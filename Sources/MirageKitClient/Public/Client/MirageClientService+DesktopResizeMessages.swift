//
//  MirageClientService+DesktopResizeMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import MirageKit

@MainActor
extension MirageClientService {
    /// Applies a host-confirmed desktop resize transition to local stream state and decoder setup.
    func handleDesktopResizeCommit(_ started: DesktopStreamStartedMessage) async -> Bool {
        let streamID = started.streamID
        guard desktopSessionID == started.desktopSessionID else {
            MirageLogger.client(
                "Ignoring stale desktop resize commit for stream \(streamID): session=\(started.desktopSessionID.uuidString)"
            )
            return false
        }
        if let generation = started.desktopPresentationGeneration {
            let previousGeneration = desktopPresentationGenerationBySessionID[started.desktopSessionID] ?? 0
            guard generation > previousGeneration else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): generation=\(generation) previous=\(previousGeneration)"
                )
                return false
            }
        } else {
            guard desktopResizeCoordinator.acceptTransition(
                streamID: streamID,
                transitionID: started.transitionID
            ) else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
                )
                return false
            }
        }

        guard desktopStreamID == streamID || controllersByStream[streamID] != nil else {
            MirageLogger.client(
                "Ignoring desktop resize commit for inactive stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
            )
            clearDesktopResizeState(streamID: streamID)
            return false
        }

        desktopStreamID = streamID
        let displaySize = CGSize(width: started.width, height: started.height)
        desktopStreamResolution = displaySize
        let presentationSize = started.presentationSize
        desktopStreamPresentationResolution = presentationSize
        desktopStreamDisplayScaleFactor = inferredDisplayScaleFactor(
            displayPixelSize: displaySize,
            presentationSize: presentationSize
        )
        desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
            logicalResolution: presentationSize,
            displayPixelSize: displaySize
        )
        desktopCaptureSource = started.captureSource
        desktopStreamAllowsClientResize = started.allowsClientResize
        updateObservedFrameRate(started.frameRate, for: streamID)
        if let generation = started.desktopPresentationGeneration {
            desktopPresentationGenerationBySessionID[started.desktopSessionID] = generation
        }
        activeStreamCodecs[streamID] = started.codec
        if let dimensionToken = started.dimensionToken {
            desktopDimensionTokenByStream[streamID] = dimensionToken
        }

        let desktopMinSize = presentationSize
        sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
        onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
        onDesktopStreamStarted?(streamID, desktopMinSize, started.displayCount)

        let outcome = started.transitionOutcome ?? .resized
        if outcome == .noChange {
            postResizeTransitionTimeoutTasks[streamID]?.cancel()
            postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
            sessionStore.clearPostResizeTransition(for: streamID)
            desktopResizeCoordinator.finishTransition()
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            return true
        }

        if started.allowsClientResize {
            beginPostResizeTransition(streamID: streamID, scheduleTimeout: false)
        } else {
            sessionStore.clearPostResizeTransition(for: streamID)
        }
        await applyStreamCadenceTarget(
            started.frameRate,
            for: streamID,
            reason: "desktop resize commit"
        )
        await prepareControllerForDesktopResize(
            streamID,
            codec: started.codec,
            streamDimensions: (width: started.width, height: started.height),
            mediaMaxPacketSize: started.acceptedMediaMaxPacketSize,
            dimensionToken: started.dimensionToken,
            targetFrameRate: started.frameRate
        )
        desktopResizeCoordinator.finishTransition()
        if !started.allowsClientResize {
            desktopResizeCoordinator.clearAllState()
            sessionStore.clearPostResizeTransition(for: streamID)
        } else {
            schedulePostResizeTransitionTimeoutIfNeeded(streamID: streamID)
        }
        return true
    }
}
