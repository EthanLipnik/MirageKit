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
    func handleDesktopStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(DesktopStreamStartedMessage.self)
            MirageLogger
                .client("Desktop stream started: stream=\(started.streamID), \(started.width)x\(started.height)")
            let streamID = started.streamID
            let previousStreamID = desktopStreamID
            let hasController = controllersByStream[streamID] != nil
            let previousDimensionToken = desktopDimensionTokenByStream[streamID]
            let dimensionToken = started.dimensionToken
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
            desktopStreamID = streamID
            desktopStreamResolution = CGSize(width: started.width, height: started.height)
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
            configureAdaptiveFallbackBaseline(
                for: streamID,
                bitrate: pendingDesktopAdaptiveFallbackBitrate,
                bitDepth: pendingDesktopAdaptiveFallbackBitDepth
            )
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

            Task {
                if shouldResetController {
                    await self.setupControllerForStream(streamID)
                }
                self.addActiveStreamID(streamID)

                if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                    let reassembler = await controller.getReassembler()
                    reassembler.updateExpectedDimensionToken(token)
                }

                if !self.registeredStreamIDs.contains(streamID) {
                    self.registeredStreamIDs.insert(streamID)
                    do {
                        if self.udpConnection == nil { try await self.startVideoConnection() }
                        try await self.sendStreamRegistration(streamID: streamID)
                        await self.ensureAudioTransportRegistered(for: streamID)
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
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection for desktop stream: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                        self.clearStartupPacketPending(streamID)
                        self.cancelStartupRegistrationRetry(streamID: streamID)
                    }
                }
            }

            onDesktopStreamStarted?(
                streamID,
                CGSize(width: started.width, height: started.height),
                started.displayCount
            )

            let desktopMinSize = CGSize(width: started.width, height: started.height)
            sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
            onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
        } catch {
            MirageLogger.error(.client, "Failed to decode desktop stream started: \(error)")
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
            desktopDimensionTokenByStream.removeValue(forKey: streamID)
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
            clearAdaptiveFallbackState(for: streamID)
            pendingDesktopAdaptiveFallbackBitrate = nil
            pendingDesktopAdaptiveFallbackBitDepth = nil

            Task {
                if let controller = self.controllersByStream[streamID] {
                    await controller.stop()
                    self.controllersByStream.removeValue(forKey: streamID)
                }
                await self.updateReassemblerSnapshot()
            }

            onDesktopStreamStopped?(streamID, stopped.reason)
        } catch {
            MirageLogger.error(.client, "Failed to decode desktop stream stopped: \(error)")
        }
    }
}
