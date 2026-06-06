//
//  MirageHostService+SharedClipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    nonisolated static func shouldEnableSharedClipboard(
        settingEnabled: Bool,
        sessionAvailability: MirageWire.MirageHostSessionAvailability,
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        guard settingEnabled else { return false }
        guard sessionAvailability == .ready else { return false }
        return hasAppStreams || hasDesktopStream
    }

    func syncSharedClipboardState(forceStatusBroadcast: Bool = false) {
        let hasAppStreams = !activeStreams.isEmpty
        let hasDesktopStream = desktopStreamID != nil
        let connectedClientIDs = Set(clientsByID.keys)
        sharedClipboardStatusByClientID = sharedClipboardStatusByClientID.filter { connectedClientIDs.contains($0.key) }

        var hasEligibleActiveClient = false
        for clientContext in clientsBySessionID.values {
            let enabled = Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                sessionAvailability: mirageSessionAvailability,
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
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        let client = clientContext.client

        guard Self.shouldEnableSharedClipboard(
            settingEnabled: sharedClipboardEnabled,
            sessionAvailability: mirageSessionAvailability,
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
                let update = try message.decode(MirageWire.SharedClipboardUpdateMessage.self)
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
        representation: MirageWire.SharedClipboardRepresentation,
        payload: Data?,
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken,
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
        for clientContext in clientsBySessionID.values {
            guard Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                sessionAvailability: mirageSessionAvailability,
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
            content: MirageWire.SharedClipboardStatusMessage(enabled: enabled)
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
