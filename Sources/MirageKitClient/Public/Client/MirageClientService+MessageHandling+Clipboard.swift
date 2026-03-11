//
//  MirageClientService+MessageHandling+Clipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleSharedClipboardStatus(_ message: ControlMessage) {
        guard negotiatedFeatures.contains(.sharedClipboardV1) else {
            MirageLogger.client("Ignoring shared clipboard status without negotiated support")
            return
        }

        do {
            let status = try message.decode(SharedClipboardStatusMessage.self)
            sharedClipboardEnabled = status.enabled
            refreshSharedClipboardBridgeState()
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode shared clipboard status: ")
        }
    }

    func handleSharedClipboardUpdate(_ message: ControlMessage) {
        guard negotiatedFeatures.contains(.sharedClipboardV1) else {
            MirageLogger.client("Ignoring shared clipboard update without negotiated support")
            return
        }
        guard Self.shouldEnableSharedClipboard(
            connectionState: connectionState,
            hostSharedClipboardEnabled: sharedClipboardEnabled,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        ) else {
            return
        }
        guard let mediaSecurityContext else {
            MirageLogger.client("Ignoring shared clipboard update without media security context")
            return
        }

        do {
            let update = try message.decode(SharedClipboardUpdateMessage.self)
            let decryptedText = try MirageMediaSecurity.decryptClipboardText(
                update.encryptedText,
                context: mediaSecurityContext
            )
            guard let clipboardText = MirageSharedClipboard.validatedText(decryptedText) else {
                MirageLogger.client("Ignoring invalid shared clipboard payload from host")
                return
            }

            ensureSharedClipboardBridge().applyRemoteText(
                clipboardText,
                changeID: update.changeID,
                sentAtMs: update.sentAtMs
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to handle shared clipboard update: ")
        }
    }
}
