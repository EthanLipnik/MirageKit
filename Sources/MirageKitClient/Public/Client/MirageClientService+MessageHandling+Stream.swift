//
//  MirageClientService+MessageHandling+Stream.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Stream control message handling.
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
import CoreGraphics
import Foundation

@MainActor
extension MirageClientService {
    /// Handles host confirmation that a window stream is ready and prepares the matching decoder path.
    func handleStreamStarted(_ message: MirageWire.ControlMessage) async {
        let started: MirageWire.StreamStartedMessage
        do {
            started = try message.decode(MirageWire.StreamStartedMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode stream started message: "
            )
            return
        }
        let streamID = started.streamID
        let startupAttemptID = started.startupAttemptID
        guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
            MirageLogger.client(
                "Ignoring stale streamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
            )
            return
        }
        MirageLogger.client("Stream started: \(streamID) for window \(started.windowID)")
        let resolvedWindow = resolveWindowForStartedStream(
            streamID: streamID,
            started: started
        )
        upsertActiveStreamSession(
            streamID: streamID,
            window: resolvedWindow
        )

        refreshRateOverridesByStream[streamID] = MirageRenderModePolicy.normalizedTargetFPS(
            started.frameRate
        )
        await applyStreamCadenceTarget(
            started.frameRate,
            for: streamID,
            reason: "window stream started"
        )

        let dimensionToken = started.dimensionToken
        let hasController = controllersByStream[streamID] != nil
        let isExistingStream =
            activeStreams.contains(where: { $0.id == streamID })
            || sessionStore.sessionByStreamID(streamID) != nil
        let previousDimensionToken = appDimensionTokenByStream[streamID]
        let didAdvanceDimensionToken =
            if let previousDimensionToken, let dimensionToken {
                previousDimensionToken != dimensionToken
            } else {
                false
            }
        let shouldResetController =
            streamStartedContinuation != nil ||
            !isExistingStream ||
            !hasController ||
            didAdvanceDimensionToken
        let shouldSetupController = shouldResetController || !hasController
        let wasRegistered = registeredStreamIDs.contains(streamID)
        let shouldRegisterVideo = !wasRegistered || !hasController || shouldResetController
        let shouldBeginPostResizeTransition =
            didAdvanceDimensionToken && isExistingStream && hasController
        if didAdvanceDimensionToken,
           let previousDimensionToken,
           let dimensionToken {
            MirageLogger
                .client(
                    "App stream token advanced \(previousDimensionToken) -> \(dimensionToken); reset=\(shouldResetController)"
                )
            beginStreamStartupCriticalSection(streamID: streamID)
            beginPostResizeTransition(streamID: streamID)
        }
        if let dimensionToken {
            appDimensionTokenByStream[streamID] = dimensionToken
        }
        appStreamStartAcknowledgementByStreamID[streamID] = StreamStartAcknowledgement(
            width: started.width,
            height: started.height,
            dimensionToken: dimensionToken
        )

        let isAppCentricStream = streamStartedContinuation == nil
        if !isAppCentricStream, let minW = started.minWidth, let minH = started.minHeight {
            streamMinSizes[streamID] = (minWidth: minW, minHeight: minH)
            MirageLogger.client("Minimum window size: \(minW)x\(minH) pts")
            let minSize = CGSize(width: minW, height: minH)
            sessionStore.updateMinimumSize(for: streamID, minSize: minSize)
            onStreamMinimumSizeUpdate?(streamID, minSize)
        }

        streamStartedContinuation?.resume(returning: streamID)
        streamStartedContinuation = nil
        let shouldMarkStartupPending = isAppCentricStream && shouldRegisterVideo

        if shouldMarkStartupPending {
            streamStartupBaseTimes[streamID] = CFAbsoluteTimeGetCurrent()
            streamStartupFirstRegistrationSent.remove(streamID)
            streamStartupFirstPacketReceived.remove(streamID)
            fastPathState.markStartupPacketPending(streamID)
        }
        registerStartupAttempt(startupAttemptID, for: streamID)
        activeStreamCodecs[streamID] = started.codec

        if shouldSetupController {
            await setupControllerForStream(
                streamID,
                beginPostResizeTransition: shouldBeginPostResizeTransition,
                codec: started.codec,
                mediaMaxPacketSize: started.acceptedMediaMaxPacketSize,
                dimensionToken: dimensionToken,
                targetFrameRate: started.frameRate
            )
        }
        fastPathState.addActiveStreamID(streamID)
        processBufferedEarlyVideoPacketIfNeeded(streamID: streamID)
        if isAppCentricStream, shouldSetupController {
            MirageLogger.client("Controller set up for app-centric stream \(streamID)")
        }

        if let startupAttemptID {
            await sendStreamReadyAck(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                kind: .window
            )
        }

        if shouldRegisterVideo {
            registeredStreamIDs.insert(streamID)
            let refreshRate =
                refreshRateOverridesByStream[streamID] ?? screenMaxRefreshRate
            do {
                try await sendStreamRefreshRateChange(
                    streamID: streamID,
                    maxRefreshRate: refreshRate
                )
                MirageLogger.client(
                    "Refresh override sync sent for stream \(streamID): \(refreshRate)Hz"
                )
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to sync refresh override: ")
            }
            if shouldMarkStartupPending {
                startStartupRegistrationRetry(streamID: streamID)
            }
        }
    }

    /// Applies host stream metrics to diagnostics, cadence control, and refresh-rate fallback state.
    func handleStreamMetricsUpdate(_ message: MirageWire.ControlMessage) {
        let metrics: MirageWire.StreamMetricsMessage
        do {
            metrics = try message.decode(MirageWire.StreamMetricsMessage.self)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode stream metrics: ")
            return
        }
        updateObservedFrameRate(metrics.targetFrameRate, for: metrics.streamID)
        if let mosaicTilePlan = metrics.mosaicTilePlan {
            mosaicTilePlansByStreamID[metrics.streamID] = mosaicTilePlan
            fastPathState.setMosaicTilePlan(mosaicTilePlan, for: metrics.streamID)
            processBufferedMosaicUnitsIfNeeded(streamID: metrics.streamID)
        }
        if let mosaicEpochSummary = metrics.mosaicEpochSummary {
            mosaicEpochSummariesByStreamID[metrics.streamID] = mosaicEpochSummary
        }
        if let controller = controllersByStream[metrics.streamID] {
            let requestedLatencyMode = renderLatencyModeByStream[metrics.streamID]
            let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
            Task {
                await controller.updateHostMetrics(metrics)
                await controller.updateCadenceTarget(
                    sourceFPS: metrics.targetFrameRate,
                    displayFPS: metrics.targetFrameRate,
                    latencyMode: latencyMode,
                    playoutDelayFrames: resolvedStreamPlayoutDelayFrames(for: latencyMode),
                    reason: "host metrics"
                )
            }
        }
        metricsStore.updateHostMetrics(metrics)
        metricsStore.updateHostPipelineMetrics(metrics)
        if let requested = refreshRateOverridesByStream[metrics.streamID] {
            guard metrics.streamID == desktopStreamID else {
                refreshRateMismatchCounts.removeValue(forKey: metrics.streamID)
                refreshRateFallbackTargets.removeValue(forKey: metrics.streamID)
                return
            }
            if requested != metrics.targetFrameRate {
                let updatedCount = (refreshRateMismatchCounts[metrics.streamID] ?? 0) + 1
                refreshRateMismatchCounts[metrics.streamID] = updatedCount
                if updatedCount == 2 {
                    MirageLogger.client(
                        "Refresh override pending for stream \(metrics.streamID): requested \(requested)Hz, host \(metrics.targetFrameRate)Hz"
                    )
                }
                let fallbackThreshold = 4
                if updatedCount >= fallbackThreshold {
                    let lastFallback = refreshRateFallbackTargets[metrics.streamID]
                    if lastFallback != requested {
                        refreshRateFallbackTargets[metrics.streamID] = requested
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                try await self.sendStreamRefreshRateChange(
                                    streamID: metrics.streamID,
                                    maxRefreshRate: requested,
                                    forceDisplayRefresh: true
                                )
                            } catch {
                                MirageLogger.error(.client, error: error, message: "Failed to send refresh override fallback: ")
                            }
                        }
                        MirageLogger.client(
                            "Refresh override fallback requested for stream \(metrics.streamID): \(requested)Hz"
                        )
                    }
                }
            } else {
                refreshRateMismatchCounts.removeValue(forKey: metrics.streamID)
                refreshRateFallbackTargets.removeValue(forKey: metrics.streamID)
            }
        }
    }

    /// Responds to host transport-refresh requests by asking active streams for fresh keyframes.
    func handleTransportRefreshRequest(_ message: MirageWire.ControlMessage) {
        do {
            let request = try message.decode(MirageWire.TransportRefreshRequestMessage.self)
            transportRefreshRequests &+= 1
            MirageLogger.client(
                "Host transport refresh request received: reason=\(request.reason), stream=\(request.streamID.map(String.init) ?? "all"), count=\(transportRefreshRequests)"
            )
            let activeIDs = activeStreamIDsForFiltering
            let targetIDs: [StreamID] =
                if let filterID = request.streamID {
                    activeIDs.contains(filterID) ? [filterID] : []
                } else {
                    activeIDs.sorted()
                }
            for streamID in targetIDs {
                sendKeyframeRequest(for: streamID)
            }
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode transport refresh request: "
            )
        }
    }

    /// Inserts or refreshes the client-side session record for an active stream.
    func upsertActiveStreamSession(
        streamID: StreamID,
        window: MirageMedia.MirageWindow,
        kind: MirageMedia.MirageStreamKind = .app
    ) {
        let session = ClientStreamSession(
            id: streamID, window: window, kind: kind, mediaStreamID: streamID
        )
        if let index = activeStreams.firstIndex(where: { $0.id == streamID }) {
            activeStreams[index] = session
        } else {
            activeStreams.append(session)
        }
        Task { await refreshSharedClipboardBridgeState() }
    }
}

private extension MirageClientService {
    /// Resolves the window metadata associated with a newly started app stream.
    func resolveWindowForStartedStream(
        streamID: StreamID,
        started: MirageWire.StreamStartedMessage
    ) -> MirageMedia.MirageWindow {
        let fallbackFrame = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, started.width)),
            height: CGFloat(max(1, started.height))
        )
        let windowTemplate =
            activeStreams.first(where: { $0.id == streamID })?.window
                ?? sessionStore.sessionByStreamID(
                    streamID
                )?.window ?? availableWindows.first(where: { $0.id == started.windowID })

        guard let template = windowTemplate else {
            return MirageMedia.MirageWindow(
                id: started.windowID,
                title: nil,
                application: nil,
                frame: fallbackFrame,
                isOnScreen: true,
                windowLayer: 0
            )
        }

        let templateFrame = template.frame
        let mergedFrame = CGRect(
            x: templateFrame.origin.x,
            y: templateFrame.origin.y,
            width: CGFloat(max(1, started.width)),
            height: CGFloat(max(1, started.height))
        )

        return MirageMedia.MirageWindow(
            id: started.windowID,
            title: template.title,
            application: template.application,
            frame: mergedFrame,
            isOnScreen: template.isOnScreen,
            windowLayer: template.windowLayer
        )
    }
}
