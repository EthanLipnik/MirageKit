//
//  StreamContext+Streaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//
//  Shared streaming pipeline setup used by all capture modes.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Shared Pipeline Setup

enum StreamCaptureEngineSetupError: Error, LocalizedError {
    case encoderUnavailable
    case streamStoppedDuringSetup

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable:
            "Encoder became unavailable during capture-engine setup"
        case .streamStoppedDuringSetup:
            "Stream stopped during capture-engine setup"
        }
    }
}

extension StreamContext {
    /// Configures the packet sender for encoded frame output with per-fragment transport metadata.
    func setupPacketSender(
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
        onSendError: (@Sendable (Error) -> Void)? = nil
    ) async {
        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            sendPacketWithMetadata: sendPacketWithMetadata,
            queuedUnreliableDiagnosticsProvider: mediaSendDiagnosticsProvider,
            onSendError: onSendError,
            duplicatesParameterSetPackets: mediaPathProfile.usesAwdlRadioPolicy,
            onDependencyFrameDropped: { [weak self] streamID, frameNumber, reason in
                Task(priority: .userInitiated) {
                    await self?.handlePacketSenderDependencyFrameDrop(
                        streamID: streamID,
                        frameNumber: frameNumber,
                        reason: reason
                    )
                }
            },
            onFrameTransportCompleted: { [weak self] completion in
                Task(priority: .userInitiated) {
                    await self?.handleFrameTransportCompleted(completion)
                }
            }
        )
        packetSender = sender
        await sender.start()
        realtimeSenderPacingBitrateBps = encoderConfig.bitrate
        await sender.setTargetBitrateBps(encoderConfig.bitrate)
    }

    /// Creates the video encoder, session, and runs preheat with fallback.
    func createAndPreheatEncoder(
        streamKind: VideoEncoder.StreamKind,
        width: Int,
        height: Int
    ) async throws {
        let encoder = VideoEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            streamKind: streamKind,
            mediaPathProfile: mediaPathProfile,
            inFlightLimit: maxInFlightFrames,
            maximizePowerEfficiencyEnabled: encoderLowPowerEnabled
        )
        self.encoder = encoder
        try await encoder.createSession(width: width, height: height)

        let preheatOK = try await encoder.preheatWithFallback()
        if !preheatOK {
            MirageLogger.error(.stream, "Encoder preheat failed on all pixel formats and spec tiers; streaming may not work")
        }
        activePixelFormat = await encoder.activePixelFormat
        shouldEncodeFrames = false
        startupFrameCachingEnabled = true
        cachedStartupFrame = nil
        MirageLogger.stream("Waiting for datagram registration before encoding")
    }

    /// Starts the encoder with a shared encoding callback. The callback handles frame
    /// numbering, FEC, fragmentation, and packet enqueue — identical across all capture modes.
    ///
    /// - Parameters:
    ///   - pinnedContentRect: If non-nil, all frames use this content rect. Otherwise `currentContentRect` is used.
    ///   - logPrefix: Label prefix for packet sender logging (e.g., "Frame", "Desktop frame", "VD Frame").
    func startEncoderWithSharedCallback(
        pinnedContentRect: CGRect?,
        logPrefix: String
    ) async {
        let currentStreamID = streamID
        guard packetSender != nil, let encoder else {
            MirageLogger.stream("startEncoderWithSharedCallback skipped — stream \(currentStreamID) already stopped")
            return
        }
        let callbackSequencer = StreamEncodingCallbackSequencer()
        let baseFrameFlagsSnapshot = baseFrameFlags

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime, finishFrame in
                Task(priority: .userInitiated) {
                    guard let self else {
                        finishFrame()
                        return
                    }
                    await self.handleEncodedFrameForStreaming(
                        encodedData: encodedData,
                        isKeyframe: isKeyframe,
                        presentationTime: presentationTime,
                        pinnedContentRect: pinnedContentRect,
                        logPrefix: logPrefix,
                        callbackSequencer: callbackSequencer,
                        baseFrameFlagsSnapshot: baseFrameFlagsSnapshot
                    )
                    finishFrame()
                }
            }, onFrameComplete: { [weak self] in
                Task(priority: .userInitiated) { await self?.finishEncoding() }
            }
        )
    }

    private func handleEncodedFrameForStreaming(
        encodedData: Data,
        isKeyframe: Bool,
        presentationTime: CMTime,
        pinnedContentRect: CGRect?,
        logPrefix: String,
        callbackSequencer: StreamEncodingCallbackSequencer,
        baseFrameFlagsSnapshot: FrameFlags
    ) async {
        guard let packetSender else { return }
        guard shouldEncodeFrames else {
            MirageLogger.stream(
                "Dropping encoded frame after client background pause stream=\(streamID) keyframe=\(isKeyframe)"
            )
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if !isKeyframe, suppressEncodedNonKeyframesUntilKeyframe || frameChainSuppressesPFrames {
            return
        }

        let frameByteCount = encodedData.count
        let requestedFECBlockSize = resolvedFECBlockSize(
            isKeyframe: isKeyframe,
            frameByteCount: frameByteCount,
            now: now
        )
        let fecBlockSize = requestedFECBlockSize
        let projectedPlan = Self.projectedFragmentPlan(
            frameByteCount: frameByteCount,
            maxPayloadSize: maxPayloadSize,
            fecBlockSize: fecBlockSize
        )
        let admissionDecision = await evaluateEncodedFrameBudget(
            byteCount: frameByteCount,
            wireBytes: projectedPlan.wireBytes,
            packetCount: projectedPlan.packetCount,
            isKeyframe: isKeyframe,
            encodedAt: now
        )

        switch admissionDecision.admission {
        case .send,
             .sendWithQualityDrop:
            break
        case .dropPFrameStartChainRepair:
            await handleDroppedPFrameForTransportBudget(
                byteCount: frameByteCount,
                wireBytes: projectedPlan.wireBytes,
                packetCount: projectedPlan.packetCount,
                evaluation: admissionDecision,
                encodedAt: now
            )
            return
        }

        let reservation = callbackSequencer.reserve(
            frameByteCount: frameByteCount,
            maxPayloadSize: maxPayloadSize,
            fecBlockSize: fecBlockSize
        )

        if isKeyframe {
            MirageLogger.stream(
                "Keyframe encoded: size=\(encodedData.count), frame=\(reservation.frameNumber), stream=\(streamID)"
            )
        } else {
            if admissionDecision.admission == .sendWithQualityDrop {
                logAdaptivePFrameAdmissionIfNeeded(
                    frameNumber: reservation.frameNumber,
                    byteCount: frameByteCount,
                    wireBytes: projectedPlan.wireBytes,
                    packetCount: projectedPlan.packetCount,
                    evaluation: admissionDecision,
                    action: "send-quality-drop",
                    now: now
                )
            }
            MirageFrameIntegrityDiagnostics.shared.recordPFrame(
                source: .encodedPFrame,
                streamID: streamID,
                frameNumber: reservation.frameNumber,
                frameBytes: encodedData
            )
        }
        let contentRect = pinnedContentRect ?? currentContentRect
        let pacingOverride = Self.mediaPacingOverride(
            isKeyframe: isKeyframe,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            targetBitrateBps: currentTargetBitrateBps,
            maxPayloadSize: maxPayloadSize,
            awdlDecision: latestAwdlMediaDecisionSnapshot
        )

        let flags = baseFrameFlagsSnapshot.union(dynamicFrameFlags)
        let dimToken = dimensionToken
        let currentEpoch = epoch

        let generation = packetSender.currentGeneration
        if isKeyframe {
            let queuedBytes = packetSender.queuedByteCount
            logDependencyRecoveryKeyframeIfNeeded(
                frameNumber: reservation.frameNumber,
                queuedBytes: queuedBytes
            )
            markKeyframeInFlight(frameNumber: reservation.frameNumber)
            markKeyframeSent()
        }
        let workItem = StreamPacketSender.WorkItem(
            encodedData: encodedData,
            frameByteCount: frameByteCount,
            isKeyframe: isKeyframe,
            presentationTime: presentationTime,
            contentRect: contentRect,
            streamID: streamID,
            frameNumber: reservation.frameNumber,
            sequenceNumberStart: reservation.sequenceNumberStart,
            additionalFlags: flags,
            dimensionToken: dimToken,
            epoch: currentEpoch,
            fecBlockSize: fecBlockSize,
            wireBytes: reservation.wireBytes,
            logPrefix: logPrefix,
            generation: generation,
            encodedAt: now,
            sendDeadline: admissionDecision.sendDeadline,
            hardSendDeadline: awdlHardSendDeadline(
                sendDeadline: admissionDecision.sendDeadline,
                isKeyframe: isKeyframe,
                packetCount: projectedPlan.packetCount
            ),
            targetFrameRate: currentFrameRate,
            pacingOverride: pacingOverride,
            usesAwdlRealtimeQueuePolicy: mediaPathProfile.usesAwdlRadioPolicy
        )
        packetSender.enqueue(workItem)
    }

    private func awdlHardSendDeadline(
        sendDeadline: CFAbsoluteTime,
        isKeyframe: Bool,
        packetCount: Int
    ) -> CFAbsoluteTime? {
        guard mediaPathProfile.usesAwdlRadioPolicy,
              sendDeadline.isFinite else {
            return nil
        }
        let playoutDelayMs = min(
            MirageAwdlMediaController.maximumPlayoutDelayMs,
            max(
                MirageAwdlMediaController.minimumPlayoutDelayMs,
                receiverPlayoutDelayTargetMs ??
                    latestAwdlMediaDecisionSnapshot?.playoutDelayMs ??
                    MirageAwdlMediaController.basePlayoutDelayMs
            )
        )
        let frameInterval = 1.0 / Double(max(1, currentFrameRate))
        if isKeyframe {
            let packetPressureMs = min(80.0, Double(max(0, packetCount)) * 0.03)
            let recoveryWindowMs = min(200.0, max(120.0, playoutDelayMs + 40.0 + packetPressureMs))
            return sendDeadline + recoveryWindowMs / 1_000.0
        }
        let allowanceSeconds = max(frameInterval * 2.0, max(50.0, playoutDelayMs) / 1_000.0)
        return sendDeadline + allowanceSeconds
    }

    private static func projectedFragmentPlan(
        frameByteCount: Int,
        maxPayloadSize: Int,
        fecBlockSize: Int
    ) -> (wireBytes: Int, packetCount: Int) {
        let payloadSize = max(1, maxPayloadSize)
        let dataFragments = frameByteCount > 0
            ? (frameByteCount + payloadSize - 1) / payloadSize
            : 0
        let parityFragments = fecBlockSize > 1
            ? (dataFragments + fecBlockSize - 1) / fecBlockSize
            : 0
        return (
            wireBytes: frameByteCount + parityFragments * payloadSize,
            packetCount: dataFragments + parityFragments
        )
    }

    /// Creates and starts the capture engine with admission dropping.
    func setupAndStartCaptureEngine(
        usesDisplayRefreshCadence: Bool
    ) async throws -> WindowCaptureEngine {
        guard let encoder else {
            throw StreamCaptureEngineSetupError.encoderUnavailable
        }

        let resolvedPixelFormat = await encoder.activePixelFormat
        guard isRunning, self.encoder != nil else {
            throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
        }
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let engine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
        captureEngine = engine
        if let captureStallStageHandler {
            guard isRunning, self.encoder != nil else {
                captureEngine = nil
                throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
            }
            await engine.setCaptureStallStageHandler(captureStallStageHandler)
        }
        let frameInboxSnapshot = frameInbox
        guard isRunning, self.encoder != nil else {
            captureEngine = nil
            throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
        }
        let latencyMode = latencyMode
        let hostBufferingPolicy = hostBufferingPolicy
        await engine.setAdmissionDropper { [weak self] in
            let snapshot = frameInboxSnapshot.pendingSnapshot
            let backpressure = self?.backpressureActiveSnapshot ?? false
            let encoderLag = HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: self?.encoderAverageEncodeMsSnapshot ?? 0,
                inFlightCount: self?.encoderInFlightCountSnapshot ?? 0,
                frameRate: self?.currentFrameRate ?? 60
            )
            let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                pendingFrameCount: snapshot.pending,
                frameCapacity: snapshot.capacity,
                backpressureActive: backpressure,
                encoderLag: encoderLag
            )
            guard shouldDrop else { return false }
            if frameInboxSnapshot.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }
        return engine
    }

    func waitForDisplayStartupReadiness(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> DisplayCaptureStartupReadiness {
        guard captureMode == .display, let captureEngine else { return .noScreenSamples }
        return await captureEngine.waitForDisplayStartupReadiness(
            timeout: timeout,
            pollInterval: pollInterval
        )
    }

    func restartDisplayCaptureForStartupRecovery(reason: String) async {
        guard captureMode == .display else { return }
        await captureEngine?.restartCapture(reason: reason)
    }

    func hasObservedDisplayStartupSample() async -> Bool {
        guard captureMode == .display, let captureEngine else { return false }
        return await captureEngine.hasObservedDisplayStartupSample
    }

    var hasCachedStartupFrame: Bool {
        cachedStartupFrame != nil
    }

    func seedDisplayStartupFrameIfNeeded() async -> Bool {
        guard captureMode == .display,
              startupFrameCachingEnabled,
              cachedStartupFrame == nil,
              let captureEngine else {
            return cachedStartupFrame != nil
        }

        guard let seededFrame = await captureEngine.captureDisplayStartupSeedFrame() else {
            return false
        }

        cachedStartupFrame = seededFrame
        MirageLogger.stream(
            "Cached screenshot startup frame for stream \(streamID) pending first live display sample"
        )
        return true
    }

}
#endif
