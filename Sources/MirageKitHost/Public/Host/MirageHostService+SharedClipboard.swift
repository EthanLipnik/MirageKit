//
//  MirageHostService+SharedClipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    nonisolated static func shouldEnableSharedClipboard(
        settingEnabled: Bool,
        sessionState: LoomSessionAvailability,
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        guard settingEnabled else { return false }
        guard sessionState == .ready else { return false }
        return hasAppStreams || hasDesktopStream
    }

    nonisolated static func shouldDeferAutomaticSharedClipboardPayloads(
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        hasAppStreams || hasDesktopStream
    }

    func syncSharedClipboardState(forceStatusBroadcast: Bool = false) {
        let hasAppStreams = !activeStreams.isEmpty
        let hasDesktopStream = desktopStreamID != nil
        let connectedClientIDs = Set(clientsByID.keys)
        sharedClipboardStatusByClientID = sharedClipboardStatusByClientID.filter { connectedClientIDs.contains($0.key) }

        if !Self.shouldDeferAutomaticSharedClipboardPayloads(
            hasAppStreams: hasAppStreams,
            hasDesktopStream: hasDesktopStream
        ), deferredAutomaticSharedClipboardSend != nil {
            MirageLogger.host(
                "Dropping deferred automatic shared clipboard payload after stream stop: deferredClipboardPayloads=\(deferredAutomaticSharedClipboardPayloadCount)"
            )
            deferredAutomaticSharedClipboardSend = nil
        }

        var hasEligibleActiveClient = false
        for clientContext in clientsBySessionID.values {
            let enabled = Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                sessionState: sessionState,
                hasAppStreams: hasAppStreams,
                hasDesktopStream: hasDesktopStream
            )
            if enabled {
                hasEligibleActiveClient = true
            }
            sendSharedClipboardStatusIfNeeded(
                to: clientContext,
                enabled: enabled,
                force: forceStatusBroadcast || sharedClipboardStatusByClientID[clientContext.client.id] == nil
            )
        }

        if hasEligibleActiveClient {
            ensureSharedClipboardBridge().setActive(true)
        } else {
            sharedClipboardBridge?.setActive(false)
        }
    }

    func handleSharedClipboardUpdate(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let client = clientContext.client

        guard Self.shouldEnableSharedClipboard(
            settingEnabled: sharedClipboardEnabled,
            sessionState: sessionState,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        ) else {
            MirageLogger.host("Ignoring shared clipboard update while runtime is disabled")
            return
        }

        guard let mediaSecurityContext = mediaSecurityByClientID[client.id] else {
            MirageLogger.host("Ignoring shared clipboard update without media security for \(client.name)")
            return
        }

        let secCtx = mediaSecurityContext
        let clientName = client.name
        Task.detached(priority: .utility) { [weak self] in
            do {
                let update = try message.decode(SharedClipboardUpdateMessage.self)
                let decryptedPayload: Data? = if let encryptedPayload = update.encryptedPayload {
                    try MirageMediaSecurity.decryptClipboardPayload(
                        encryptedPayload,
                        context: secCtx
                    )
                } else {
                    nil
                }
                await self?.applyReceivedClipboardChunk(
                    representation: update.representation,
                    payload: decryptedPayload,
                    orderingToken: update.orderingToken,
                    sentAtMs: update.sentAtMs,
                    chunkIndex: update.chunkIndex,
                    chunkCount: update.chunkCount
                )
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to handle shared clipboard update from \(clientName): ")
            }
        }
    }

    private func applyReceivedClipboardChunk(
        representation: SharedClipboardRepresentation,
        payload: Data?,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64,
        chunkIndex: Int,
        chunkCount: Int
    ) async {
        if payload == nil {
            await ensureSharedClipboardBridge().applyRemoteItem(
                MirageSharedClipboardItem(
                    representation: representation,
                    payload: nil
                ),
                orderingToken: orderingToken,
                sentAtMs: sentAtMs
            )
            return
        }

        guard let payload,
              let fullPayload = clipboardChunkBuffer.addChunk(
                  changeID: orderingToken.changeID,
                  chunkIndex: chunkIndex,
                  chunkCount: chunkCount,
                  payload: payload
              ) else { return }

        guard let validatedPayload = MirageSharedClipboard.validatedPayload(
            fullPayload,
            representation: representation
        ) else { return }

        await ensureSharedClipboardBridge().applyRemoteItem(
            MirageSharedClipboardItem(
                representation: representation,
                payload: validatedPayload
            ),
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )
    }

    private func ensureSharedClipboardBridge() -> MirageHostSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageHostSharedClipboardBridge()
        bridge.onLocalSend = { [weak self] localSend, sentAtMs in
            await self?.broadcastLocalSharedClipboard(localSend, sentAtMs: sentAtMs)
        }
        sharedClipboardBridge = bridge
        return bridge
    }

    private func broadcastLocalSharedClipboard(
        _ localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64
    ) async {
        if Self.shouldDeferAutomaticSharedClipboardPayloads(
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        ) {
            deferredAutomaticSharedClipboardSend = (localSend, sentAtMs)
            deferredAutomaticSharedClipboardPayloadCount += 1
            MirageLogger.host(
                "Deferred automatic shared clipboard payload during active stream: " +
                "deferredClipboardPayloads=\(deferredAutomaticSharedClipboardPayloadCount), " +
                "bytes=\(localSend.item.representation.byteCount)"
            )
            return
        }

        for clientContext in clientsBySessionID.values {
            guard Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                sessionState: sessionState,
                hasAppStreams: !activeStreams.isEmpty,
                hasDesktopStream: desktopStreamID != nil
            ) else {
                continue
            }
            guard let mediaSecurityContext = mediaSecurityByClientID[clientContext.client.id] else {
                continue
            }

            do {
                let messages = try MirageSharedClipboard.makeUpdateMessages(
                    localSend: localSend,
                    sentAtMs: sentAtMs,
                    mediaSecurityContext: mediaSecurityContext
                )
                for (index, message) in messages.enumerated() {
                    try await clientContext.send(message)
                    guard index < messages.count - 1 else { continue }
                    await Task.yield()
                    try await Task.sleep(for: MirageSharedClipboard.automaticStreamChunkPacingDelay)
                }
            } catch is CancellationError {
                return
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send shared clipboard update to \(clientContext.client.name): ")
            }
        }
    }

    private func sendSharedClipboardStatusIfNeeded(
        to clientContext: ClientContext,
        enabled: Bool,
        force: Bool
    ) {
        let clientID = clientContext.client.id
        guard force || sharedClipboardStatusByClientID[clientID] != enabled else { return }

        let sent = clientContext.sendBestEffort(
            .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: enabled)
        )
        guard sent else {
            MirageLogger.host("Failed to encode shared clipboard status for \(clientContext.client.name)")
            return
        }

        sharedClipboardStatusByClientID[clientID] = enabled
        MirageLogger.host(
            "Shared clipboard status sent to \(clientContext.client.name): enabled=\(enabled)"
        )
    }
}
#endif
