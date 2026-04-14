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
        guard desktopResizeCoordinator.acceptTransition(
            streamID: streamID,
            transitionID: started.transitionID
        ) else {
            MirageLogger.client(
                "Ignoring stale desktop resize commit for stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
            )
            return false
        }

        guard desktopStreamID == streamID || controllersByStream[streamID] != nil else {
            MirageLogger.client(
                "Ignoring desktop resize commit for inactive stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
            )
            clearDesktopResizeState(streamID: streamID)
            return false
        }

        desktopStreamID = streamID
        desktopStreamResolution = CGSize(width: started.width, height: started.height)
        activeStreamCodecs[streamID] = started.codec
        if let dimensionToken = started.dimensionToken {
            desktopDimensionTokenByStream[streamID] = dimensionToken
        }

        let desktopMinSize = CGSize(width: started.width, height: started.height)
        sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
        onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
        onDesktopStreamStarted?(streamID, desktopMinSize, started.displayCount)

        let outcome = started.transitionOutcome ?? .resized
        if outcome == .noChange {
            sessionStore.clearPostResizeTransition(for: streamID)
            desktopResizeCoordinator.finishTransition(outcome: outcome)
            await dispatchQueuedDesktopResizeIfNeeded(streamID: streamID)
            return true
        }

        await prepareControllerForDesktopResize(
            streamID,
            codec: started.codec,
            streamDimensions: (width: started.width, height: started.height),
            mediaMaxPacketSize: started.acceptedMediaMaxPacketSize
        )
        if let dimensionToken = started.dimensionToken,
           let controller = controllersByStream[streamID] {
            let reassembler = await controller.getReassembler()
            reassembler.updateExpectedDimensionToken(dimensionToken)
        }
        sessionStore.beginPostResizeTransition(for: streamID)
        desktopResizeCoordinator.finishTransition(outcome: outcome)
        return true
    }

    func handleDesktopStreamStarted(_ message: ControlMessage) async {
        do {
            let started = try message.decode(DesktopStreamStartedMessage.self)
            MirageLogger
                .client("Desktop stream started: stream=\(started.streamID), \(started.width)x\(started.height)")
            if started.transitionPhase == .resize || started.transitionID != nil {
                _ = await handleDesktopResizeCommit(started)
                return
            }
            let streamID = started.streamID
            let receivedDesktopSessionID = started.desktopSessionID
            let startupAttemptID = started.startupAttemptID
            guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
                )
                return
            }
            let requestStartPending = desktopStreamRequestStartTime > 0
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
            let isResizeTokenAdvance = acceptanceDecision == .acceptResizeAdvance
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
                sessionStore.beginPostResizeTransition(for: streamID)
            }
            if previousDesktopSessionID != receivedDesktopSessionID {
                desktopDimensionTokenByStream.removeValue(forKey: streamID)
                if let previousStreamID {
                    clearDesktopResizeState(streamID: previousStreamID)
                    desktopDimensionTokenByStream.removeValue(forKey: previousStreamID)
                } else {
                    desktopResizeCoordinator.clearAllState()
                }
                cancelDesktopStreamStopTimeout()
            }
            desktopStreamID = streamID
            desktopSessionID = receivedDesktopSessionID
            desktopStreamResolution = CGSize(width: started.width, height: started.height)
            activeStreamCodecs[streamID] = started.codec
            if let dimensionToken {
                desktopDimensionTokenByStream[streamID] = dimensionToken
            }
            if let previousStreamID, previousStreamID != streamID {
                desktopDimensionTokenByStream.removeValue(forKey: previousStreamID)
            }
            let existingRefreshRate = refreshRateOverridesByStream[streamID] ?? 0
            let desiredRefreshRate = existingRefreshRate > 0 ? existingRefreshRate : getScreenMaxRefreshRate()
            refreshRateOverridesByStream[streamID] = MirageRenderModePolicy.normalizedTargetFPS(desiredRefreshRate)
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
                    mediaMaxPacketSize: started.acceptedMediaMaxPacketSize
                )
            }
            self.addActiveStreamID(streamID)

            if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                let reassembler = await controller.getReassembler()
                reassembler.updateExpectedDimensionToken(token)
            }

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
                CGSize(width: started.width, height: started.height),
                started.displayCount
            )

            let desktopMinSize = CGSize(width: started.width, height: started.height)
            sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
            onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
            await refreshSharedClipboardBridgeState()
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream started: ")
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
            delegate?.clientService(
                self,
                didEncounterError: MirageError.protocolError("Desktop stream failed: \(failed.reason)")
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream failed: ")
            clearPendingDesktopStreamStartState()
            delegate?.clientService(
                self,
                didEncounterError: MirageError.protocolError("Desktop stream start failed (unknown reason)")
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

            desktopStreamID = nil
            desktopSessionID = nil
            desktopStreamResolution = nil
            desktopStreamMode = nil
            desktopCursorPresentation = nil
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
            clearDecoderColorDepthState(for: streamID)
            inputEventSender.clearTemporaryPointerCoalescing(for: streamID)
            pendingDesktopRequestedColorDepth = nil
            activeJitterHoldMs = 0

            Task {
                if let controller = self.controllersByStream[streamID] {
                    await controller.stop()
                    self.controllersByStream.removeValue(forKey: streamID)
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
