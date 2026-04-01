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
    func handleDesktopStreamStarted(_ message: ControlMessage) async {
        do {
            let started = try message.decode(DesktopStreamStartedMessage.self)
            MirageLogger
                .client("Desktop stream started: stream=\(started.streamID), \(started.width)x\(started.height)")
            let streamID = started.streamID
            let startupAttemptID = started.startupAttemptID
            guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
                MirageLogger.client(
                    "Ignoring stale desktopStreamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
                )
                return
            }
            let previousStreamID = desktopStreamID
            let hasController = controllersByStream[streamID] != nil
            let previousDimensionToken = desktopDimensionTokenByStream[streamID]
            let dimensionToken = started.dimensionToken
            let isResizeTokenAdvance = if let previousDimensionToken, let dimensionToken {
                previousDimensionToken != dimensionToken && previousStreamID == streamID && hasController
            } else {
                false
            }
            let resetDecision = desktopStreamStartResetDecision(
                streamID: streamID,
                previousStreamID: previousStreamID,
                hasController: hasController,
                requestStartPending: desktopStreamRequestStartTime > 0,
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
            }
            if isResizeTokenAdvance {
                sessionStore.beginPostResizeTransition(for: streamID)
            }
            desktopStreamID = streamID
            desktopStreamResolution = CGSize(width: started.width, height: started.height)
            activeStreamCodecs[streamID] = started.codec
            if let dimensionToken {
                desktopDimensionTokenByStream[streamID] = dimensionToken
            }
            if let previousStreamID, previousStreamID != streamID {
                desktopDimensionTokenByStream.removeValue(forKey: previousStreamID)
            }
            let screenMaxRefreshRate = getScreenMaxRefreshRate()
            let existingRefreshRate = refreshRateOverridesByStream[streamID] ?? 0
            let desiredRefreshRate = max(existingRefreshRate, screenMaxRefreshRate)
            refreshRateOverridesByStream[streamID] = desiredRefreshRate >= 120 ? 120 : 60
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
            refreshSharedClipboardBridgeState()
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
            MirageLogger.client("Desktop stream stopped: stream=\(streamID), reason=\(stopped.reason)")

            desktopStreamID = nil
            desktopStreamResolution = nil
            desktopStreamMode = nil
            desktopCursorPresentation = nil
            desktopDimensionTokenByStream.removeValue(forKey: streamID)
            clearStartupAttempt(for: streamID)
            sessionStore.clearPostResizeTransition(for: streamID)
            metricsStore.clear(streamID: streamID)
            cursorStore.clear(streamID: streamID)
            cursorPositionStore.clear(streamID: streamID)
            clearStreamRefreshRateOverride(streamID: streamID)

            removeActiveStreamID(streamID)
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
                    self.heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
                }
                await self.updateReassemblerSnapshot()
            }

            onDesktopStreamStopped?(streamID, stopped.reason)
            refreshSharedClipboardBridgeState()
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode desktop stream stopped: ")
        }
    }
}
