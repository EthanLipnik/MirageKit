//
//  MirageClientService+MessageHandling+Desktop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Desktop stream control message handling.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    private func handleDesktopResizeCommit(_ started: DesktopStreamStartedMessage) async -> Bool {
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

        let previousDisplaySize = desktopStreamResolution
        let previousPresentationSize = desktopStreamPresentationResolution
        let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[streamID] ?? mirageDefaultMaxPacketSize
        let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(started.acceptedMediaMaxPacketSize)
        let previousCodec = activeStreamCodecs[streamID]

        desktopStreamID = streamID
        let displaySize = CGSize(width: started.width, height: started.height)
        desktopStreamResolution = displaySize
        let presentationSize = started.presentationSize
        desktopStreamPresentationResolution = presentationSize
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

        let geometryChanged = desktopStreamStartGeometryChanged(
            previousDisplaySize: previousDisplaySize,
            previousPresentationSize: previousPresentationSize,
            nextDisplaySize: displaySize,
            nextPresentationSize: presentationSize
        )
        let packetSizeChanged = previousMediaMaxPacketSize != acceptedMediaMaxPacketSize
        let codecChanged = previousCodec.map { $0 != started.codec } ?? false
        if !geometryChanged, !packetSizeChanged, !codecChanged {
            if let dimensionToken = started.dimensionToken,
               let existingController = controllersByStream[streamID] {
                let reassembler = await existingController.getReassembler()
                reassembler.updateExpectedDimensionToken(dimensionToken)
            }
            sessionStore.clearPostResizeTransition(for: streamID)
            await applyStreamCadenceTarget(
                started.frameRate,
                for: streamID,
                reason: "desktop resize metadata refresh"
            )
            mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
            desktopResizeCoordinator.finishTransition()
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            MirageLogger.client(
                "Desktop resize commit refreshed stream metadata without decoder reset for stream \(streamID)"
            )
            return true
        }

        if started.allowsClientResize {
            beginPostResizeTransition(streamID: streamID, scheduleTimeout: true)
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
                let tokenText = dimensionToken.map(String.init) ?? "nil"
                let previousTokenText = previousDimensionToken.map(String.init) ?? "nil"
                let reasonText: String = switch acceptanceDecision {
                case .ignoreDuplicateToken:
                    "duplicate dimension token \(tokenText)"
                case .ignoreOlderToken:
                    "older dimension token \(tokenText) < \(previousTokenText)"
                case .ignoreMissingTokenAfterTokenizedStart:
                    "missing dimension token after prior token \(previousTokenText)"
                case .accept,
                     .acceptResizeAdvance:
                    "accepted"
                }
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID): \(reasonText)"
                )
                return
            }
            let displaySize = CGSize(width: started.width, height: started.height)
            let presentationSize = started.presentationSize
            let isResizeTokenAdvance = acceptanceDecision == .acceptResizeAdvance &&
                desktopStreamStartGeometryChanged(
                    previousDisplaySize: isActiveDesktopSession ? desktopStreamResolution : nil,
                    previousPresentationSize: isActiveDesktopSession ? desktopStreamPresentationResolution : nil,
                    nextDisplaySize: displaySize,
                    nextPresentationSize: presentationSize
                )
            let resetDecision = desktopStreamStartResetDecision(
                streamID: streamID,
                previousStreamID: isActiveDesktopSession ? previousStreamID : nil,
                hasController: isActiveDesktopSession ? hasController : false,
                requestStartPending: requestStartPending,
                previousDimensionToken: previousDimensionToken,
                receivedDimensionToken: dimensionToken
            )
            let shouldResetController = resetDecision == .resetController
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
            desktopStreamResolution = displaySize
            desktopStreamPresentationResolution = presentationSize
            desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
                logicalResolution: presentationSize,
                displayPixelSize: displaySize
            )
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
                lastAutomaticDesktopWorkloadReconfigurationSummary = nil
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
            desktopStreamRestartAttempts = 0
            if desktopStreamRequestStartTime > 0 {
                let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStreamRequestStartTime) * 1000)
                MirageLogger
                    .client("Desktop start: desktopStreamStarted received for stream \(streamID) (+\(deltaMs)ms)")
                streamStartupBaseTimes[streamID] = desktopStreamRequestStartTime
                streamStartupFirstRegistrationSent.remove(streamID)
                streamStartupFirstPacketReceived.remove(streamID)
                markStartupPacketPending(streamID)
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
            self.addActiveStreamID(streamID)

            if let startupAttemptID {
                await self.sendStreamReadyAck(
                    streamID: streamID,
                    startupAttemptID: startupAttemptID,
                    kind: .desktop
                )
            }

            if !self.registeredStreamIDs.contains(streamID) {
                self.registeredStreamIDs.insert(streamID)
                let refreshRate = self.refreshRateOverridesByStream[streamID] ?? self.getScreenMaxRefreshRate()
                try? await self.sendStreamRefreshRateChange(
                    streamID: streamID,
                    maxRefreshRate: refreshRate
                )
                MirageLogger
                    .client(
                        "Desktop start: refresh override sync sent for stream \(streamID): \(refreshRate)Hz"
                    )
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
            delegate?.didEncounterError(MirageError.protocolError("Desktop stream failed: \(failed.reason)"))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream failed: ")
            clearPendingDesktopStreamStartState()
            delegate?.didEncounterError(MirageError.protocolError("Desktop stream start failed (unknown reason)"))
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
            if hadLocalDesktopState {
                recordRetiredStreamDiagnosticsSummary(
                    streamID: streamID,
                    reason: "desktop:\(stopped.reason)"
                )
            }

            retiredDesktopSessionIDs.insert(stopped.desktopSessionID)
            desktopStreamID = nil
            desktopSessionID = nil
            desktopStreamResolution = nil
            desktopStreamPresentationResolution = nil
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

            removeActiveStreamID(streamID)
            stopVideoStreamReceive(for: streamID)
            registeredStreamIDs.remove(streamID)
            streamStartupBaseTimes.removeValue(forKey: streamID)
            streamStartupFirstRegistrationSent.remove(streamID)
            streamStartupFirstPacketReceived.remove(streamID)
            clearStartupPacketPending(streamID)
            cancelStartupRegistrationRetry(streamID: streamID)
            cancelRecoveryKeyframeRetry(for: streamID)
            pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
            clearDecoderColorDepthState(for: streamID)
            inputEventSender.clearTemporaryPointerCoalescing(for: streamID)
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
