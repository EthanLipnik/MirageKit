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
            onSendError: onSendError
        )
        self.packetSender = sender
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
            performanceMode: performanceMode,
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
        activePixelFormat = await encoder.getActivePixelFormat()
        shouldEncodeFrames = false
        startupFrameCachingEnabled = true
        cachedStartupFrame = nil
        MirageLogger.stream("Waiting for UDP registration before encoding")
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
        let streamID = streamID
        guard let packetSender = self.packetSender, let encoder = self.encoder else {
            MirageLogger.stream("startEncoderWithSharedCallback skipped — stream \(streamID) already stopped")
            return
        }
        let callbackSequencer = StreamEncodingCallbackSequencer()
        let baseFrameFlags = self.baseFrameFlags

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
                guard let self else { return }

                let now = CFAbsoluteTimeGetCurrent()
                let fecBlockSize = self.resolvedFECBlockSize(isKeyframe: isKeyframe, now: now)
                let reservation = callbackSequencer.reserve(
                    frameByteCount: encodedData.count,
                    maxPayloadSize: self.maxPayloadSize,
                    fecBlockSize: fecBlockSize,
                    isKeyframe: isKeyframe
                )

                if isKeyframe {
                    MirageLogger.stream(
                        "Keyframe encoded: size=\(encodedData.count), frame=\(reservation.frameNumber), stream=\(streamID)"
                    )
                } else if reservation.shouldLogPFrameDiagnostic,
                          MirageLogger.isEnabled(.frameAssembly) {
                    let crc = CRC32.calculate(encodedData)
                    let header = encodedData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    MirageLogger.log(
                        .frameAssembly,
                        "Encoded P-frame CRC=\(String(format: "%08X", crc)), size=\(encodedData.count), header: \(header)"
                    )
                }

                let contentRect = pinnedContentRect ?? self.currentContentRect
                let pacingOverride = isKeyframe ? startupKeyframePacingOverride(now: now) : nil
                let frameByteCount = encodedData.count

                let flags = baseFrameFlags.union(self.dynamicFrameFlags)
                let dimToken = self.dimensionToken
                let epoch = self.epoch

                let generation = packetSender.currentGenerationSnapshot()
                if isKeyframe {
                    Task(priority: .userInitiated) {
                        await self.markKeyframeInFlight()
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
                    epoch: epoch,
                    fecBlockSize: fecBlockSize,
                    wireBytes: reservation.wireBytes,
                    logPrefix: logPrefix,
                    generation: generation,
                    encodedAt: now,
                    pacingOverride: pacingOverride,
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

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        guard isRunning, self.encoder != nil else {
            throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
        }
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let engine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
        self.captureEngine = engine
        if let captureStallStageHandler {
            guard isRunning, self.encoder != nil else {
                self.captureEngine = nil
                throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
            }
            await engine.setCaptureStallStageHandler(captureStallStageHandler)
        }
        let frameInbox = self.frameInbox
        guard isRunning, self.encoder != nil else {
            self.captureEngine = nil
            throw StreamCaptureEngineSetupError.streamStoppedDuringSetup
        }
        await engine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot()
            let backpressure = self?.backpressureActiveSnapshot ?? false
            let pendingThreshold = backpressure
                ? max(1, snapshot.capacity - 1)
                : snapshot.capacity
            let pendingPressure = snapshot.pending >= pendingThreshold
            guard pendingPressure || backpressure else { return false }
            if frameInbox.scheduleIfNeeded() {
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
        return await captureEngine.hasObservedDisplayStartupSample()
    }

    func hasCachedStartupFrame() -> Bool {
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
