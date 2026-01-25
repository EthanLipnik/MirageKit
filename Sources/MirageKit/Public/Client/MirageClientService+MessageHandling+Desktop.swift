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

@MainActor
extension MirageClientService {
    func handleDesktopStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(DesktopStreamStartedMessage.self)
            MirageLogger.client("Desktop stream started: stream=\(started.streamID), \(started.width)x\(started.height)")
            let streamID = started.streamID
            desktopStreamID = streamID
            desktopStreamResolution = CGSize(width: started.width, height: started.height)
            refreshRateOverridesByStream[streamID] = getScreenMaxRefreshRate()

            let dimensionToken = started.dimensionToken

            Task {
                await self.setupControllerForStream(streamID)
                self.addActiveStreamID(streamID)

                if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                    let reassembler = await controller.getReassembler()
                    reassembler.updateExpectedDimensionToken(token)
                }

                if !self.registeredStreamIDs.contains(streamID) {
                    self.registeredStreamIDs.insert(streamID)
                    do {
                        if self.udpConnection == nil {
                            try await self.startVideoConnection()
                        }
                        try await self.sendStreamRegistration(streamID: streamID)
                        MirageLogger.client("Registered for desktop stream video \(streamID)")
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection for desktop stream: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                    }
                }
            }

            onDesktopStreamStarted?(streamID, CGSize(width: started.width, height: started.height), started.displayCount)

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
            metricsStore.clear(streamID: streamID)
            cursorStore.clear(streamID: streamID)
            clearStreamRefreshRateOverride(streamID: streamID)

            removeActiveStreamID(streamID)
            registeredStreamIDs.remove(streamID)

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
