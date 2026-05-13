//
//  MirageHostService+WindowVisibleFrameMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Starts monitoring visible-frame drift for a virtual-display-backed window stream.
    func ensureWindowVisibleFrameMonitor(streamID: StreamID) {
        guard windowVisibleFrameMonitorTasks[streamID] == nil else { return }
        windowVisibleFrameMonitorTasks[streamID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let driftTolerancePixels: CGFloat = 8
            let driftSampleMatchTolerance: CGFloat = 8
            let stableDriftSampleThreshold = 3

            while !Task.isCancelled {
                guard let state = virtualDisplayState(streamID: streamID) else { break }
                guard let windowID = activeWindowIDByStreamID[streamID] else { break }

                if windowResizeInFlightStreamIDs.contains(streamID) {
                    if windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID) != nil {
                        MirageLogger.host(
                            "event=visible_frame_drift_stability state=reset stream=\(streamID) reason=resize_in_flight"
                        )
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        break
                    }
                    continue
                }

                let displayBounds = CGVirtualDisplayBridge.displayBounds(
                    state.displayID,
                    knownResolution: SharedVirtualDisplayManager.logicalResolution(
                        for: state.pixelResolution,
                        scaleFactor: max(1.0, state.scaleFactor)
                    )
                )
                var visibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
                    state.displayID,
                    knownBounds: displayBounds
                )
                visibleBounds = visibleBounds.intersection(displayBounds)
                if visibleBounds.isEmpty {
                    visibleBounds = displayBounds
                }
                let currentVisiblePixels = CGSize(
                    width: max(1, ceil(visibleBounds.width * max(1.0, state.scaleFactor))),
                    height: max(1, ceil(visibleBounds.height * max(1.0, state.scaleFactor)))
                )

                let widthDelta = abs(currentVisiblePixels.width - state.displayVisiblePixelResolution.width)
                let heightDelta = abs(currentVisiblePixels.height - state.displayVisiblePixelResolution.height)
                let displayWidthDelta = abs(currentVisiblePixels.width - state.pixelResolution.width)
                let displayHeightDelta = abs(currentVisiblePixels.height - state.pixelResolution.height)
                let directVisibleMatch = widthDelta <= driftTolerancePixels && heightDelta <= driftTolerancePixels
                let displayPixelMatch = displayWidthDelta <= driftTolerancePixels && displayHeightDelta <=
                    driftTolerancePixels
                let drifted = !(directVisibleMatch || displayPixelMatch)
                if drifted {
                    let existingDriftState = windowVisibleFrameDriftStateByStreamID[streamID]
                    let sameCandidateAsPrevious: Bool = if let existingDriftState {
                        abs(existingDriftState.candidateBounds.minX - visibleBounds.minX) <= driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.minY - visibleBounds.minY) <=
                            driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.width - visibleBounds.width) <=
                            driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.height - visibleBounds.height) <=
                            driftSampleMatchTolerance &&
                            abs(
                                existingDriftState.candidateVisiblePixelResolution.width - currentVisiblePixels.width
                            ) <= driftSampleMatchTolerance &&
                            abs(
                                existingDriftState.candidateVisiblePixelResolution.height - currentVisiblePixels.height
                            ) <= driftSampleMatchTolerance
                    } else {
                        false
                    }
                    let nextSampleCount = sameCandidateAsPrevious
                        ? (existingDriftState?.consecutiveSamples ?? 0) + 1
                        : 1
                    windowVisibleFrameDriftStateByStreamID[streamID] = WindowVisibleFrameDriftState(
                        candidateBounds: visibleBounds,
                        candidateVisiblePixelResolution: currentVisiblePixels,
                        consecutiveSamples: nextSampleCount
                    )
                    MirageLogger.host(
                        "event=visible_frame_drift_stability state=candidate stream=\(streamID) " +
                            "samples=\(nextSampleCount)/\(stableDriftSampleThreshold) " +
                            "cached=\(Int(state.displayVisiblePixelResolution.width))x\(Int(state.displayVisiblePixelResolution.height)) " +
                            "candidate=\(Int(currentVisiblePixels.width))x\(Int(currentVisiblePixels.height))"
                    )
                    if nextSampleCount >= stableDriftSampleThreshold {
                        MirageLogger.host(
                            "event=visible_frame_drift_stability state=stable stream=\(streamID) " +
                                "samples=\(nextSampleCount)"
                        )
                        var targetContentAspectRatio: CGFloat?
                        if let currentState = virtualDisplayState(windowID: windowID), currentState.streamID == streamID {
                            targetContentAspectRatio = currentState.targetContentAspectRatio
                            let updatedBounds = aspectFittedWindowBounds(
                                visibleBounds,
                                targetAspectRatio: currentState.targetContentAspectRatio
                            )
                            let updatedState = WindowVirtualDisplayState(
                                streamID: currentState.streamID,
                                displayID: currentState.displayID,
                                generation: currentState.generation,
                                bounds: updatedBounds,
                                displayVisibleBounds: visibleBounds,
                                targetContentAspectRatio: currentState.targetContentAspectRatio,
                                captureSourceRect: currentState.captureSourceRect,
                                visiblePixelResolution: CGSize(
                                    width: max(1, ceil(updatedBounds.width * max(1.0, currentState.scaleFactor))),
                                    height: max(1, ceil(updatedBounds.height * max(1.0, currentState.scaleFactor)))
                                ),
                                displayVisiblePixelResolution: currentVisiblePixels,
                                scaleFactor: currentState.scaleFactor,
                                pixelResolution: currentState.pixelResolution,
                                clientScaleFactor: currentState.clientScaleFactor
                            )
                            setVirtualDisplayState(windowID: windowID, state: updatedState)
                            inputStreamCache.updateWindowFrame(streamID, newFrame: updatedBounds)
                        }
                        windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
                        let didRepairPlacement = await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)
                        if !didRepairPlacement {
                            await refreshSharedDisplayAppCaptureStateBestEffort(
                                streamID: streamID,
                                reason: "visible frame drift",
                                targetContentAspectRatioOverride: targetContentAspectRatio
                            )
                        }
                    }
                } else if windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID) != nil {
                    MirageLogger.host(
                        "event=visible_frame_drift_stability state=reset stream=\(streamID) reason=drift_cleared"
                    )
                }

                _ = await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)

                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    break
                }
            }
            windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
            windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
        }
    }

    /// Stops visible-frame drift monitoring for a window stream.
    func stopWindowVisibleFrameMonitor(streamID: StreamID) {
        windowVisibleFrameMonitorTasks[streamID]?.cancel()
        windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
        windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
    }
}
#endif
