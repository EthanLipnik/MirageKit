//
//  MirageHostService+AppWindowSwapAtlas.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Replaces direct app-atlas capture with a hidden window capture for a slot swap.
    func performAppAtlasWindowSwap(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID,
        currentWindowID: WindowID,
        hiddenInfo: AppStreamHiddenWindowInfo,
        streamSession: MirageStreamSession,
        previousWindowInfo: WindowStreamInfo,
        clientContext: ClientContext,
        clientID: UUID,
        failure: (String) -> AppWindowSwapResultMessage
    ) async -> AppWindowSwapResultMessage {
        do {
            let started = try await replaceAppAtlasWindowCapture(
                streamSession: streamSession,
                currentWindowID: currentWindowID,
                targetWindowID: targetWindowID,
                hiddenInfo: hiddenInfo,
                clientContext: clientContext
            )
            let targetWindow = started.session.window
            let attachment = started.attachment
            let processID = targetWindow.application?.id ?? 0
            let isResizable = appStreamManager.checkWindowResizability(processID: processID)
            await appStreamManager.replaceVisibleWindowForStream(
                bundleIdentifier: bundleIdentifier,
                streamID: targetSlotStreamID,
                newWindowID: targetWindowID,
                title: attachment.title,
                width: attachment.width,
                height: attachment.height,
                isResizable: isResizable,
                capturedClusterWindowIDs: [],
                mediaStreamID: attachment.mediaStreamID,
                atlasRegion: attachment.atlasRegion
            )
            await appStreamManager.upsertHiddenWindow(
                bundleIdentifier: bundleIdentifier,
                windowID: currentWindowID,
                title: previousWindowInfo.title,
                width: previousWindowInfo.width,
                height: previousWindowInfo.height,
                isResizable: previousWindowInfo.isResizable
            )
            await appStreamManager.noteWindowStartupSucceeded(
                bundleID: bundleIdentifier,
                windowID: targetWindowID
            )
            await markAppStreamInteraction(streamID: targetSlotStreamID, reason: "app atlas slot swap")
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleIdentifier, clientID: clientID)
            await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "app atlas slot swap")
            return AppWindowSwapResultMessage(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                mediaStreamID: attachment.mediaStreamID,
                windowID: targetWindowID,
                success: true,
                reason: nil,
                atlasRegion: attachment.atlasRegion,
                atlasLayouts: attachment.atlasLayouts
            )
        } catch {
            return failure("Failed to swap app-atlas window: \(error.localizedDescription)")
        }
    }
}
#endif
