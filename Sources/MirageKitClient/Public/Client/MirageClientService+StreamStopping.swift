//
//  MirageClientService+StreamStopping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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
import Foundation

@MainActor
public extension MirageClientService {
    /// Stop viewing a stream.
    /// - Parameters:
    ///   - session: The stream session to stop.
    ///   - minimizeWindow: Whether to minimize the source window on the host.
    ///   - origin: Optional stop-request origin metadata.
    func stopViewing(
        _ session: ClientStreamSession,
        minimizeWindow: Bool = false,
        origin: MirageClientService.StreamStopOrigin? = nil
    )
    async {
        let streamID = session.id

        let request = MirageWire.StopStreamMessage(
            streamID: streamID,
            minimizeWindow: minimizeWindow,
            origin: origin?.controlMessageOrigin
        )
        queueControlMessageBestEffort(.stopStream, content: request)

        await forceStopWindowStreamLocally(streamID: streamID)
    }
}

extension MirageClientService {
    /// Handles unrecoverable startup failure by stopping the affected stream and notifying the delegate.
    func handleTerminalStartupFailure(
        _ failure: StreamController.TerminalStartupFailure,
        for streamID: StreamID
    ) async {
        let waitReason = failure.waitReason ?? "unknown"
        MirageLogger.error(
            .client,
            "Terminal startup failure for stream \(streamID): hardRecoveries=\(failure.hardRecoveryAttempts), " +
                "reason=\(failure.reason.logLabel), waitReason=\(waitReason)"
        )

        let error = MirageCore.MirageError.protocolError(StreamController.TerminalStartupFailure.errorMessage)

        if desktopStreamID == streamID {
            if pendingLocalDesktopStopStreamID == streamID,
               pendingLocalDesktopStopSessionID == desktopSessionID {
                MirageLogger.client(
                    "Suppressing terminal startup failure for stream \(streamID) while a local desktop stop is pending"
                )
                await forceStopDesktopStreamLocally(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID,
                    notifyStopReason: .clientRequested
                )
                return
            }

            if await restartDesktopStreamAfterTerminalStartupFailure(failure, failedStreamID: streamID) {
                return
            }

            if let desktopSessionID {
                let request = MirageWire.StopDesktopStreamMessage(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID
                )
                queueControlMessageBestEffort(.stopDesktopStream, content: request)
            }
            await forceStopDesktopStreamLocally(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                notifyStopReason: .error
            )
            delegate?.didEncounterError(error)
            return
        }

        let appStartupFailure = appAtlasStartupFailure(for: streamID, message: error.localizedDescription)
        let hasOtherInteractiveStream = hasOtherInteractiveStream(afterStopping: streamID)

        if activeStreams.contains(where: { $0.id == streamID }) ||
            sessionStore.sessionByMediaStreamID(streamID) != nil ||
            controllersByStream[streamID] != nil {
            let request = MirageWire.StopStreamMessage(
                streamID: streamID,
                minimizeWindow: false,
                origin: nil
            )
            queueControlMessageBestEffort(.stopStream, content: request)
            await forceStopWindowStreamLocally(streamID: streamID)
        }

        if let appStartupFailure {
            onAppStreamStartupFailed?(appStartupFailure)
            return
        }

        if hasOtherInteractiveStream {
            MirageLogger.client(
                "Suppressing session-level terminal startup failure for stopped non-desktop stream \(streamID); another stream remains active or starting"
            )
            return
        }

        delegate?.didEncounterError(error)
    }
}

extension MirageClientService {
    func appAtlasStartupFailure(
        for streamID: StreamID,
        message: String
    ) -> AppStreamStartupFailure? {
        let sessions = sessionStore.activeSessions.filter { $0.mediaStreamID == streamID }
        guard !sessions.isEmpty else { return nil }
        let bundleIdentifier = sessions.compactMap { $0.window.application?.bundleIdentifier }.first
        return AppStreamStartupFailure(
            bundleIdentifier: bundleIdentifier,
            message: message
        )
    }

    func hasOtherInteractiveStream(afterStopping streamID: StreamID) -> Bool {
        if let desktopStreamID, desktopStreamID != streamID {
            return true
        }
        if desktopStreamMode != nil, desktopStreamID != streamID {
            return true
        }
        if activeStreams.contains(where: { $0.id != streamID && $0.mediaStreamID != streamID }) {
            return true
        }
        if sessionStore.activeSessions.contains(where: { $0.streamID != streamID && $0.mediaStreamID != streamID }) {
            return true
        }
        return controllersByStream.keys.contains { $0 != streamID }
    }
}

public extension MirageClientService {
    /// Cancels the pending local desktop-stop fallback timer.
    func cancelDesktopStreamStopTimeout() {
        desktopStreamStopTimeoutTask?.cancel()
        desktopStreamStopTimeoutTask = nil
        pendingLocalDesktopStopStreamID = nil
        pendingLocalDesktopStopSessionID = nil
    }

    private nonisolated static func shouldForceLocalDesktopStopAfterTimeout(
        requestedStreamID: StreamID,
        requestedDesktopSessionID: UUID,
        activeDesktopStreamID: StreamID?,
        activeDesktopSessionID: UUID?,
        hasController: Bool,
        isRegistered: Bool
    ) -> Bool {
        if let activeDesktopSessionID,
           activeDesktopSessionID != requestedDesktopSessionID {
            return false
        }
        return activeDesktopStreamID == requestedStreamID || hasController || isRegistered
    }

    /// Schedules a local desktop-stop fallback when host acknowledgement is delayed.
    func scheduleDesktopStreamStopTimeout(for streamID: StreamID, desktopSessionID: UUID) {
        desktopStreamStopTimeoutTask?.cancel()
        desktopStreamStopTimeoutTask = nil
        pendingLocalDesktopStopStreamID = streamID
        pendingLocalDesktopStopSessionID = desktopSessionID
        desktopStreamStopTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: desktopStreamStopTimeout)
            } catch {
                return
            }

            guard Self.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: streamID,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: desktopStreamID,
                activeDesktopSessionID: self.desktopSessionID,
                hasController: controllersByStream[streamID] != nil,
                isRegistered: registeredStreamIDs.contains(streamID)
            ) else {
                desktopStreamStopTimeoutTask = nil
                if pendingLocalDesktopStopStreamID == streamID,
                   pendingLocalDesktopStopSessionID == desktopSessionID {
                    pendingLocalDesktopStopStreamID = nil
                    pendingLocalDesktopStopSessionID = nil
                }
                return
            }

            MirageLogger.client(
                "Desktop stop acknowledgement timed out for stream \(streamID), session=\(desktopSessionID.uuidString); forcing local teardown"
            )
            await forceStopDesktopStreamLocally(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                notifyStopReason: .clientRequested
            )
            desktopStreamStopTimeoutTask = nil
        }
    }

    func forceStopWindowStreamLocally(streamID: StreamID) async {
        MirageRenderStreamStore.shared.clear(for: streamID)
        activeStreams.removeAll { $0.id == streamID }
        sessionStore.removeSessions(renderingMediaStreamID: streamID)
        pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
        renderLatencyModeByStream.removeValue(forKey: streamID)

        metricsStore.clear(streamID: streamID)
        cursorStore.clear(streamID: streamID)
        cursorPositionStore.clear(streamID: streamID)

        fastPathState.removeActiveStreamID(streamID)
        stopVideoStreamReceive(for: streamID)
        registeredStreamIDs.remove(streamID)
        clearStreamRefreshRateOverride(streamID: streamID)
        clearDecoderColorDepthState(for: streamID)
        mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
        clearStartupAttempt(for: streamID)
        appDimensionTokenByStream.removeValue(forKey: streamID)
        appStreamStartAcknowledgementByStreamID.removeValue(forKey: streamID)
        appWindowResizeResultByStreamID.removeValue(forKey: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupFirstRegistrationSent.remove(streamID)
        streamStartupFirstPacketReceived.remove(streamID)
        fastPathState.clearStartupPacketPending(streamID)
        cancelStartupRegistrationRetry(streamID: streamID)
        cancelForegroundRecoveryMonitor(for: streamID)
        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.stop()
        }

        await updateReassemblerSnapshot()
        await refreshSharedClipboardBridgeState()
    }

    /// Clears local desktop stream state without waiting for another host message.
    func forceStopDesktopStreamLocally(
        streamID: StreamID,
        desktopSessionID expectedDesktopSessionID: UUID? = nil,
        notifyStopReason: MirageWire.DesktopStreamStopReason? = nil
    ) async {
        if let expectedDesktopSessionID,
           let activeDesktopSessionID = desktopSessionID,
           activeDesktopSessionID != expectedDesktopSessionID {
            MirageLogger.client(
                "Skipping local desktop teardown for superseded session \(expectedDesktopSessionID.uuidString); activeSession=\(activeDesktopSessionID.uuidString)"
            )
            return
        }
        if let sessionID = expectedDesktopSessionID ?? desktopSessionID {
            retiredDesktopSessionIDs.insert(sessionID)
        }
        cancelDesktopStreamStopTimeout()
        let hadLocalState = desktopStreamID == streamID ||
            controllersByStream[streamID] != nil ||
            registeredStreamIDs.contains(streamID)

        MirageRenderStreamStore.shared.clear(for: streamID)
        pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
        renderLatencyModeByStream.removeValue(forKey: streamID)
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = nil
        desktopStreamRequestStartTime = 0
        if desktopStreamID == streamID {
            desktopStreamID = nil
            desktopSessionID = nil
            desktopStreamResolution = nil
            desktopStreamPresentationResolution = nil
            desktopStreamDisplayScaleFactor = nil
            desktopCaptureSource = .virtualDisplay
            desktopStreamAllowsClientResize = true
            desktopStreamMode = nil
            desktopCursorPresentation = nil
        }
        desktopDimensionTokenByStream.removeValue(forKey: streamID)
        clearStartupAttempt(for: streamID)
        sessionStore.clearPostResizeTransition(for: streamID)
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
        cancelForegroundRecoveryMonitor(for: streamID)
        clearDecoderColorDepthState(for: streamID)
        pendingDesktopRequestedColorDepth = nil
        pendingDesktopRequestedLatencyMode = nil
        mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
        activeStreamCodecs.removeValue(forKey: streamID)

        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.stop()
        }

        await updateReassemblerSnapshot()
        await refreshSharedClipboardBridgeState()

        if let notifyStopReason, hadLocalState {
            onDesktopStreamStopped?(streamID, notifyStopReason)
        }
    }
}

private extension MirageClientService.StreamStopOrigin {
    var controlMessageOrigin: MirageWire.StopStreamMessage.Origin {
        switch self {
        case .clientWindowClosed:
            .clientWindowClosed
        case .remoteCommand:
            .remoteCommand
        }
    }
}
