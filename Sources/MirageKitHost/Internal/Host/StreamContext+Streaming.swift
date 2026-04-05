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
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0
        var pFrameDiagnosticCounter: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
                guard let self else { return }

                if isKeyframe {
                    MirageLogger.stream(
                        "Keyframe encoded: size=\(encodedData.count), frame=\(localFrameNumber), stream=\(streamID)"
                    )
                } else {
                    pFrameDiagnosticCounter += 1
                    if pFrameDiagnosticCounter % 60 == 1 {
                        let crc = CRC32.calculate(encodedData)
                        let header = encodedData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                        MirageLogger.stream("Encoded P-frame CRC=\(String(format: "%08X", crc)), size=\(encodedData.count), header: \(header)")
                    }
                }

                let contentRect = pinnedContentRect ?? currentContentRect
                let frameNum = localFrameNumber
                let seqStart = localSequenceNumber

                let now = CFAbsoluteTimeGetCurrent()
                let fecBlockSize = resolvedFECBlockSize(isKeyframe: isKeyframe, now: now)
                let pacingOverride = isKeyframe ? startupKeyframePacingOverride(now: now) : nil
                let frameByteCount = encodedData.count
                let dataFragments = (frameByteCount + maxPayloadSize - 1) / maxPayloadSize
                let parityFragments = fecBlockSize > 1 ? (dataFragments + fecBlockSize - 1) / fecBlockSize : 0
                let totalFragments = dataFragments + parityFragments
                let wireBytes = frameByteCount + parityFragments * maxPayloadSize
                localSequenceNumber += UInt32(totalFragments)
                localFrameNumber += 1

                let flags = baseFrameFlags.union(dynamicFrameFlags)
                let dimToken = dimensionToken
                let epoch = epoch

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
                    frameNumber: frameNum,
                    sequenceNumberStart: seqStart,
                    additionalFlags: flags,
                    dimensionToken: dimToken,
                    epoch: epoch,
                    fecBlockSize: fecBlockSize,
                    wireBytes: wireBytes,
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
}
#endif
