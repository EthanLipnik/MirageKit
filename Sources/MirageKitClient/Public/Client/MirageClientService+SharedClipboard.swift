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

    func refreshSharedClipboardBridgeState() async {
        let shouldEnable = Self.shouldEnableSharedClipboard(
            connectionState: connectionState,
            hostSharedClipboardEnabled: sharedClipboardEnabled,
            clientClipboardSharingEnabled: clientClipboardSharingEnabled,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        )

        if shouldEnable {
            MirageLogger.client("Shared clipboard bridge active, autoSync=\(clientClipboardAutoSync)")
            await ensureSharedClipboardBridge().setActive(true, autoSync: clientClipboardAutoSync)
        } else {
            MirageLogger.client("Shared clipboard bridge inactive")
            await sharedClipboardBridge?.setActive(false)
        }
    }

    /// Updates the client-side clipboard sharing preferences and refreshes bridge state.
    public func updateClipboardPreferences(enabled: Bool, autoSync: Bool) async {
        clientClipboardSharingEnabled = enabled
        clientClipboardAutoSync = autoSync
        await refreshSharedClipboardBridgeState()
    }

    /// Reads the local clipboard and sends it to the host. Called on Cmd+V in on-paste mode.
    @discardableResult
    public func syncLocalClipboardToHost() async -> Bool {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              clientClipboardSharingEnabled else {
            MirageLogger.client("Shared clipboard manual sync skipped: sharing disabled")
            return false
        }
        #if canImport(UIKit)
        guard let preparedSend = await ensureSharedClipboardBridge().prepareCurrentClipboardManualSend() else {
            return false
        }
        do {
            try await sendSharedClipboardUpdateReliably(
                localSend: preparedSend.localSend,
                sentAtMs: preparedSend.sentAtMs
            )
            return true
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed manual shared clipboard sync: ")
            return false
        }
        #else
        return false
        #endif
    }

    func sendSharedClipboardUpdate(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64
    ) {
        Task { @MainActor [weak self] in
            do {
                try await self?.sendSharedClipboardUpdateReliably(
                    localSend: localSend,
                    sentAtMs: sentAtMs
                )
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to send shared clipboard update: ")
            }
        }
    }

    func sendSharedClipboardUpdateReliably(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64
    ) async throws {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              let mediaSecurityContext,
              let controlChannel else {
            throw MirageError.protocolError("Shared clipboard unavailable")
        }
        guard let clipboardText = MirageSharedClipboard.validatedText(localSend.text) else {
            MirageLogger.client("Ignoring invalid local shared clipboard text")
            return
        }

        let chunks = MirageSharedClipboard.chunkText(clipboardText)
        let chunkCount = chunks.count
        MirageLogger.client(
            "Sending shared clipboard update to host: bytes=\(clipboardText.utf8.count), chunks=\(chunkCount)"
        )

        for (index, chunk) in chunks.enumerated() {
            let encryptedText = try MirageMediaSecurity.encryptClipboardText(
                chunk,
                context: mediaSecurityContext
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
            try await controlChannel.send(message)
            if chunkCount > 1 { await Task.yield() }
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
