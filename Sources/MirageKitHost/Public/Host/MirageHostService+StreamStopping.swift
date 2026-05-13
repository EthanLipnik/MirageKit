//
//  MirageHostService+StreamStopping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Stops a host stream, releases capture resources, and optionally updates app-session state.
    func stopStream(
        _ session: MirageStreamSession,
        minimizeWindow: Bool = false,
        updateAppSession: Bool = true,
        triggeredByExplicitStreamStop: Bool = true
    )
    async {
        clearPendingAppWindowReplacement(streamID: session.id)
        cancelPendingStartupAttempt(streamID: session.id)

        inputController.clearAllModifiers()

        await menuBarMonitor.stopMonitoring(streamID: session.id)

        let windowID = session.window.id
        let context = streamsByID[session.id]
        let mirroredDisplayID = await context?.virtualDisplayContext?.displayID
        let appSessionForStoppedWindow: MirageAppStreamSession? = if updateAppSession {
            await appStreamManager.sessionForWindow(windowID)
        } else {
            nil
        }
        let shouldDisableSharedMirroringBeforeStop = activeStreams.count == 1 &&
            activeStreams.first?.id == session.id

        clearVirtualDisplayState(windowID: windowID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: session.id)
        windowResizeRequestCounterByStreamID.removeValue(forKey: session.id)
        windowResizeInFlightStreamIDs.remove(session.id)
        clearAppStreamGovernorState(streamID: session.id)
        stopWindowVisibleFrameMonitor(streamID: session.id)

        if context == nil {
            await stopAppAtlasWindow(
                streamID: session.id,
                clientID: appSessionForStoppedWindow?.clientID ?? session.client.id
            )
        }

        if shouldDisableSharedMirroringBeforeStop, let mirroredDisplayID {
            _ = await disableDisplayMirroring(displayID: mirroredDisplayID)
        }
        await context?.stop()
        await WindowSpaceManager.shared.restoreAllWindowsOwned(by: session.id)
        inputController.endTrafficLightProtection(windowID: windowID)
        streamsByID.removeValue(forKey: session.id)
        streamRegistry.unregisterPointerCoalescingRoute(streamID: session.id)
        removeActiveStreamSession(streamID: session.id)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await deactivateAudioSourceIfNeeded(streamID: session.id)

        inputStreamCache.remove(session.id)

        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: session.id) {
            closeRemovedMediaStream(videoStream, streamID: session.id, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: session.id)

        if minimizeWindow { WindowManager.minimizeWindowIfPossible(windowID) }

        if updateAppSession {
            let removedAppWindowID: WindowID = if let appSessionForStoppedWindow,
                                                  let reboundWindowID = await appStreamManager.windowIDForStream(
                                                      bundleIdentifier: appSessionForStoppedWindow.bundleIdentifier,
                                                      streamID: session.id
                                                  ) {
                reboundWindowID
            } else {
                windowID
            }
            await removeStoppedWindowFromAppSessionIfNeeded(
                streamID: session.id,
                fallbackWindowID: removedAppWindowID
            )
            if let appSessionForStoppedWindow,
               let clientContext = findClientContext(clientID: appSessionForStoppedWindow.clientID) {
                await emitWindowRemovedFromStream(
                    to: clientContext,
                    bundleIdentifier: appSessionForStoppedWindow.bundleIdentifier,
                    streamID: session.id,
                    windowID: removedAppWindowID,
                    reason: .noLongerEligible
                )
            }
        }

        await updateLightsOutState()
        lockHostIfStreamingStopped(triggeredByExplicitStreamStop: triggeredByExplicitStreamStop)

        if activeStreams.isEmpty {
            await PowerAssertionManager.shared.disable()
        }
        await stopAppStreamGovernorsIfIdle()
        await teardownSharedAppStreamMirroringIfIdle(displayID: mirroredDisplayID)
    }
}
#endif
