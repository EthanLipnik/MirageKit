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
        ensureSharedClipboardBridge().syncCurrentClipboardToRemote()
        #endif
    }

    func sendSharedClipboardUpdate(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64
    ) {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              let mediaSecurityContext,
              let controlChannel else {
            return
        }
        guard let clipboardText = MirageSharedClipboard.validatedText(localSend.text) else { return }

        let secCtx = mediaSecurityContext
        let channel = controlChannel
        let chunks = MirageSharedClipboard.chunkText(clipboardText)
        let chunkCount = chunks.count

        Task.detached(priority: .utility) {
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
                    MirageLogger.error(.client, error: error, message: "Failed to send shared clipboard update: ")
                }
                if chunkCount > 1 { await Task.yield() }
            }
        }
    }

    func ensureSharedClipboardBridge() -> MirageClientSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageClientSharedClipboardBridge { [weak self] localSend, sentAtMs in
            self?.sendSharedClipboardUpdate(
                localSend: localSend,
                sentAtMs: sentAtMs
            )
        }
        sharedClipboardBridge = bridge
        return bridge
    }
}
