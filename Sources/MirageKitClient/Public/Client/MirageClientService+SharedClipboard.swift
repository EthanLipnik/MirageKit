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
            MirageLogger.client("Shared clipboard bridge active")
            await ensureSharedClipboardBridge().setActive(true)
        } else {
            MirageLogger.client("Shared clipboard bridge inactive")
            await sharedClipboardBridge?.setActive(false)
        }
    }

    /// Updates the client-side clipboard sharing preferences and refreshes bridge state.
    public func updateClipboardPreferences(enabled: Bool) async {
        clientClipboardSharingEnabled = enabled
        await refreshSharedClipboardBridgeState()
    }

    /// Reads the local clipboard and sends it to the host. Called on Cmd+V.
    @discardableResult
    public func syncLocalClipboardToHost() async -> Bool {
        guard case .connected = connectionState,
              sharedClipboardEnabled,
              clientClipboardSharingEnabled else {
            MirageLogger.client("Shared clipboard manual sync skipped: sharing disabled")
            return false
        }
        #if canImport(UIKit)
        guard let preparation = await ensureSharedClipboardBridge().prepareCurrentClipboardManualSync() else {
            return false
        }
        guard case let .send(localSend: localSend, sentAtMs: sentAtMs) = preparation else {
            return true
        }
        do {
            try await sendSharedClipboardUpdateReliably(
                localSend: localSend,
                sentAtMs: sentAtMs
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

        let messages = try MirageSharedClipboard.makeUpdateMessages(
            localSend: localSend,
            sentAtMs: sentAtMs,
            mediaSecurityContext: mediaSecurityContext,
            source: .client
        )
        MirageLogger.client(
            "Sending shared clipboard update to host: kind=\(localSend.item.representation.kind.rawValue), bytes=\(localSend.item.representation.byteCount), chunks=\(messages.count), transferable=\(localSend.hasPayload)"
        )
        for (index, message) in messages.enumerated() {
            try await controlChannel.send(message)
            guard index < messages.count - 1 else { continue }
            try await Task.sleep(for: MirageSharedClipboard.automaticStreamChunkPacingDelay)
        }
    }

    func ensureSharedClipboardBridge() -> MirageClientSharedClipboardBridge {
        if let sharedClipboardBridge {
            return sharedClipboardBridge
        }

        let bridge = MirageClientSharedClipboardBridge()
        sharedClipboardBridge = bridge
        return bridge
    }
}
