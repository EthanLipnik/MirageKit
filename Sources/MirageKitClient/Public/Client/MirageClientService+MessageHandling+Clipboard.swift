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
            MirageLogger.client("Shared clipboard host status received: enabled=\(status.enabled)")
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
            MirageLogger.client("Ignoring shared clipboard update while bridge is disabled")
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
                let decryptedPayload: Data?
                if let encryptedPayload = update.encryptedPayload {
                    decryptedPayload = try MirageMediaSecurity.decryptClipboardPayload(
                        encryptedPayload,
                        context: secCtx
                    )
                } else {
                    decryptedPayload = nil
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
                MirageLogger.error(.client, error: error, message: "Failed to handle shared clipboard update: ")
            }
        }
    }

    private func applyReceivedClipboardChunk(
        representation: SharedClipboardRepresentation,
        payload: Data?,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64,
        chunkIndex: Int,
        chunkCount: Int
    ) async {
        guard let payload else {
            await ensureSharedClipboardBridge().noteRemoteDeclaration(
                orderingToken: orderingToken,
                sentAtMs: sentAtMs
            )
            return
        }

        guard let fullPayload = clipboardChunkBuffer.addChunk(
            changeID: orderingToken.changeID,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            payload: payload
        ) else { return }

        guard let validatedPayload = MirageSharedClipboard.validatedPayload(fullPayload) else {
            await ensureSharedClipboardBridge().noteRemoteDeclaration(
                orderingToken: orderingToken,
                sentAtMs: sentAtMs
            )
            return
        }

        await ensureSharedClipboardBridge().applyRemoteItem(
            MirageSharedClipboardItem(
                representation: representation,
                payload: validatedPayload
            ),
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )
    }
}
