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
            Task { await refreshSharedClipboardBridgeState() }
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
            clientClipboardSharingEnabled: clientClipboardSharingEnabled,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamID != nil
        ) else {
            return
        }
        guard let mediaSecurityContext else {
            MirageLogger.client("Ignoring shared clipboard update without media security context")
            return
        }

        let secCtx = mediaSecurityContext
        Task.detached(priority: .utility) { [weak self] in
            do {
                let update = try message.decode(SharedClipboardUpdateMessage.self)
                let decryptedText = try MirageMediaSecurity.decryptClipboardText(
                    update.encryptedText,
                    context: secCtx
                )
                guard let chunkText = MirageSharedClipboard.validatedText(decryptedText) else {
                    MirageLogger.client("Ignoring invalid shared clipboard payload from host")
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
                MirageLogger.error(.client, error: error, message: "Failed to handle shared clipboard update: ")
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
}
