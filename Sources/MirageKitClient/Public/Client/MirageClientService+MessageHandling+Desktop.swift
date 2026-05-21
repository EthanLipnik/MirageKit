//
//  MirageClientService+MessageHandling+Desktop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Desktop stream control message handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleDesktopStreamStarted(_ message: ControlMessage) async {
        do {
            let started = try message.decode(DesktopStreamStartedMessage.self)
            let streamID = started.streamID
            let receivedDesktopSessionID = started.desktopSessionID
            let requestStartPending = desktopStreamRequestStartTime > 0
            MirageLogger
                .client("Desktop stream started: stream=\(streamID), \(started.width)x\(started.height)")
            if pendingLocalDesktopStopStreamID == streamID,
               pendingLocalDesktopStopSessionID == receivedDesktopSessionID {
                MirageLogger.client(
                    "Ignoring desktopStreamStarted for locally stopping stream \(streamID), session=\(receivedDesktopSessionID.uuidString)"
                )
                return
            }
            if retiredDesktopSessionIDs.contains(receivedDesktopSessionID) {
                MirageLogger.client(
                    "Ignoring desktopStreamStarted for retired desktop session \(receivedDesktopSessionID.uuidString), stream=\(streamID)"
                )
                return
            }
            if desktopStreamID == nil, desktopSessionID == nil, !requestStartPending {
                MirageLogger.client(
                    "Ignoring orphaned desktopStreamStarted for stream \(streamID), session=\(receivedDesktopSessionID.uuidString)"
                )
                return
            }
            if started.transitionPhase == .resize || started.transitionID != nil {
                _ = await handleDesktopResizeCommit(started)
                return
            }
            let startupAttemptID = started.startupAttemptID
            guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
                )
                return
            }
            let previousStreamID = desktopStreamID
            let previousDesktopSessionID = desktopSessionID
            let hasController = controllersByStream[streamID] != nil
            if let previousDesktopSessionID,
               previousDesktopSessionID != receivedDesktopSessionID,
               !requestStartPending {
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID): session=\(receivedDesktopSessionID.uuidString) activeSession=\(previousDesktopSessionID.uuidString)"
                )
                return
            }
            let isActiveDesktopSession = previousDesktopSessionID == receivedDesktopSessionID
            let previousDimensionToken = isActiveDesktopSession
                ? desktopDimensionTokenByStream[streamID]
                : nil
            let dimensionToken = started.dimensionToken
            let acceptanceDecision = desktopStreamStartAcceptanceDecision(
                streamID: streamID,
                previousStreamID: isActiveDesktopSession ? previousStreamID : nil,
                hasController: isActiveDesktopSession ? hasController : false,
                requestStartPending: requestStartPending,
                previousDimensionToken: previousDimensionToken,
                receivedDimensionToken: dimensionToken
            )
            guard acceptanceDecision.shouldAccept else {
                let reasonText = acceptanceDecision.rejectionReasonText(
                    previousDimensionToken: previousDimensionToken,
                    receivedDimensionToken: dimensionToken
                )
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID): \(reasonText)"
                )
                return
            }
            let isResizeTokenAdvance = acceptanceDecision == .acceptResizeAdvance
            let shouldResetController =
                requestStartPending ||
                !isActiveDesktopSession ||
                previousStreamID != streamID ||
                !hasController ||
                isResizeTokenAdvance
            if let previousDimensionToken, let dimensionToken, previousDimensionToken != dimensionToken,
               previousStreamID == streamID, hasController {
                MirageLogger
                    .client(
                        "Desktop stream token advanced \(previousDimensionToken) -> \(dimensionToken); resetting controller"
                    )
                beginStreamStartupCriticalSection(streamID: streamID)
            }
            if isResizeTokenAdvance {
                beginPostResizeTransition(streamID: streamID, scheduleTimeout: false)
            }
            if previousDesktopSessionID != receivedDesktopSessionID {
                sessionStore.resetFirstFrameReadiness(for: streamID)
                desktopDimensionTokenByStream.removeValue(forKey: streamID)
                if let previousDesktopSessionID {
                    desktopPresentationGenerationBySessionID.removeValue(forKey: previousDesktopSessionID)
                }
                if let previousStreamID {
                    clearDesktopResizeState(streamID: previousStreamID, preserveLastSentTarget: true)
                    desktopDimensionTokenByStream.removeValue(forKey: previousStreamID)
                } else {
                    desktopResizeCoordinator.clearAllState(preserveLastSentTarget: true)
                }
                cancelDesktopStreamStopTimeout()
            }
            desktopStreamID = streamID
            desktopSessionID = receivedDesktopSessionID
            let displaySize = CGSize(width: started.width, height: started.height)
            desktopStreamResolution = displaySize
            let presentationSize = started.presentationSize
            desktopStreamPresentationResolution = presentationSize
            desktopStreamDisplayScaleFactor = acceptedDesktopDisplayScaleFactor(
                from: started,
                displayPixelSize: displaySize,
                presentationSize: presentationSize
            )
            desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
                logicalResolution: presentationSize,
                displayPixelSize: displaySize
            )
            desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedDisplayPixels(displaySize)
            desktopCaptureSource = started.captureSource
            desktopStreamAllowsClientResize = started.allowsClientResize
            if let generation = started.desktopPresentationGeneration {
                desktopPresentationGenerationBySessionID[receivedDesktopSessionID] = generation
            }
            if !started.allowsClientResize {
                desktopResizeCoordinator.clearAllState()
                sessionStore.clearPostResizeTransition(for: streamID)
            }
            activeStreamCodecs[streamID] = started.codec
            if let dimensionToken {
                desktopDimensionTokenByStream[streamID] = dimensionToken
            }
            if let previousStreamID, previousStreamID != streamID {
                desktopDimensionTokenByStream.removeValue(forKey: previousStreamID)
            }
            applyRenderLatencyMode(
                to: streamID,
                preferredLatencyMode: pendingStreamSetupLatencyMode ?? pendingDesktopRequestedLatencyMode
            )
            await applyStreamCadenceTarget(
                started.frameRate,
                for: streamID,
                reason: "desktop stream started"
            )
            refreshRateOverridesByStream[streamID] = MirageRenderModePolicy.normalizedTargetFPS(started.frameRate)
            configureDecoderColorDepthBaseline(
                for: streamID,
                colorDepth: pendingDesktopRequestedColorDepth
            )
            desktopStreamStartTimeoutTask?.cancel()
            desktopStreamStartTimeoutTask = nil
            if desktopStreamRequestStartTime > 0 {
                let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStreamRequestStartTime) * 1000)
                MirageLogger
                    .client("Desktop start: desktopStreamStarted received for stream \(streamID) (+\(deltaMs)ms)")
                streamStartupBaseTimes[streamID] = desktopStreamRequestStartTime
                streamStartupFirstRegistrationSent.remove(streamID)
                streamStartupFirstPacketReceived.remove(streamID)
                fastPathState.markStartupPacketPending(streamID)
                desktopStreamRequestStartTime = 0
            }
            registerStartupAttempt(startupAttemptID, for: streamID)

            if shouldResetController {
                await self.setupControllerForStream(
                    streamID,
                    beginPostResizeTransition: isResizeTokenAdvance,
                    codec: started.codec,
                    streamDimensions: (width: started.width, height: started.height),
                    mediaMaxPacketSize: started.acceptedMediaMaxPacketSize,
                    dimensionToken: dimensionToken,
                    targetFrameRate: started.frameRate
                )
            }
            self.fastPathState.addActiveStreamID(streamID)
            self.processBufferedEarlyVideoPacketIfNeeded(streamID: streamID)

            if let startupAttemptID {
                await self.sendStreamReadyAck(
                    streamID: streamID,
                    startupAttemptID: startupAttemptID,
                    kind: .desktop
                )
            }

            if !self.registeredStreamIDs.contains(streamID) {
                self.registeredStreamIDs.insert(streamID)
                let refreshRate = self.refreshRateOverridesByStream[streamID] ?? self.screenMaxRefreshRate
                do {
                    try await self.sendStreamRefreshRateChange(
                        streamID: streamID,
                        maxRefreshRate: refreshRate
                    )
                    MirageLogger
                        .client(
                            "Desktop start: refresh override sync sent for stream \(streamID): \(refreshRate)Hz"
                        )
                } catch {
                    MirageLogger.error(.client, error: error, message: "Failed to sync desktop refresh override: ")
                }
                MirageLogger.client("Registered for desktop stream video \(streamID)")
                self.startStartupRegistrationRetry(streamID: streamID)
            }

            onDesktopStreamStarted?(
                streamID,
                presentationSize,
                started.displayCount
            )
            clearPendingStreamSetup(kind: .desktop)

            let desktopMinSize = presentationSize
            sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
            onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
            await refreshSharedClipboardBridgeState()
            if isResizeTokenAdvance {
                schedulePostResizeTransitionTimeoutIfNeeded(streamID: streamID)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream started: ")
            if desktopStreamRequestStartTime > 0 {
                cancelStreamSetup()
                clearPendingDesktopStreamStartState()
                delegate?.didEncounterError(
                    MirageError.protocolError("Desktop stream failed: invalid start response from host.")
                )
            }
        }
    }

    func handleDesktopStreamFailed(_ message: ControlMessage) {
        do {
            let failed = try message.decode(DesktopStreamFailedMessage.self)
            MirageLogger.error(.client, "Desktop stream start failed: \(failed.reason)")
            if let streamID = desktopStreamID {
                clearStartupAttempt(for: streamID)
                clearDesktopResizeState(streamID: streamID)
            }
            clearPendingDesktopStreamStartState()
            delegate?.didEncounterError(
                MirageError.protocolError("Desktop stream failed: \(failed.reason)")
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream failed: ")
            clearPendingDesktopStreamStartState()
            delegate?.didEncounterError(
                MirageError.protocolError("Desktop stream start failed (unknown reason)")
            )
        }
    }

    func handleDesktopStreamStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(DesktopStreamStoppedMessage.self)
            let streamID = stopped.streamID
            guard desktopSessionID == stopped.desktopSessionID else {
                MirageLogger.client(
                    "Ignoring stale desktopStreamStopped for stream \(streamID): session=\(stopped.desktopSessionID.uuidString) activeSession=\(desktopSessionID?.uuidString ?? "nil")"
                )
                return
            }
            guard desktopStreamID == nil || desktopStreamID == streamID else {
                MirageLogger.client(
                    "Ignoring desktopStreamStopped for mismatched active stream \(streamID): activeStream=\(desktopStreamID.map(String.init) ?? "nil")"
                )
                return
            }
            cancelDesktopStreamStopTimeout()
            let hadLocalDesktopState = desktopStreamID == streamID ||
                controllersByStream[streamID] != nil ||
                registeredStreamIDs.contains(streamID)
            MirageLogger.client("Desktop stream stopped: stream=\(streamID), reason=\(stopped.reason)")

            retiredDesktopSessionIDs.insert(stopped.desktopSessionID)
            desktopStreamID = nil
            desktopSessionID = nil
            desktopStreamResolution = nil
            desktopStreamPresentationResolution = nil
            desktopStreamDisplayScaleFactor = nil
            desktopCaptureSource = .virtualDisplay
            desktopStreamAllowsClientResize = true
            desktopStreamMode = nil
            desktopCursorPresentation = nil
            desktopPresentationGenerationBySessionID.removeValue(forKey: stopped.desktopSessionID)
            desktopDimensionTokenByStream.removeValue(forKey: streamID)
            clearStartupAttempt(for: streamID)
            clearDesktopResizeState(streamID: streamID)
            metricsStore.clear(streamID: streamID)
            cursorStore.clear(streamID: streamID)
            cursorPositionStore.clear(streamID: streamID)
            clearStreamRefreshRateOverride(streamID: streamID)

            fastPathState.removeActiveStreamID(streamID)
            stopVideoStreamReceive(for: streamID)
            registeredStreamIDs.remove(streamID)
            streamStartupBaseTimes.removeValue(forKey: streamID)
            streamStartupFirstRegistrationSent.remove(streamID)
            streamStartupFirstPacketReceived.remove(streamID)
            fastPathState.clearStartupPacketPending(streamID)
            cancelStartupRegistrationRetry(streamID: streamID)
            cancelRecoveryKeyframeRetry(for: streamID)
            pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
            clearDecoderColorDepthState(for: streamID)
            pendingDesktopRequestedColorDepth = nil
            pendingDesktopRequestedLatencyMode = nil
            renderLatencyModeByStream.removeValue(forKey: streamID)
            activeJitterHoldMs = 0
            mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
            activeStreamCodecs.removeValue(forKey: streamID)
            let controller = controllersByStream.removeValue(forKey: streamID)

            Task {
                if let controller {
                    await controller.stop()
                }
                await self.updateReassemblerSnapshot()
            }

            if hadLocalDesktopState {
                onDesktopStreamStopped?(streamID, stopped.reason)
            }
            Task { await self.refreshSharedClipboardBridgeState() }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream stopped: ")
        }
    }
}
