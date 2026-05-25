//
//  StreamContext+Streaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//
//  Shared streaming pipeline setup used by all capture modes.
//

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
    /// Configures the packet sender for encoded frame output.
    func setupPacketSender(
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil
    ) async {
        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            sendPacket: sendPacket,
            onSendError: onSendError,
            onDependencyFrameDropped: { [weak self] streamID, frameNumber, reason in
                Task(priority: .userInitiated) {
                    await self?.handlePacketSenderDependencyFrameDrop(
                        streamID: streamID,
                        frameNumber: frameNumber,
                        reason: reason
                    )
                }
            }
        )
        packetSender = sender
        await sender.start()
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
        guard let packetSender, let encoder else {
            MirageLogger.stream("startEncoderWithSharedCallback skipped — stream \(currentStreamID) already stopped")
            return
        }
        let callbackSequencer = StreamEncodingCallbackSequencer()
        let baseFrameFlagsSnapshot = baseFrameFlags

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
                guard let self else { return }

                let now = CFAbsoluteTimeGetCurrent()
                if !isKeyframe, suppressEncodedNonKeyframesUntilKeyframe {
                    return
                }
                if isKeyframe {
                    suppressEncodedNonKeyframesUntilKeyframe = false
                }

                let fecBlockSize = resolvedFECBlockSize(
                    isKeyframe: isKeyframe,
                    frameByteCount: encodedData.count,
                    now: now
                )
                let reservation = callbackSequencer.reserve(
                    frameByteCount: encodedData.count,
                    maxPayloadSize: maxPayloadSize,
                    fecBlockSize: fecBlockSize
                )

                if isKeyframe {
                    MirageLogger.stream(
                        "Keyframe encoded: size=\(encodedData.count), frame=\(reservation.frameNumber), stream=\(streamID)"
                    )
                } else {
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
                    targetBitrateBps: currentTargetBitrateBps,
                    maxPayloadSize: maxPayloadSize
                )
                let frameByteCount = encodedData.count

                let flags = baseFrameFlagsSnapshot.union(dynamicFrameFlags)
                let dimToken = dimensionToken
                let currentEpoch = epoch
                let sendDeadline = Self.mediaSendDeadline(
                    encodedAt: now,
                    isKeyframe: isKeyframe,
                    latencyMode: latencyMode,
                    transportPathKind: transportPathKind,
                    targetFrameRate: currentFrameRate
                )

                let generation = packetSender.currentGeneration
                if isKeyframe {
                    let queuedBytes = packetSender.queuedByteCount
                    Task(priority: .userInitiated) {
                        await self.logDependencyRecoveryKeyframeIfNeeded(
                            frameNumber: reservation.frameNumber,
                            queuedBytes: queuedBytes
                        )
                        await self.markKeyframeInFlight(frameNumber: reservation.frameNumber)
                        await self.markKeyframeSent()
                    }
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
                    sendDeadline: sendDeadline,
                    targetFrameRate: currentFrameRate,
                    pacingOverride: pacingOverride
                )
                packetSender.enqueue(workItem)
            }, onFrameComplete: { [weak self] in
                Task(priority: .userInitiated) { await self?.finishEncoding() }
            }
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
        await engine.setAdmissionDropper { [weak self] in
            let snapshot = frameInboxSnapshot.pendingSnapshot
            let backpressure = self?.backpressureActiveSnapshot ?? false
            let pendingThreshold = backpressure
                ? max(1, snapshot.capacity - 1)
                : snapshot.capacity
            let pendingPressure = snapshot.pending >= pendingThreshold
            guard pendingPressure || backpressure else { return false }
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

    func restartDisplayCaptureForCadenceRecovery(reason: String) async {
        guard captureMode == .display, !isResizing, !encodingSuspendedForResize else { return }
        let restarted = await captureEngine?.restartCaptureForDeliveryValidation(reason: reason) ?? false
        guard restarted else { return }
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Capture cadence recovery",
            noteLoss: true,
            ignoreExistingInFlight: true
        )
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

    nonisolated static func mediaSendDeadline(
        encodedAt: CFAbsoluteTime,
        isKeyframe: Bool,
        latencyMode: MirageStreamLatencyMode,
        transportPathKind: MirageNetworkPathKind = .unknown,
        targetFrameRate: Int
    ) -> CFAbsoluteTime? {
        guard !isKeyframe else { return nil }
        let frameInterval = 1.0 / Double(max(1, targetFrameRate))
        let deadlineOffset = switch latencyMode {
        case .lowestLatency:
            if transportPathKind == .awdl {
                clamp(frameInterval * 5.0, min: 0.080, max: 0.120)
            } else {
                clamp(frameInterval * 2.0, min: 0.016, max: 0.050)
            }
        case .balanced:
            if transportPathKind == .awdl {
                clamp(frameInterval * 5.0, min: 0.080, max: 0.120)
            } else {
                clamp(frameInterval * 3.0, min: 0.033, max: 0.080)
            }
        case .smoothest:
            clamp(0.160 + frameInterval * 2.0, min: 0.120, max: 0.300)
        }
        return encodedAt + deadlineOffset
    }

    nonisolated private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
#endif
