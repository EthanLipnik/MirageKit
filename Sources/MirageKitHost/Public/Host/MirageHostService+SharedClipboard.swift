//
//  MirageHostService+SharedClipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import Network
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
        for clientContext in clientsByConnection.values {
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
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)],
              clientContext.client.id == client.id else {
            MirageLogger.host("Ignoring shared clipboard update from unknown client \(client.name)")
            return
        }

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

        do {
            let update = try message.decode(SharedClipboardUpdateMessage.self)
            let decryptedText = try MirageMediaSecurity.decryptClipboardText(
                update.encryptedText,
                context: mediaSecurityContext
            )
            guard let clipboardText = MirageSharedClipboard.validatedText(decryptedText) else {
                MirageLogger.host("Ignoring invalid shared clipboard payload from \(client.name)")
                return
            }

            ensureSharedClipboardBridge().applyRemoteText(
                clipboardText,
                changeID: update.changeID,
                sentAtMs: update.sentAtMs
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle shared clipboard update: ")
        }
    }

    private func ensureSharedClipboardBridge() -> MirageHostSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageHostSharedClipboardBridge { [weak self] text, changeID, sentAtMs in
            self?.broadcastSharedClipboardUpdate(
                text: text,
                changeID: changeID,
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
        text: String,
        changeID: UUID,
        sentAtMs: Int64
    ) {
        guard let clipboardText = MirageSharedClipboard.validatedText(text) else { return }

        for clientContext in clientsByConnection.values {
            guard Self.shouldEnableSharedClipboard(
                settingEnabled: sharedClipboardEnabled,
                negotiatedFeatures: clientContext.negotiatedFeatures,
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
                let encryptedText = try MirageMediaSecurity.encryptClipboardText(
                    clipboardText,
                    context: mediaSecurityContext
                )
                let update = SharedClipboardUpdateMessage(
                    changeID: changeID,
                    sentAtMs: sentAtMs,
                    encryptedText: encryptedText
                )
                if !clientContext.sendBestEffort(.sharedClipboardUpdate, content: update) {
                    MirageLogger.host("Failed to encode shared clipboard update for \(clientContext.client.name)")
                }
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to encrypt shared clipboard update: ")
            }
        }
    }
}
#endif
