//
//  MirageClientService+MessageHandling+Core.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Core control message handling.
//

import CoreGraphics
import Foundation

@MainActor
extension MirageClientService {
    func handleHelloResponse(_ message: ControlMessage) {
        do {
            let response = try message.decode(HelloResponseMessage.self)
            hasReceivedHelloResponse = true
            isAwaitingManualApproval = false
            approvalWaitTask?.cancel()
            if response.accepted {
                hostDataPort = response.dataPort
                MirageLogger.client("Received hello response, dataPort: \(hostDataPort)")
            } else {
                MirageLogger.client("Connection rejected by host")
                connectionState = .error("Connection rejected")
            }
        } catch {
            MirageLogger.error(.client, "Failed to decode hello response: \(error)")
        }
    }

    func handleWindowList(_ message: ControlMessage) {
        do {
            let windowList = try message.decode(WindowListMessage.self)
            MirageLogger.client("Received window list with \(windowList.windows.count) windows")
            for window in windowList.windows {
                MirageLogger.client("  - \(window.application?.name ?? "Unknown"): \(window.title ?? "Untitled")")
            }
            hasReceivedWindowList = true
            availableWindows = windowList.windows
            delegate?.clientService(self, didUpdateWindowList: windowList.windows)
        } catch {
            MirageLogger.error(.client, "Failed to decode window list: \(error)")
        }
    }

    func handleWindowUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(WindowUpdateMessage.self) {
            for window in update.added where !availableWindows.contains(where: { $0.id == window.id }) {
                availableWindows.append(window)
            }
            for id in update.removed {
                availableWindows.removeAll { $0.id == id }
            }
            for window in update.updated {
                if let index = availableWindows.firstIndex(where: { $0.id == window.id }) { availableWindows[index] = window }
            }
        }
    }

    func handleStreamStarted(_ message: ControlMessage) {
        if let started = try? message.decode(StreamStartedMessage.self) {
            let streamID = started.streamID
            MirageLogger.client("Stream started: \(streamID) for window \(started.windowID)")

            refreshRateOverridesByStream[streamID] = getScreenMaxRefreshRate()

            let dimensionToken = started.dimensionToken

            Task { [weak self] in
                if let controller = self?.controllersByStream[streamID] {
                    let reassembler = await controller.getReassembler()
                    reassembler.reset()
                    if let token = dimensionToken { reassembler.updateExpectedDimensionToken(token) }
                }
            }

            if let minW = started.minWidth, let minH = started.minHeight {
                streamMinSizes[streamID] = (minWidth: minW, minHeight: minH)
                MirageLogger.client("Minimum window size: \(minW)x\(minH) pts")
                let minSize = CGSize(width: minW, height: minH)
                sessionStore.updateMinimumSize(for: streamID, minSize: minSize)
                onStreamMinimumSizeUpdate?(streamID, minSize)
            }

            let isAppCentricStream = streamStartedContinuation == nil
            streamStartedContinuation?.resume(returning: streamID)
            streamStartedContinuation = nil

            if !registeredStreamIDs.contains(streamID) {
                registeredStreamIDs.insert(streamID)
                Task {
                    do {
                        await self.setupControllerForStream(streamID)
                        self.addActiveStreamID(streamID)
                        if isAppCentricStream { MirageLogger.client("Controller set up for app-centric stream \(streamID)") }

                        if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                            let reassembler = await controller.getReassembler()
                            reassembler.updateExpectedDimensionToken(token)
                        }

                        if self.udpConnection == nil { try await self.startVideoConnection() }

                        try await self.sendStreamRegistration(streamID: streamID)
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                    }
                }
            }
        }
    }

    func handleStreamStopped(_ message: ControlMessage) {
        if let stopped = try? message.decode(StreamStoppedMessage.self) {
            let streamID = stopped.streamID
            activeStreams.removeAll { $0.id == streamID }
            MirageFrameCache.shared.clear(for: streamID)
            metricsStore.clear(streamID: streamID)
            cursorStore.clear(streamID: streamID)
            cursorPositionStore.clear(streamID: streamID)

            removeActiveStreamID(streamID)
            registeredStreamIDs.remove(streamID)
            clearStreamRefreshRateOverride(streamID: streamID)

            Task { [weak self] in
                guard let self else { return }
                if let controller = controllersByStream[streamID] {
                    await controller.stop()
                    controllersByStream.removeValue(forKey: streamID)
                }
                await updateReassemblerSnapshot()
            }
        }
    }

    func handleStreamMetricsUpdate(_ message: ControlMessage) {
        if let metrics = try? message.decode(StreamMetricsMessage.self) {
            metricsStore.updateHostMetrics(
                streamID: metrics.streamID,
                encodedFPS: metrics.encodedFPS,
                idleEncodedFPS: metrics.idleEncodedFPS,
                droppedFrames: metrics.droppedFrames,
                activeQuality: Double(metrics.activeQuality),
                targetFrameRate: metrics.targetFrameRate
            )

            if let requested = refreshRateOverridesByStream[metrics.streamID] {
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
                                try? await self?.sendStreamRefreshRateChange(
                                    streamID: metrics.streamID,
                                    maxRefreshRate: requested,
                                    forceDisplayRefresh: true
                                )
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
    }

    func handleErrorMessage(_ message: ControlMessage) {
        if let error = try? message.decode(ErrorMessage.self) { delegate?.clientService(self, didEncounterError: MirageError.protocolError(error.message)) }
    }

    func handleDisconnectMessage(_ message: ControlMessage) async {
        if let disconnect = try? message.decode(DisconnectMessage.self) {
            await handleDisconnect(
                reason: disconnect.reason.rawValue,
                state: .disconnected,
                notifyDelegate: true
            )
        }
    }

    func handleCursorUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(CursorUpdateMessage.self) {
            MirageLogger.client("Cursor update received: \(update.cursorType) (visible: \(update.isVisible))")
            let didChange = cursorStore.updateCursor(
                streamID: update.streamID,
                cursorType: update.cursorType,
                isVisible: update.isVisible
            )
            if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
            onCursorUpdate?(update.streamID, update.cursorType, update.isVisible)
        }
    }

    func handleCursorPositionUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(CursorPositionUpdateMessage.self) {
            let position = CGPoint(x: CGFloat(update.normalizedX), y: CGFloat(update.normalizedY))
            let didChange = cursorPositionStore.updatePosition(
                streamID: update.streamID,
                position: position,
                isVisible: update.isVisible
            )
            if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
        }
    }

    func handleContentBoundsUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(ContentBoundsUpdateMessage.self) {
            MirageLogger.client("Content bounds update for stream \(update.streamID): \(update.bounds)")
            onContentBoundsUpdate?(update.streamID, update.bounds)
            delegate?.clientService(self, didReceiveContentBoundsUpdate: update.bounds, forStream: update.streamID)
        }
    }

    func handleSessionStateUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(SessionStateUpdateMessage.self)
            MirageLogger.client("Host session state: \(update.state), requires username: \(update.requiresUsername)")
            hostSessionState = update.state
            currentSessionToken = update.sessionToken
            delegate?.clientService(
                self,
                hostSessionStateChanged: update.state,
                requiresUsername: update.requiresUsername
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode session state update: \(error)")
        }
    }

    func handleUnlockResponse(_ message: ControlMessage) {
        do {
            let response = try message.decode(UnlockResponseMessage.self)
            MirageLogger.client("Unlock response: success=\(response.success)")
            if response.success {
                hostSessionState = response.newState
                if let token = response.newSessionToken { currentSessionToken = token }
            }
            delegate?.clientService(
                self,
                unlockDidComplete: response.success,
                error: response.error?.message,
                canRetry: response.canRetry,
                retriesRemaining: response.retriesRemaining,
                retryAfterSeconds: response.retryAfterSeconds
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode unlock response: \(error)")
        }
    }

    func handleLoginDisplayReady(_ message: ControlMessage) {
        do {
            let ready = try message.decode(LoginDisplayReadyMessage.self)
            MirageLogger.client("Login display ready: stream=\(ready.streamID), \(ready.width)x\(ready.height)")
            let streamID = StreamID(ready.streamID)
            loginDisplayStreamID = streamID
            loginDisplayResolution = CGSize(width: ready.width, height: ready.height)
            sessionStore.startLoginDisplay(
                streamID: streamID,
                resolution: CGSize(width: ready.width, height: ready.height)
            )

            let dimensionToken = ready.dimensionToken

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
                        if self.udpConnection == nil { try await self.startVideoConnection() }
                        try await self.sendStreamRegistration(streamID: streamID)
                        MirageLogger.client("Registered for login display video stream \(streamID)")
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection for login display: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                    }
                }
            }

            delegate?.clientService(
                self,
                loginDisplayDidStart: StreamID(ready.streamID),
                resolution: CGSize(width: ready.width, height: ready.height),
                sessionState: ready.sessionState,
                requiresUsername: ready.requiresUsername
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode login display ready: \(error)")
        }
    }

    func handleLoginDisplayStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(LoginDisplayStoppedMessage.self)
            let streamID = StreamID(stopped.streamID)
            let borrowedDesktopStream = desktopStreamID != nil && streamID == desktopStreamID
            MirageLogger.client("Login display stopped: stream=\(streamID)")
            loginDisplayStreamID = nil
            loginDisplayResolution = nil
            sessionStore.stopLoginDisplay()
            if borrowedDesktopStream {
                MirageLogger
                    .client("Login display stop shares the active desktop stream; desktop stream state remains active")
            } else {
                metricsStore.clear(streamID: streamID)
                cursorStore.clear(streamID: streamID)

                removeActiveStreamID(streamID)
                registeredStreamIDs.remove(streamID)

                Task {
                    if let controller = self.controllersByStream[streamID] {
                        await controller.stop()
                        self.controllersByStream.removeValue(forKey: streamID)
                    }
                    await self.updateReassemblerSnapshot()
                }
            }

            delegate?.clientService(self, loginDisplayDidStop: streamID, newState: stopped.newState)
        } catch {
            MirageLogger.error(.client, "Failed to decode login display stopped: \(error)")
        }
    }
}
