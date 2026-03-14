//
//  MirageClientService+SharedClipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated static func shouldEnableSharedClipboard(
        connectionState: ConnectionState,
        hostSharedClipboardEnabled: Bool,
        hasAppStreams: Bool,
        hasDesktopStream: Bool
    ) -> Bool {
        guard case .connected = connectionState else { return false }
        guard hostSharedClipboardEnabled else { return false }
        return hasAppStreams || hasDesktopStream
    }

    func refreshSharedClipboardBridgeState() {
        let shouldEnable = Self.shouldEnableSharedClipboard(
            connectionState: connectionState,
            hostSharedClipboardEnabled: sharedClipboardEnabled,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        )

        if shouldEnable {
            ensureSharedClipboardBridge().setActive(true)
        } else {
            sharedClipboardBridge?.setActive(false)
        }
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
