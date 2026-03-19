//
//  MirageClientService+SharedClipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit

#if canImport(UIKit)
import UIKit
#endif

@MainActor
extension MirageClientService {
    nonisolated static func shouldEnableSharedClipboard(
        connectionState: ConnectionState,
        hostSharedClipboardEnabled: Bool,
        clientClipboardSharingEnabled: Bool,
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        guard case .connected = connectionState else { return false }
        guard hostSharedClipboardEnabled else { return false }
        guard clientClipboardSharingEnabled else { return false }
        return hasAppStreams || hasDesktopStream
    }

    func refreshSharedClipboardBridgeState() {
        let shouldEnable = Self.shouldEnableSharedClipboard(
            connectionState: connectionState,
            hostSharedClipboardEnabled: sharedClipboardEnabled,
            clientClipboardSharingEnabled: clientClipboardSharingEnabled,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        )

        if shouldEnable {
            ensureSharedClipboardBridge().setActive(true, autoSync: clientClipboardAutoSync)
        } else {
            sharedClipboardBridge?.setActive(false)
        }
    }

    /// Updates the client-side clipboard sharing preferences and refreshes bridge state.
    public func updateClipboardPreferences(enabled: Bool, autoSync: Bool) {
        clientClipboardSharingEnabled = enabled
        clientClipboardAutoSync = autoSync
        refreshSharedClipboardBridgeState()
    }

    /// Reads the local clipboard and sends it to the host. Called on Cmd+V in on-paste mode.
    public func syncLocalClipboardToHost() {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              clientClipboardSharingEnabled else { return }
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string else { return }
        ensureSharedClipboardBridge().injectLocalClipboardText(text)
        #endif
    }

    func sendSharedClipboardUpdate(
        text: String,
        changeID: UUID,
        sentAtMs: Int64
    ) {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              let mediaSecurityContext else {
            return
        }
        guard let clipboardText = MirageSharedClipboard.validatedText(text) else { return }

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
            _ = sendControlMessageBestEffort(.sharedClipboardUpdate, content: update)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to send shared clipboard update: ")
        }
    }

    func ensureSharedClipboardBridge() -> MirageClientSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageClientSharedClipboardBridge { [weak self] text, changeID, sentAtMs in
            self?.sendSharedClipboardUpdate(
                text: text,
                changeID: changeID,
                sentAtMs: sentAtMs
            )
        }
        sharedClipboardBridge = bridge
        return bridge
    }
}
