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
    nonisolated static func sharedClipboardFeatureNegotiated(
        _ negotiatedFeatures: MirageFeatureSet
    ) -> Bool {
        negotiatedFeatures.contains(.sharedClipboardV1)
    }

    nonisolated static func shouldEnableSharedClipboard(
        settingEnabled: Bool,
        negotiatedFeatures: MirageFeatureSet,
        sessionState: LoomSessionAvailability,
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        guard settingEnabled else { return false }
        guard sharedClipboardFeatureNegotiated(negotiatedFeatures) else { return false }
        guard sessionState == .ready else { return false }
        return hasAppStreams || hasDesktopStream
    }

    func syncSharedClipboardState(
        reason _: String,
        forceStatusBroadcast: Bool = false
    ) {
        let hasAppStreams = !activeStreams.isEmpty
        let hasDesktopStream = desktopStreamID != nil
        let connectedClientIDs = Set(clientsByID.keys)
        sharedClipboardStatusByClientID = sharedClipboardStatusByClientID.filter { connectedClientIDs.contains($0.key) }

        var hasEligibleActiveClient = false
        for clientContext in clientsBySessionID.values {
            guard Self.sharedClipboardFeatureNegotiated(clientContext.negotiatedFeatures) else {
                sharedClipboardStatusByClientID.removeValue(forKey: clientContext.client.id)
                continue
            }

            let enabled = Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                negotiatedFeatures: clientContext.negotiatedFeatures,
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
            negotiatedFeatures: clientContext.negotiatedFeatures,
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
                let decryptedText = try MirageMediaSecurity.decryptClipboardText(
                    update.encryptedText,
                    context: secCtx
                )
                guard let chunkText = MirageSharedClipboard.validatedText(decryptedText) else {
                    MirageLogger.host("Ignoring invalid shared clipboard payload from \(clientName)")
                    return
                }
                await self?.applyReceivedClipboardChunk(
                    text: chunkText,
                    orderingToken: update.orderingToken,
                    sentAtMs: update.sentAtMs,
                    chunkIndex: update.chunkIndex,
                    chunkCount: update.chunkCount
                )
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to handle shared clipboard update: ")
            }
        }
    }

    private func applyReceivedClipboardChunk(
        text: String,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64,
        chunkIndex: Int,
        chunkCount: Int
    ) {
        guard let fullText = clipboardChunkBuffer.addChunk(
            changeID: orderingToken.changeID,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            text: text
        ) else { return }

        guard let validatedText = MirageSharedClipboard.validatedText(fullText) else { return }

        ensureSharedClipboardBridge().applyRemoteText(
            validatedText,
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )
    }

    private func ensureSharedClipboardBridge() -> MirageHostSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageHostSharedClipboardBridge { [weak self] localSend, sentAtMs in
            self?.broadcastSharedClipboardUpdate(
                localSend: localSend,
                sentAtMs: sentAtMs
            )
        }
        sharedClipboardBridge = bridge
        return bridge
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
    }

    private func broadcastSharedClipboardUpdate(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64
    ) {
        guard let clipboardText = MirageSharedClipboard.validatedText(localSend.text) else { return }

        var targets: [(MirageMediaSecurityContext, MirageControlChannel)] = []
        for clientContext in clientsBySessionID.values {
            guard Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                negotiatedFeatures: clientContext.negotiatedFeatures,
                sessionState: sessionState,
                hasAppStreams: !activeStreams.isEmpty,
                hasDesktopStream: desktopStreamID != nil
            ) else {
                continue
            }
            guard let secCtx = mediaSecurityByClientID[clientContext.client.id] else {
                continue
            }
            targets.append((secCtx, clientContext.controlChannel))
        }
        guard !targets.isEmpty else { return }

        let chunks = MirageSharedClipboard.chunkText(clipboardText)
        let chunkCount = chunks.count

        Task.detached(priority: .utility) {
            for (secCtx, channel) in targets {
                for (index, chunk) in chunks.enumerated() {
                    do {
                        let encryptedText = try MirageMediaSecurity.encryptClipboardText(
                            chunk,
                            context: secCtx
                        )
                        let update = SharedClipboardUpdateMessage(
                            changeID: localSend.orderingToken.changeID,
                            logicalVersion: localSend.orderingToken.logicalVersion,
                            sentAtMs: sentAtMs,
                            encryptedText: encryptedText,
                            chunkIndex: index,
                            chunkCount: chunkCount
                        )
                        let message = try ControlMessage(type: .sharedClipboardUpdate, content: update)
                        channel.sendBestEffort(message)
                    } catch {
                        MirageLogger.error(.host, error: error, message: "Failed to encrypt shared clipboard update: ")
                    }
                    if chunkCount > 1 { await Task.yield() }
                }
            }
        }
    }
}
#endif
