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
    /// Applies the host's shared-clipboard availability state.
    func handleSharedClipboardStatus(_ message: ControlMessage) {
        do {
            let status = try message.decode(SharedClipboardStatusMessage.self)
            sharedClipboardEnabled = status.enabled
            MirageLogger.client("Shared clipboard host status received: enabled=\(status.enabled)")
            Task { await refreshSharedClipboardBridgeState() }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode shared clipboard status: ")
        }
    }

    /// Validates and decrypts a host clipboard update before handing payload chunks to the bridge.
    func handleSharedClipboardUpdate(_ message: ControlMessage) {
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
                let decryptedPayload: Data? = if let encryptedPayload = update.encryptedPayload {
                    try MirageMediaSecurity.decryptClipboardPayload(
                        encryptedPayload,
                        context: secCtx
                    )
                } else {
                    nil
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

    /// Reassembles and validates remote clipboard chunks before applying the completed item.
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

        await ensureSharedClipboardBridge().noteRemoteTransferObservation(
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )

        guard let fullPayload = clipboardChunkBuffer.addChunk(
            changeID: orderingToken.changeID,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            payload: payload
        ) else { return }

        guard let validatedPayload = MirageSharedClipboard.validatedPayload(
            fullPayload,
            representation: representation
        ) else {
            await ensureSharedClipboardBridge().noteRemoteDeclaration(
                orderingToken: orderingToken,
                sentAtMs: sentAtMs
            )
            return
        }

        await applyReceivedClipboardItemWhenMediaStable(
            MirageSharedClipboardItem(
                representation: representation,
                payload: validatedPayload
            ),
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )
    }

    /// Delays clipboard application while active media recovery may still be presenting stale frames.
    private func applyReceivedClipboardItemWhenMediaStable(
        _ item: MirageSharedClipboardItem,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64,
        attempt: Int = 0
    ) async {
        if await shouldDeferSharedClipboardPayloadApplication(), attempt < 20 {
            if attempt == 0 {
                MirageLogger.client(
                    "Deferring shared clipboard payload apply while media recovery is active"
                )
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await applyReceivedClipboardItemWhenMediaStable(
                item,
                orderingToken: orderingToken,
                sentAtMs: sentAtMs,
                attempt: attempt + 1
            )
            return
        }

        await ensureSharedClipboardBridge().applyRemoteItem(
            item,
            orderingToken: orderingToken,
            sentAtMs: sentAtMs
        )
    }

    /// Returns whether any active stream controller is currently blocking remote clipboard application.
    private func shouldDeferSharedClipboardPayloadApplication() async -> Bool {
        for controller in controllersByStream.values {
            if await controller.shouldDeferSharedClipboardApply {
                return true
            }
        }
        return false
    }
}
