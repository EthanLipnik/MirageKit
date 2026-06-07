//
//  MirageHostService+StreamCleanup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
#if os(macOS)

@MainActor
extension MirageHostService {
    /// Closes a media stream removed from host bookkeeping and logs cleanup failures.
    func closeRemovedMediaStream(
        _ stream: any MirageQueuedUnreliableMediaStream,
        streamID: StreamID,
        kind: String
    ) {
        Task {
            do {
                try await stream.close()
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to close \(kind) stream \(streamID): ")
            }
        }
    }

    /// Releases resources reserved by a window stream that failed before startup completed.
    func cleanupFailedStreamStart(
        streamID: StreamID,
        context: StreamContext,
        windowID: WindowID
    )
    async {
        let mirroredDisplayID = await context.virtualDisplayContext?.displayID
        let shouldDisableSharedMirroringBeforeStop = activeStreams.count == 1 &&
            activeStreams.first?.id == streamID
        if shouldDisableSharedMirroringBeforeStop, let mirroredDisplayID {
            _ = await disableDisplayMirroring(displayID: mirroredDisplayID)
        }
        await context.stop()
        clearVirtualDisplayState(windowID: windowID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
        windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
        windowResizeInFlightStreamIDs.remove(streamID)
        clearAppStreamGovernorState(streamID: streamID)
        stopWindowVisibleFrameMonitor(streamID: streamID)
        streamsByID.removeValue(forKey: streamID)
        mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
        transportSendErrorReported.remove(streamID)
        removeActiveStreamSession(streamID: streamID)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await deactivateAudioSourceIfNeeded(streamID: streamID)
        inputStreamCache.remove(streamID)
        if let videoStream = videoMediaStreamsByStreamID.removeValue(forKey: streamID) {
            closeRemovedMediaStream(videoStream, streamID: streamID, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
        await teardownSharedAppStreamMirroringIfIdle(displayID: mirroredDisplayID)
    }
}

#endif
