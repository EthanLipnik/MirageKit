//
//  MirageHostService+AppWindowSwapSharedDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Retargets a shared-display app-stream slot to a different host window.
    func performSharedDisplayAppWindowSwap(
        _ request: SharedDisplayAppWindowSwapRequest
    ) async -> String? {
        guard let virtualDisplayState = virtualDisplayState(streamID: request.targetSlotStreamID) else {
            return "Missing shared-display state for slot swap; direct window capture is disabled."
        }

        let resolvedSpaceID = platformVirtualDisplayBackend.space(for: virtualDisplayState.displayID)
        guard resolvedSpaceID != 0 else {
            return "Unable to resolve target display space for slot"
        }

        let oldOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: request.targetSlotStreamID
        )
        let newGeneration = virtualDisplayState.generation &+ 1
        let newOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: request.targetSlotStreamID
        )

        do {
            try await platformVirtualDisplayBackend.restoreWindow(
                request.currentWindowID,
                expectedOwner: oldOwner
            )
        } catch {
            return "Failed to release previous slot window: \(error.localizedDescription)"
        }

        do {
            try await platformVirtualDisplayBackend.moveWindow(
                request.targetWindowID,
                toSpaceID: resolvedSpaceID,
                displayID: virtualDisplayState.displayID,
                displayBounds: virtualDisplayState.bounds,
                targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                owner: newOwner
            )
        } catch {
            do {
                try await platformVirtualDisplayBackend.moveWindow(
                    request.currentWindowID,
                    toSpaceID: resolvedSpaceID,
                    displayID: virtualDisplayState.displayID,
                    displayBounds: virtualDisplayState.bounds,
                    targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                    owner: oldOwner
                )
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to restore prior slot binding after swap failure: "
                )
            }
            return "Failed to bind requested hidden window into slot: \(error.localizedDescription)"
        }

        let targetFrame = currentWindowFrame(for: request.targetWindowID) ?? CGRect(
            x: virtualDisplayState.bounds.origin.x,
            y: virtualDisplayState.bounds.origin.y,
            width: CGFloat(max(1, request.hiddenInfo.width)),
            height: CGFloat(max(1, request.hiddenInfo.height))
        )
        let targetWindow = MirageMedia.MirageWindow(
            id: request.targetWindowID,
            title: request.hiddenInfo.title,
            application: activeSessionByStreamID[request.targetSlotStreamID]?.window.application,
            frame: targetFrame,
            isOnScreen: true,
            windowLayer: 0
        )

        registerActiveStreamSession(
            MirageStreamSession(
                id: request.targetSlotStreamID,
                window: targetWindow,
                client: request.streamSession.client
            )
        )
        inputStreamCache.set(
            request.targetSlotStreamID,
            window: targetWindow,
            client: request.streamSession.client
        )
        clearVirtualDisplayState(windowID: request.currentWindowID)
        setVirtualDisplayState(
            windowID: request.targetWindowID,
            state: WindowVirtualDisplayState(
                streamID: request.targetSlotStreamID,
                displayID: virtualDisplayState.displayID,
                generation: newGeneration,
                bounds: virtualDisplayState.bounds,
                displayVisibleBounds: virtualDisplayState.displayVisibleBounds,
                targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                captureSourceRect: virtualDisplayState.captureSourceRect,
                visiblePixelResolution: virtualDisplayState.visiblePixelResolution,
                displayVisiblePixelResolution: virtualDisplayState.displayVisiblePixelResolution,
                scaleFactor: virtualDisplayState.scaleFactor,
                pixelResolution: virtualDisplayState.pixelResolution,
                clientScaleFactor: virtualDisplayState.clientScaleFactor
            )
        )
        await request.context.updateWindowBinding(
            windowID: request.targetWindowID,
            ownerGeneration: newGeneration
        )
        await activateWindow(targetWindow)
        _ = await enforceVirtualDisplayPlacementAfterActivation(windowID: request.targetWindowID, force: true)
        do {
            try await refreshSharedDisplayAppCaptureStateIfNeeded(
                streamID: request.targetSlotStreamID,
                reason: "slot swap"
            )
        } catch {
            return "Failed to retarget shared-display app capture state: \(error.localizedDescription)"
        }

        return nil
    }
}
#endif
