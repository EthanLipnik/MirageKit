//
//  MirageClientService+CustomStreaming.swift
//  MirageKit
//
//  Created by Codex on 4/30/26.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Requests a generic app-defined stream from the connected host.
    @discardableResult
    func startCustomStream(
        kind: String,
        metadata: [String: String] = [:],
        displayResolution: CGSize? = nil,
        scaleFactor: CGFloat? = nil,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
    ) async throws -> ClientStreamSession {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        await cancelActiveQualityTest(reason: "custom stream startup", notifyHost: true)

        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty else {
            throw MirageError.protocolError("Custom stream kind is required")
        }

        let baseResolution = displayResolution ?? getMainDisplayResolution()
        let effectiveDisplayResolution = scaledDisplayResolution(baseResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for custom streaming")
        }

        let startupRequestID = UUID()
        pendingStreamSetupRequestID = startupRequestID
        pendingStreamSetupKind = .custom
        pendingStreamSetupAppSessionID = nil

        var request = StartCustomStreamMessage(
            startupRequestID: startupRequestID,
            kind: trimmedKind,
            metadata: metadata,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            targetFrameRate: getScreenMaxRefreshRate(),
            scaleFactor: nil,
            streamScale: nil,
            mediaMaxPacketSize: resolvedRequestedMediaMaxPacketSize()
        )

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &request)

        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor,
            requestedStreamScale: clampedStreamScale(),
            encoderMaxWidth: request.encoderMaxWidth,
            encoderMaxHeight: request.encoderMaxHeight,
            disableResolutionCap: request.disableResolutionCap == true
        )
        resolutionScale = geometry.resolvedStreamScale
        request.streamScale = geometry.resolvedStreamScale

        return try await withCheckedThrowingContinuation { continuation in
            customStreamStartedContinuations[startupRequestID] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendControlMessage(.startCustomStream, content: request)
                    self.heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
                    MirageLogger.client("Requested custom stream kind=\(trimmedKind)")
                } catch {
                    self.customStreamStartedContinuations.removeValue(forKey: startupRequestID)
                    self.clearPendingStreamSetup(kind: .custom)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopCustomStream(_ session: ClientStreamSession) async {
        let streamID = session.id
        let request = StopCustomStreamMessage(streamID: streamID)
        if let message = try? ControlMessage(type: .stopCustomStream, content: request) {
            sendControlMessageBestEffort(message)
        }
        await forceStopCustomStreamLocally(
            streamID: streamID,
            notifyStopReason: .clientRequested
        )
    }
}

@MainActor
extension MirageClientService {
    func handleCustomStreamStarted(_ message: ControlMessage) async {
        do {
            let started = try message.decode(MirageCustomStreamStartedMessage.self)
            let streamID = started.streamID
            let startupAttemptID = started.startupAttemptID
            guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
                MirageLogger.client(
                    "Ignoring stale customStreamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
                )
                return
            }

            let window = syntheticCustomStreamWindow(for: started)
            let clientSession = ClientStreamSession(id: streamID, window: window, kind: .custom)
            customStreamDescriptorsByStreamID[streamID] = started.descriptor
            upsertActiveStreamSession(streamID: streamID, window: window, kind: .custom)
            activeStreamCodecs[streamID] = started.codec

            if let dimensionToken = started.dimensionToken {
                appDimensionTokenByStream[streamID] = dimensionToken
            }

            streamStartupBaseTimes[streamID] = CFAbsoluteTimeGetCurrent()
            streamStartupFirstRegistrationSent.remove(streamID)
            streamStartupFirstPacketReceived.remove(streamID)
            markStartupPacketPending(streamID)
            registerStartupAttempt(startupAttemptID, for: streamID)

            await setupControllerForStream(
                streamID,
                codec: started.codec,
                streamDimensions: (width: started.width, height: started.height),
                mediaMaxPacketSize: started.acceptedMediaMaxPacketSize,
                dimensionToken: started.dimensionToken
            )
            addActiveStreamID(streamID)

            if let startupAttemptID {
                await sendStreamReadyAck(
                    streamID: streamID,
                    startupAttemptID: startupAttemptID,
                    kind: .custom
                )
            }

            if !registeredStreamIDs.contains(streamID) {
                registeredStreamIDs.insert(streamID)
                let refreshRate = refreshRateOverridesByStream[streamID] ?? getScreenMaxRefreshRate()
                try? await sendStreamRefreshRateChange(
                    streamID: streamID,
                    maxRefreshRate: refreshRate
                )
                startStartupRegistrationRetry(streamID: streamID)
            }

            if let continuation = customStreamStartedContinuations.removeValue(forKey: started.startupRequestID) {
                continuation.resume(returning: clientSession)
            }
            clearPendingStreamSetup(kind: .custom)
            onCustomStreamStarted?(started)
            await refreshSharedClipboardBridgeState()
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode custom stream started: ")
        }
    }

    func handleCustomStreamStopped(_ message: ControlMessage) async {
        do {
            let stopped = try message.decode(MirageCustomStreamStoppedMessage.self)
            await forceStopCustomStreamLocally(
                streamID: stopped.streamID,
                notifyStopReason: stopped.reason
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode custom stream stopped: ")
        }
    }

    func handleCustomStreamFailed(_ message: ControlMessage) {
        do {
            let failed = try message.decode(CustomStreamFailedMessage.self)
            if let continuation = customStreamStartedContinuations.removeValue(forKey: failed.startupRequestID) {
                continuation.resume(throwing: MirageError.protocolError(failed.reason))
            }
            clearPendingStreamSetup(kind: .custom)
            delegate?.clientService(self, didEncounterError: MirageError.protocolError(failed.reason))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode custom stream failed: ")
        }
    }

    private func syntheticCustomStreamWindow(
        for started: MirageCustomStreamStartedMessage
    ) -> MirageWindow {
        let app = MirageApplication(
            id: 0,
            bundleIdentifier: started.descriptor.kind,
            name: started.descriptor.displayName
        )
        return MirageWindow(
            id: 0,
            title: started.descriptor.displayName,
            application: app,
            frame: CGRect(x: 0, y: 0, width: started.width, height: started.height),
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private func forceStopCustomStreamLocally(
        streamID: StreamID,
        notifyStopReason: MirageCustomStreamStoppedMessage.Reason?
    ) async {
        MirageRenderStreamStore.shared.clear(for: streamID)
        activeStreams.removeAll { $0.id == streamID }
        customStreamDescriptorsByStreamID.removeValue(forKey: streamID)
        pendingApplicationActivationRecoveryStreamIDs.remove(streamID)

        metricsStore.clear(streamID: streamID)
        cursorStore.clear(streamID: streamID)
        cursorPositionStore.clear(streamID: streamID)
        sessionStore.clearPostResizeTransition(for: streamID)

        removeActiveStreamID(streamID)
        stopVideoStreamReceive(for: streamID)
        registeredStreamIDs.remove(streamID)
        clearStreamRefreshRateOverride(streamID: streamID)
        inputEventSender.clearTemporaryPointerCoalescing(for: streamID)
        clearDecoderColorDepthState(for: streamID)
        mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
        clearStartupAttempt(for: streamID)
        appDimensionTokenByStream.removeValue(forKey: streamID)
        appStreamStartAcknowledgementByStreamID.removeValue(forKey: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupFirstRegistrationSent.remove(streamID)
        streamStartupFirstPacketReceived.remove(streamID)
        clearStartupPacketPending(streamID)
        cancelStartupRegistrationRetry(streamID: streamID)
        cancelRecoveryKeyframeRetry(for: streamID)
        activeJitterHoldMs = 0

        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.stop()
        }

        await updateReassemblerSnapshot()
        await refreshSharedClipboardBridgeState()

        if let notifyStopReason {
            onCustomStreamStopped?(
                MirageCustomStreamStoppedMessage(streamID: streamID, reason: notifyStopReason)
            )
        }
    }
}
