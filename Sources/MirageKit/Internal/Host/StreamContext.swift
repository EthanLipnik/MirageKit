import Foundation
import CoreMedia
import CoreVideo

#if os(macOS)
import ScreenCaptureKit

/// Manages the capture → encode → send pipeline for a single stream
/// Uses virtual displays for window isolation, with window-level capture
actor StreamContext {
    let streamID: StreamID
    private let windowID: WindowID
    private let encoderConfig: MirageEncoderConfiguration
    private var streamScale: CGFloat
    private var baseCaptureSize: CGSize = .zero
    private var currentEncodedSize: CGSize = .zero
    private var currentCaptureSize: CGSize = .zero
    private var activePixelFormat: MiragePixelFormat
    private var lastWindowFrame: CGRect = .zero
    private enum CaptureMode {
        case window
        case display
    }
    private var captureMode: CaptureMode = .window
    /// Max payload size per UDP packet (excludes Mirage header).
    nonisolated let maxPayloadSize: Int
    nonisolated(unsafe) private var shouldEncodeFrames: Bool = true

    // Window capture engine (used both for legacy and virtual display modes)
    private var captureEngine: WindowCaptureEngine?

    // Virtual display components (provides window isolation)
    // Uses SharedVirtualDisplayManager for single shared display across all streams
    private var virtualDisplayContext: SharedVirtualDisplayManager.ManagedDisplayContext?
    private var useVirtualDisplay: Bool = true

    private var encoder: HEVCEncoder?
    private var isRunning = false
    private var frameNumber: UInt32 = 0
    private var sequenceNumber: UInt32 = 0

    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Incremented each time encoder dimensions change. Sent in every frame header
    /// so client can discard frames with mismatched tokens.
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (token is incremented on actor, read in callback)
    nonisolated(unsafe) private var dimensionToken: UInt16 = 0

    /// Current content rectangle within the capture buffer
    /// Updated per-frame from ScreenCaptureKit to handle black padding
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (always set before read, in frame order)
    nonisolated(unsafe) private var currentContentRect: CGRect = .zero

    // Bounded frame inbox to decouple capture from encode with low latency.
    nonisolated private let frameInbox: StreamFrameInbox
    private var inFlightCount: Int = 0
    private var maxInFlightFrames: Int
    private let maxInFlightFramesCap: Int
    private let frameBufferDepth: Int
    private var lastEncodeActivityTime: CFAbsoluteTime = 0
    private var droppedFrameCount: UInt64 = 0
    private var idleSkippedCount: UInt64 = 0
    private var idleEncodedCount: UInt64 = 0
    private var encodedFrameCount: UInt64 = 0
    private var lastStreamStatsLogTime: CFAbsoluteTime = 0
    private var metricsUpdateHandler: (@Sendable (StreamMetricsMessage) -> Void)?
    private var activeQuality: Float
    private let qualityFloor: Float
    private let qualityCeiling: Float
    private let keyframeQualityFloor: Float
    private var pendingKeyframeReason: String? = nil
    private var pendingKeyframeDeadline: CFAbsoluteTime = 0
    private var isKeyframeEncoding: Bool = false
    private var pendingKeyframeRequiresFlush: Bool = false
    private var pendingKeyframeUrgent: Bool = false
    private var pendingKeyframeRequiresReset: Bool = false
    private var lastQualityAdjustmentTime: CFAbsoluteTime = 0
    private let qualityAdjustmentCooldown: CFAbsoluteTime = 0.35
    private var qualityOverBudgetCount: Int = 0
    private var qualityUnderBudgetCount: Int = 0
    private let qualityDropThreshold: Int = 3
    private let qualityRaiseThreshold: Int = 4
    private let qualityDropStep: Float = 0.02
    private let qualityDropStepHighPressure: Float = 0.05
    private let qualityRaiseStep: Float = 0.03
    private var lastInFlightAdjustmentTime: CFAbsoluteTime = 0
    private let inFlightAdjustmentCooldown: CFAbsoluteTime = 1.0

    // Pipeline throughput metrics (interval counters)
    private var captureIntervalCount: UInt64 = 0
    private var captureDroppedIntervalCount: UInt64 = 0
    private var encodeAttemptIntervalCount: UInt64 = 0
    private var encodeAcceptedIntervalCount: UInt64 = 0
    private var encodeRejectedIntervalCount: UInt64 = 0
    private var encodeErrorIntervalCount: UInt64 = 0
    private var lastPipelineStatsLogTime: CFAbsoluteTime = 0
    private let pipelineStatsInterval: CFAbsoluteTime = 2.0

    /// Maximum time to wait for encode progress before considering encoder stuck (ms)
    /// During drag operations, VideoToolbox can block - we need to detect this and recover
    private let maxEncodeTimeMs: Double

    /// Flag indicating encoder needs to be reset on next encode attempt
    /// Set when encoder is detected as stuck, cleared after reset
    private var needsEncoderReset: Bool = false

    /// Timestamp of last encoder reset (for cooldown)
    private var lastEncoderResetTime: CFAbsoluteTime = 0

    /// Minimum time between encoder resets (seconds)
    /// Prevents cascading resets during SCK pauses which cause multiple keyframes
    private let encoderResetCooldown: CFAbsoluteTime = 1.0

    /// Flag to skip encoding during resize operations
    /// When true, incoming frames are dropped to prevent decode errors and wasted CPU
    /// Set before dimension updates begin, cleared after completion
    private var isResizing: Bool = false

    // MARK: - Backpressure

    /// Packet queue backpressure thresholds (bytes)
    private let minQueuedBytes: Int = 1_000_000
    private let maxQueuedBytesCap: Int = 8_000_000
    private var maxQueuedBytes: Int = 2_000_000
    private var queuePressureBytes: Int = 1_500_000
    private let backpressureLogInterval: CFAbsoluteTime = 1.0
    private var lastBackpressureLogTime: CFAbsoluteTime = 0
    private var backpressureActive: Bool = false

    /// Keyframe request throttling
    private let keyframeRequestCooldown: CFAbsoluteTime = 0.25
    private let keyframeInFlightCap: CFAbsoluteTime = 1.0
    private let keyframeSettleTimeout: CFAbsoluteTime = 2.0
    private let keyframeQueueSettleFactor: Double = 0.4
    private var lastKeyframeRequestTime: CFAbsoluteTime = 0
    private var keyframeSendDeadline: CFAbsoluteTime = 0

    /// Scheduled keyframe cadence derived from keyFrameInterval/currentFrameRate.
    private var keyframeIntervalSeconds: CFAbsoluteTime = 0
    private var keyframeMaxIntervalSeconds: CFAbsoluteTime = 0
    private var lastKeyframeTime: CFAbsoluteTime = 0

    /// Frame rate for cadence and queue limits
    private var currentFrameRate: Int

    /// Smoothed dirty percentage (0-1) used to avoid keyframes during high motion.
    private var smoothedDirtyPercentage: Double = 0
    private let motionSmoothingFactor: Double = 0.2
    private let keyframeMotionThreshold: Double = 0.25

    /// Callback for sending encoded packets
    private var onEncodedPacket: (@Sendable (Data, FrameHeader) -> Void)?

    /// Serializes packet fragmentation/sending to preserve frame order
    private var packetSender: StreamPacketSender?

    /// Callback for content bounds changes (menus, sheets appearing)
    private var onContentBoundsChanged: (@Sendable (CGRect) -> Void)?

    /// Callback for new independent window detection
    private var onNewWindowDetected: (@Sendable (MirageWindow) -> Void)?

    /// Base flags to include on all frames for this stream
    private let baseFrameFlags: FrameFlags

    /// Dynamic flags applied to the next encoded frame.
    nonisolated(unsafe) private var dynamicFrameFlags: FrameFlags = []

    /// Stream epoch for discontinuity boundaries.
    /// Incremented when the host resets capture or send state.
    nonisolated(unsafe) private var epoch: UInt16 = 0

    /// Whether idle frames should be encoded to maintain cadence.
    private let shouldMaintainIdleFrames: Bool

    /// Quality preset used to configure latency-sensitive defaults.
    private let qualityPreset: MirageQualityPreset?
    /// When true, force low-latency buffering regardless of preset.
    private let useLowLatencyPipeline: Bool
    /// Client-requested stream scale (before adaptive adjustments).
    private var requestedStreamScale: CGFloat
    /// Whether adaptive stream scaling is allowed for this stream.
    private var adaptiveScaleEnabled: Bool
    /// Adaptive multiplier applied when capture FPS falls below target.
    private var adaptiveScale: CGFloat = 1.0
    /// Adaptive stream scale update handler (host sends dimension update to client).
    private var streamScaleUpdateHandler: (@Sendable (StreamID) -> Void)?
    private var adaptiveScaleLowStreak: Int = 0
    private var adaptiveScaleHighStreak: Int = 0
    private var lastAdaptiveScaleChangeTime: CFAbsoluteTime = 0
    private let adaptiveScaleCooldown: CFAbsoluteTime = 6.0
    private let adaptiveScaleLowThreshold: Double = 0.85
    private let adaptiveScaleHighThreshold: Double = 0.97
    private let adaptiveScaleDownSamples: Int = 2
    private let adaptiveScaleUpSamples: Int = 4
    private let adaptiveScaleDownStep: CGFloat = 0.9
    private let adaptiveScaleUpStep: CGFloat = 1.05
    private let adaptiveScaleMin: CGFloat = 0.7

    init(
        streamID: StreamID,
        windowID: WindowID,
        encoderConfig: MirageEncoderConfiguration,
        qualityPreset: MirageQualityPreset? = nil,
        streamScale: CGFloat = 1.0,
        maxPacketSize: Int = MirageDefaultMaxPacketSize,
        additionalFrameFlags: FrameFlags = [],
        adaptiveScaleEnabled: Bool = true
    ) {
        self.streamID = streamID
        self.windowID = windowID
        self.encoderConfig = encoderConfig
        self.qualityPreset = qualityPreset
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        self.streamScale = clampedScale
        self.requestedStreamScale = clampedScale
        self.adaptiveScaleEnabled = adaptiveScaleEnabled
        self.baseFrameFlags = additionalFrameFlags
        self.shouldMaintainIdleFrames = additionalFrameFlags.contains(.desktopStream)
        self.maxPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        self.currentFrameRate = encoderConfig.targetFrameRate
        self.activePixelFormat = encoderConfig.pixelFormat
        self.useLowLatencyPipeline = qualityPreset == .lowLatency || encoderConfig.targetFrameRate >= 120
        let bufferDepth = Self.frameBufferDepth(useLowLatencyPipeline: useLowLatencyPipeline, frameRate: encoderConfig.targetFrameRate)
        let inFlightCap = min(bufferDepth, Self.inFlightCap(for: encoderConfig.targetFrameRate))
        self.maxInFlightFramesCap = max(1, inFlightCap)
        self.maxInFlightFrames = 1
        self.frameBufferDepth = bufferDepth
        self.frameInbox = StreamFrameInbox(capacity: bufferDepth)
        self.maxEncodeTimeMs = encoderConfig.targetFrameRate >= 120 ? 900 : 600
        self.shouldEncodeFrames = false
        let qualityFloorFactor: Float = 0.6
        let keyframeFloorFactor: Float = 0.6
        self.qualityCeiling = encoderConfig.frameQuality
        self.qualityFloor = max(0.1, encoderConfig.frameQuality * qualityFloorFactor)
        self.activeQuality = encoderConfig.frameQuality
        self.keyframeQualityFloor = max(0.1, encoderConfig.keyframeQuality * keyframeFloorFactor)
        let cadence = Self.keyframeCadence(
            intervalFrames: encoderConfig.keyFrameInterval,
            frameRate: encoderConfig.targetFrameRate
        )
        self.keyframeIntervalSeconds = cadence.interval
        self.keyframeMaxIntervalSeconds = cadence.maxInterval
    }

    private static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    private static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }

    private static func frameBufferDepth(useLowLatencyPipeline: Bool, frameRate: Int) -> Int {
        if useLowLatencyPipeline {
            return frameRate >= 120 ? 2 : 1
        }
        return frameRate >= 120 ? 3 : 2
    }

    private static func inFlightCap(for frameRate: Int) -> Int {
        frameRate >= 120 ? 2 : 1
    }

    /// Update the current content rectangle (called per-frame from capture callback)
    private func setContentRect(_ rect: CGRect) {
        currentContentRect = rect
    }

    private func scaledOutputSize(for baseSize: CGSize) -> CGSize {
        let clampedScale = streamScale
        let width = StreamContext.alignedEvenPixel(baseSize.width * clampedScale)
        let height = StreamContext.alignedEvenPixel(baseSize.height * clampedScale)
        return CGSize(width: width, height: height)
    }

    private func updateCaptureSizesIfNeeded(_ bufferSize: CGSize) {
        guard bufferSize.width > 0, bufferSize.height > 0 else { return }
        guard bufferSize != currentCaptureSize else { return }
        currentCaptureSize = bufferSize
        currentEncodedSize = bufferSize
        if streamScale > 0 {
            baseCaptureSize = CGSize(width: bufferSize.width / streamScale, height: bufferSize.height / streamScale)
        }
        updateQueueLimits()
    }

    private func updateQueueLimits() {
        guard currentEncodedSize.width > 0, currentEncodedSize.height > 0 else { return }
        let pixelCount = Double(currentEncodedSize.width * currentEncodedSize.height)
        let frameRateFactor = currentFrameRate >= 120 ? 0.30 : 0.20
        let pixelBased = Int((pixelCount * frameRateFactor).rounded())
        let bitrateBased: Int
        if let maxBitrate = encoderConfig.maxBitrate, maxBitrate > 0 {
            let bytesPerSecond = Double(maxBitrate) / 8.0
            let windowSeconds = currentFrameRate >= 120 ? 0.20 : 0.25
            bitrateBased = Int((bytesPerSecond * windowSeconds).rounded())
        } else {
            bitrateBased = 0
        }
        let computed = max(pixelBased, bitrateBased)
        let clamped = max(minQueuedBytes, min(maxQueuedBytesCap, computed))
        maxQueuedBytes = clamped
        queuePressureBytes = max(minQueuedBytes, Int(Double(clamped) * 0.75))
    }

    private func advanceEpoch(reason: String) {
        if dynamicFrameFlags.contains(.discontinuity) {
            return
        }
        epoch &+= 1
        dynamicFrameFlags.insert(.discontinuity)
        MirageLogger.stream("Stream epoch advanced to \(epoch) (\(reason))")
    }

    private func markKeyframeInFlight() {
        let deadline = CFAbsoluteTimeGetCurrent() + keyframeInFlightCap
        if deadline > keyframeSendDeadline {
            keyframeSendDeadline = deadline
        }
    }

    private func markKeyframeRequestIssued() {
        let deadline = CFAbsoluteTimeGetCurrent() + keyframeInFlightCap
        if deadline > keyframeSendDeadline {
            keyframeSendDeadline = deadline
        }
    }

    private func shouldThrottleKeyframeRequest(requestLabel: String, checkInFlight: Bool) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if checkInFlight, now < keyframeSendDeadline {
            let remaining = Int(((keyframeSendDeadline - now) * 1000).rounded())
            MirageLogger.stream("\(requestLabel) skipped (keyframe in flight, \(remaining)ms remaining)")
            return true
        }
        let elapsed = now - lastKeyframeRequestTime
        if elapsed < keyframeRequestCooldown {
            let remaining = Int(((keyframeRequestCooldown - elapsed) * 1000).rounded())
            MirageLogger.stream("\(requestLabel) skipped (cooldown \(remaining)ms)")
            return true
        }
        lastKeyframeRequestTime = now
        return false
    }

    @discardableResult
    private func queueKeyframe(
        reason: String,
        checkInFlight: Bool,
        requiresFlush: Bool = false,
        requiresReset: Bool = false,
        urgent: Bool = false
    ) -> Bool {
        guard !shouldThrottleKeyframeRequest(requestLabel: reason, checkInFlight: checkInFlight) else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = reason
        if urgent {
            pendingKeyframeDeadline = now
            pendingKeyframeUrgent = true
        } else {
            pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
        }
        if requiresReset {
            advanceEpoch(reason: reason)
            pendingKeyframeRequiresReset = true
            pendingKeyframeRequiresFlush = true
        }
        if requiresFlush {
            pendingKeyframeRequiresFlush = true
        }
        return true
    }

    private func forceKeyframeAfterCaptureRestart() {
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        let queued = queueKeyframe(
            reason: "Fallback keyframe",
            checkInFlight: false,
            requiresFlush: true,
            requiresReset: true,
            urgent: true
        )
        if !queued {
            MirageLogger.stream("Fallback keyframe skipped (unable to queue after restart)")
        }
    }

    private func shouldEmitPendingKeyframe(queueBytes: Int) -> Bool {
        guard pendingKeyframeReason != nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        if pendingKeyframeUrgent {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            pendingKeyframeUrgent = false
            lastKeyframeTime = now
            return true
        }
        let settleThreshold = max(minQueuedBytes, Int(Double(queuePressureBytes) * keyframeQueueSettleFactor))
        let settled = queueBytes <= settleThreshold && inFlightCount == 0
        let highMotion = smoothedDirtyPercentage >= keyframeMotionThreshold
        if (settled && !highMotion) || now >= pendingKeyframeDeadline {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            lastKeyframeTime = now
            return true
        }
        return false
    }

    private static func keyframeCadence(
        intervalFrames: Int,
        frameRate: Int
    ) -> (interval: CFAbsoluteTime, maxInterval: CFAbsoluteTime) {
        let clampedFrames = max(1, intervalFrames)
        let clampedRate = max(1, frameRate)
        let intervalSeconds = Double(clampedFrames) / Double(clampedRate)
        let cadence = max(1.0, intervalSeconds)
        let maxCadence = max(cadence * 2.0, cadence + 1.0)
        return (cadence, maxCadence)
    }

    private func updateKeyframeCadence() {
        let cadence = Self.keyframeCadence(
            intervalFrames: encoderConfig.keyFrameInterval,
            frameRate: currentFrameRate
        )
        keyframeIntervalSeconds = cadence.interval
        keyframeMaxIntervalSeconds = cadence.maxInterval
    }

    private func updateMotionState(with frameInfo: CapturedFrameInfo) {
        let normalized = max(0.0, min(1.0, Double(frameInfo.dirtyPercentage) / 100.0))
        if smoothedDirtyPercentage == 0 {
            smoothedDirtyPercentage = normalized
        } else {
            smoothedDirtyPercentage = smoothedDirtyPercentage * (1.0 - motionSmoothingFactor)
                + normalized * motionSmoothingFactor
        }
    }

    private func shouldQueueScheduledKeyframe(queueBytes: Int) -> Bool {
        guard shouldEncodeFrames else { return false }
        guard !isResizing else { return false }
        guard lastKeyframeTime > 0 else { return false }
        guard pendingKeyframeReason == nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastKeyframeTime
        guard elapsed >= keyframeIntervalSeconds else { return false }

        let highMotion = smoothedDirtyPercentage >= keyframeMotionThreshold
        let queueBackedUp = queueBytes >= queuePressureBytes
        let allowDespitePressure = elapsed >= keyframeMaxIntervalSeconds

        if (highMotion || queueBackedUp) && !allowDespitePressure {
            return false
        }

        return !shouldThrottleKeyframeRequest(requestLabel: "Scheduled keyframe", checkInFlight: true)
    }

    private func markKeyframeSent() {
        lastKeyframeTime = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        if dynamicFrameFlags.contains(.discontinuity) {
            dynamicFrameFlags.remove(.discontinuity)
        }
    }

    nonisolated func enqueueCapturedFrame(_ frame: CapturedFrame) {
        guard shouldEncodeFrames else { return }
        if frameInbox.enqueue(frame) {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        }
    }

    private func scheduleProcessingIfNeeded() {
        guard frameInbox.hasPending() else { return }
        if frameInbox.scheduleIfNeeded() {
            Task(priority: .userInitiated) { await processPendingFrames() }
        }
    }

    private func resetStalledInFlightIfNeeded(label: String) -> Bool {
        guard inFlightCount > 0, lastEncodeActivityTime > 0 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = (now - lastEncodeActivityTime) * 1000
        guard elapsedMs > maxEncodeTimeMs else { return false }
        MirageLogger.stream("Encoder in-flight stalled for \(Int(elapsedMs))ms (\(label)), scheduling reset")
        inFlightCount = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = true
        return true
    }

    private func resetPipelineStateForReconfiguration(reason: String) {
        if inFlightCount > 0 || isKeyframeEncoding || lastEncodeActivityTime > 0 {
            MirageLogger.stream("Resetting pipeline state for \(reason) (inFlight=\(inFlightCount))")
        }
        inFlightCount = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = false
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        backpressureActive = false
        frameInbox.clear()
    }

    /// Process pending frames (encodes using HEVC and keeps only the most recent)
    private func processPendingFrames() async {
        defer {
            frameInbox.markDrainComplete()
            Task { await self.logPipelineStatsIfNeeded() }
        }
        // Skip encoding during resize operations - prevents decode errors and wasted CPU
        // Frames are dropped but connection stays alive; keyframe forced after resize
        if isResizing || !shouldEncodeFrames {
            frameInbox.clear()
            return
        }

        let didResetStall = resetStalledInFlightIfNeeded(label: "processPendingFrames")
        if isKeyframeEncoding, !didResetStall {
            return
        }

        let captured = frameInbox.consumeEnqueuedCount()
        if captured > 0 {
            captureIntervalCount += captured
        }
        let dropped = frameInbox.consumeDroppedCount()
        if dropped > 0 {
            captureDroppedIntervalCount += dropped
            droppedFrameCount += dropped
        }

        while inFlightCount < maxInFlightFrames {
            guard let frame = frameInbox.takeNext() else { return }

            // Check if encoder has been stuck for too long (common during drag operations)
            // If so, mark for reset and process new frame
            let encoderStuck = inFlightCount > 0 && lastEncodeActivityTime > 0 &&
                (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000 > maxEncodeTimeMs

            if encoderStuck {
                let stuckTime = (CFAbsoluteTimeGetCurrent() - lastEncodeActivityTime) * 1000
                MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, scheduling reset")
                inFlightCount = 0
                lastEncodeActivityTime = 0
                needsEncoderReset = true  // Will be handled in processLatestFrame
            }

            let bufferSize = CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            updateCaptureSizesIfNeeded(bufferSize)
            updateMotionState(with: frame.info)

            // Reset encoder if it was stuck on previous frame
            // This invalidates the VTCompressionSession and creates a new one
            // Uses cooldown to prevent cascading resets during SCK pauses
            var didResetEncoder = false
            if needsEncoderReset {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastEncoderResetTime > encoderResetCooldown {
                    MirageLogger.stream("Resetting stuck encoder before next frame")

                    do {
                        advanceEpoch(reason: "encoder reset")
                        await packetSender?.resetQueue(reason: "encoder reset")
                        try await encoder?.reset()
                        didResetEncoder = true
                        lastEncoderResetTime = now
                    } catch {
                        MirageLogger.error(.stream, "Encoder reset failed: \(error)")
                    }
                } else {
                    let remainingSeconds = (encoderResetCooldown - (now - lastEncoderResetTime))
                        .formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.stream("Encoder reset skipped (cooldown active, \(remainingSeconds)s remaining)")
                }
                needsEncoderReset = false  // Clear flag even if we skipped due to cooldown
            }

            let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
            await adjustQualityForQueue(queueBytes: queueBytes)

            var forceKeyframe = didResetEncoder
            if !forceKeyframe, let captureEngine {
                let shouldRequest = await captureEngine.consumePendingKeyframeRequest()
                if shouldRequest {
                    forceKeyframeAfterCaptureRestart()
                }
            }
            if !forceKeyframe {
                forceKeyframe = shouldEmitPendingKeyframe(queueBytes: queueBytes)
            }

            if backpressureActive {
                if queueBytes <= queuePressureBytes {
                    backpressureActive = false
                    MirageLogger.stream("Backpressure cleared (queue \(Int(Double(queueBytes) / 1024.0))KB)")
                } else {
                    droppedFrameCount += 1
                    logStreamStatsIfNeeded()
                    continue
                }
            } else if queueBytes > maxQueuedBytes && !forceKeyframe {
                backpressureActive = true
                droppedFrameCount += 1
                let queuedKB = (Double(queueBytes) / 1024.0).rounded()
                MirageLogger.stream("Backpressure: pausing encode (queue \(Int(queuedKB))KB)")
                logStreamStatsIfNeeded()
                continue
            }

            if shouldQueueScheduledKeyframe(queueBytes: queueBytes) {
                queueKeyframe(reason: "Scheduled keyframe", checkInFlight: true)
            }

            let isIdleFrame = frame.info.isIdleFrame
            if isIdleFrame {
                let shouldEncodeIdle = shouldMaintainIdleFrames && queueBytes < queuePressureBytes
                if !shouldEncodeIdle {
                    idleSkippedCount += 1
                    logStreamStatsIfNeeded()
                    continue
                }
            }

            // Encode using HEVC - P-frames automatically encode only what changed
            // Keyframes are handled by scheduled cadence + recovery; don't use capture hints.

            // Store contentRect for use in frame header
            setContentRect(frame.info.contentRect)

            do {
                guard let encoder else {
                    continue
                }
                encodeAttemptIntervalCount += 1
                let encodeStartTime = CFAbsoluteTimeGetCurrent()
                if forceKeyframe {
                    if pendingKeyframeRequiresFlush {
                        pendingKeyframeRequiresFlush = false
                        if pendingKeyframeRequiresReset {
                            pendingKeyframeRequiresReset = false
                            await packetSender?.resetQueue(reason: "keyframe request")
                        } else {
                            await packetSender?.bumpGeneration(reason: "keyframe request")
                        }
                        await encoder.flush()
                    }
                    await encoder.prepareForKeyframe(quality: keyframeQuality(for: queueBytes))
                }
                let accepted = try await encoder.encodeFrame(frame, forceKeyframe: forceKeyframe)
                if accepted {
                    encodeAcceptedIntervalCount += 1
                    if inFlightCount == 0 {
                        lastEncodeActivityTime = encodeStartTime
                    }
                    inFlightCount += 1
                    encodedFrameCount += 1
                    if forceKeyframe {
                        isKeyframeEncoding = true
                    }
                    if isIdleFrame {
                        idleEncodedCount += 1
                    }
                } else if forceKeyframe {
                    encodeRejectedIntervalCount += 1
                    droppedFrameCount += 1
                    let now = CFAbsoluteTimeGetCurrent()
                    pendingKeyframeReason = "Deferred keyframe"
                    pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
                } else {
                    encodeRejectedIntervalCount += 1
                    droppedFrameCount += 1
                }
            } catch {
                encodeErrorIntervalCount += 1
                droppedFrameCount += 1
                MirageLogger.error(.stream, "Encode error: \(error)")
                continue
            }
            logStreamStatsIfNeeded()
        }
    }

    /// Get dropped frame statistics
    func getDroppedFrameCount() -> UInt64 {
        return droppedFrameCount
    }

    func setMetricsUpdateHandler(_ handler: (@Sendable (StreamMetricsMessage) -> Void)?) {
        metricsUpdateHandler = handler
    }

    func setStreamScaleUpdateHandler(_ handler: (@Sendable (StreamID) -> Void)?) {
        streamScaleUpdateHandler = handler
    }

    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        shouldEncodeFrames = true
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0

        if let encoder {
            await encoder.resetFrameNumber()
            await encoder.forceKeyframe()
        }

        MirageLogger.stream("UDP registration confirmed, encoding resumed")
    }

    private func finishEncoding() async {
        guard inFlightCount > 0 else { return }
        inFlightCount -= 1
        lastEncodeActivityTime = CFAbsoluteTimeGetCurrent()

        if inFlightCount == 0, isKeyframeEncoding {
            isKeyframeEncoding = false
            await encoder?.restoreBaseQualityIfNeeded()
        }

        if frameInbox.hasPending() && inFlightCount < maxInFlightFrames {
            scheduleProcessingIfNeeded()
        }
    }

    private func logStreamStatsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStreamStatsLogTime
        guard lastStreamStatsLogTime == 0 || elapsed > 2.0 else { return }
        let inFlight = inFlightCount
        MirageLogger.stream("Encode stats: encoded=\(encodedFrameCount), idleEncoded=\(idleEncodedCount), idleSkipped=\(idleSkippedCount), inFlight=\(inFlight)")
        if let metricsUpdateHandler, lastStreamStatsLogTime > 0 {
            let encodedFPS = Double(encodedFrameCount) / elapsed
            let idleEncodedFPS = Double(idleEncodedCount) / elapsed
            let message = StreamMetricsMessage(
                streamID: streamID,
                encodedFPS: encodedFPS,
                idleEncodedFPS: idleEncodedFPS,
                droppedFrames: droppedFrameCount,
                activeQuality: activeQuality
            )
            metricsUpdateHandler(message)
        }
        encodedFrameCount = 0
        idleEncodedCount = 0
        idleSkippedCount = 0
        lastStreamStatsLogTime = now
    }

    private func logPipelineStatsIfNeeded() async {
        guard MirageLogger.isEnabled(.metrics) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastPipelineStatsLogTime > 0 else {
            lastPipelineStatsLogTime = now
            return
        }
        let elapsed = now - lastPipelineStatsLogTime
        guard elapsed >= pipelineStatsInterval else { return }

        let captureFPS = Double(captureIntervalCount) / elapsed
        let encodeAttemptFPS = Double(encodeAttemptIntervalCount) / elapsed
        let encodeFPS = Double(encodeAcceptedIntervalCount) / elapsed
        let captureText = captureFPS.formatted(.number.precision(.fractionLength(1)))
        let attemptText = encodeAttemptFPS.formatted(.number.precision(.fractionLength(1)))
        let encodeText = encodeFPS.formatted(.number.precision(.fractionLength(1)))
        let encodeAvgMs = await encoder?.getAverageEncodeTimeMs() ?? 0
        let encodeAvgText = encodeAvgMs.formatted(.number.precision(.fractionLength(1)))
        let queueBytes = packetSender?.queuedBytesSnapshot() ?? 0
        let queueKB = Int((Double(queueBytes) / 1024.0).rounded())
        let pendingCount = frameInbox.pendingCount()

        MirageLogger.metrics(
            "Pipeline: capture=\(captureText)fps drop=\(captureDroppedIntervalCount) " +
            "encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) error=\(encodeErrorIntervalCount) " +
            "inFlight=\(inFlightCount) buffer=\(pendingCount)/\(frameBufferDepth) " +
            "queue=\(queueKB)KB encodeAvg=\(encodeAvgText)ms"
        )

        await updateAdaptiveScaleIfNeeded(captureFPS: captureFPS)

        await updateInFlightLimitIfNeeded(
            averageEncodeMs: encodeAvgMs,
            pendingCount: pendingCount
        )

        captureIntervalCount = 0
        captureDroppedIntervalCount = 0
        encodeAttemptIntervalCount = 0
        encodeAcceptedIntervalCount = 0
        encodeRejectedIntervalCount = 0
        encodeErrorIntervalCount = 0
        lastPipelineStatsLogTime = now
    }

    private func updateAdaptiveScaleIfNeeded(captureFPS: Double) async {
        guard adaptiveScaleEnabled else { return }
        guard currentFrameRate >= 120 else { return }
        guard shouldEncodeFrames else { return }
        guard !isResizing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if lastAdaptiveScaleChangeTime > 0,
           now - lastAdaptiveScaleChangeTime < adaptiveScaleCooldown {
            return
        }

        let targetFPS = Double(currentFrameRate)
        let lowThreshold = targetFPS * adaptiveScaleLowThreshold
        let highThreshold = targetFPS * adaptiveScaleHighThreshold

        if captureFPS < lowThreshold {
            adaptiveScaleLowStreak += 1
            adaptiveScaleHighStreak = 0
        } else if captureFPS >= highThreshold {
            adaptiveScaleHighStreak += 1
            adaptiveScaleLowStreak = 0
        } else {
            adaptiveScaleLowStreak = max(0, adaptiveScaleLowStreak - 1)
            adaptiveScaleHighStreak = max(0, adaptiveScaleHighStreak - 1)
            return
        }

        if adaptiveScaleLowStreak >= adaptiveScaleDownSamples {
            let nextAdaptive = max(adaptiveScaleMin, adaptiveScale * adaptiveScaleDownStep)
            if nextAdaptive < adaptiveScale - 0.001 {
                adaptiveScale = nextAdaptive
                let effectiveScale = StreamContext.clampStreamScale(requestedStreamScale * adaptiveScale)
                if effectiveScale != streamScale {
                    lastAdaptiveScaleChangeTime = now
                    adaptiveScaleLowStreak = 0
                    adaptiveScaleHighStreak = 0
                    do {
                        try await applyStreamScale(effectiveScale, logLabel: "Adaptive scale down")
                        streamScaleUpdateHandler?(streamID)
                    } catch {
                        MirageLogger.error(.stream, "Adaptive scale down failed: \(error)")
                    }
                }
            }
            return
        }

        if adaptiveScaleHighStreak >= adaptiveScaleUpSamples {
            let nextAdaptive = min(1.0, adaptiveScale * adaptiveScaleUpStep)
            if nextAdaptive > adaptiveScale + 0.001 {
                adaptiveScale = nextAdaptive
                let effectiveScale = StreamContext.clampStreamScale(requestedStreamScale * adaptiveScale)
                if effectiveScale != streamScale {
                    lastAdaptiveScaleChangeTime = now
                    adaptiveScaleLowStreak = 0
                    adaptiveScaleHighStreak = 0
                    do {
                        try await applyStreamScale(effectiveScale, logLabel: "Adaptive scale up")
                        streamScaleUpdateHandler?(streamID)
                    } catch {
                        MirageLogger.error(.stream, "Adaptive scale up failed: \(error)")
                    }
                }
            }
        }
    }

    private func updateInFlightLimitIfNeeded(averageEncodeMs: Double, pendingCount: Int) async {
        guard maxInFlightFramesCap > 1 else { return }
        if useLowLatencyPipeline {
            let lowLatencyLimit = currentFrameRate >= 120 ? 2 : 1
            if maxInFlightFrames != lowLatencyLimit {
                maxInFlightFrames = lowLatencyLimit
                await encoder?.updateInFlightLimit(lowLatencyLimit)
                MirageLogger.metrics("In-flight depth forced to \(lowLatencyLimit) (low latency pipeline)")
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if lastInFlightAdjustmentTime > 0, now - lastInFlightAdjustmentTime < inFlightAdjustmentCooldown {
            return
        }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        var desired = maxInFlightFrames

        if averageEncodeMs > frameBudgetMs * 1.10 || pendingCount > 0 {
            desired = min(maxInFlightFrames + 1, maxInFlightFramesCap)
        } else if averageEncodeMs < frameBudgetMs * 0.80 && pendingCount == 0 {
            desired = max(maxInFlightFrames - 1, 1)
        }

        guard desired != maxInFlightFrames else { return }
        maxInFlightFrames = desired
        lastInFlightAdjustmentTime = now
        await encoder?.updateInFlightLimit(desired)
        let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics("In-flight depth set to \(desired) (encode \(avgText)ms, budget \(budgetText)ms)")
    }

    private func adjustQualityForQueue(queueBytes: Int) async {
        guard let encoder else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastQualityAdjustmentTime > qualityAdjustmentCooldown else { return }

        let frameBudgetMs = 1000.0 / Double(max(1, currentFrameRate))
        let isHighRefresh = currentFrameRate >= 120
        let averageEncodeMs = await encoder.getAverageEncodeTimeMs()
        let queuePressure = queueBytes >= queuePressureBytes
        let severePressure = queueBytes >= Int(Double(queuePressureBytes) * 1.5)
        let encodePressureMultiplier = isHighRefresh ? 1.55 : 1.35
        let heavyEncodePressureMultiplier = isHighRefresh ? 1.85 : 1.60
        let underBudgetMultiplier = isHighRefresh ? 0.65 : 0.75
        let encodePressure = averageEncodeMs > frameBudgetMs * encodePressureMultiplier
        let heavyEncodePressure = averageEncodeMs > frameBudgetMs * heavyEncodePressureMultiplier
        let underBudget = averageEncodeMs < frameBudgetMs * underBudgetMultiplier
        let queueClear = queueBytes < queuePressureBytes / 2

        if isHighRefresh {
            let scaleRoom = adaptiveScaleEnabled && adaptiveScale > adaptiveScaleMin + 0.01
            let demandDrop = queuePressure || severePressure || heavyEncodePressure
            if scaleRoom && !demandDrop {
                qualityOverBudgetCount = 0
                qualityUnderBudgetCount = 0
                return
            }
        }

        if queuePressure || encodePressure {
            qualityOverBudgetCount += 1
            qualityUnderBudgetCount = 0
        } else if queueClear && underBudget {
            qualityUnderBudgetCount += 1
            qualityOverBudgetCount = 0
        } else {
            qualityOverBudgetCount = max(0, qualityOverBudgetCount - 1)
            qualityUnderBudgetCount = max(0, qualityUnderBudgetCount - 1)
        }

        if qualityOverBudgetCount >= qualityDropThreshold, activeQuality > qualityFloor {
            let dropStep = (severePressure || heavyEncodePressure) ? qualityDropStepHighPressure : qualityDropStep
            activeQuality = max(qualityFloor, activeQuality - dropStep)
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            qualityOverBudgetCount = 0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let encodeText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            if queuePressure {
                let queueKB = Int(Double(queueBytes) / 1024.0)
                MirageLogger.stream("Encoder quality throttled to \(qualityText) (encode \(encodeText)ms, queue \(queueKB)KB)")
            } else {
                MirageLogger.stream("Encoder quality throttled to \(qualityText) (encode \(encodeText)ms)")
            }
            return
        }

        if qualityUnderBudgetCount >= qualityRaiseThreshold, activeQuality < qualityCeiling {
            activeQuality = min(qualityCeiling, activeQuality + qualityRaiseStep)
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            qualityUnderBudgetCount = 0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let encodeText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.stream("Encoder quality restored to \(qualityText) (encode \(encodeText)ms)")
        }
    }

    private func keyframeQuality(for queueBytes: Int) -> Float {
        var quality = min(activeQuality, encoderConfig.keyframeQuality)
        if queueBytes >= queuePressureBytes {
            let pressure = min(1.0, Double(queueBytes - queuePressureBytes) / Double(queuePressureBytes))
            let reduction = Float(0.25 * pressure)
            quality = max(keyframeQualityFloor, quality - reduction)
        }
        if smoothedDirtyPercentage >= keyframeMotionThreshold {
            quality = max(keyframeQualityFloor, quality - 0.10)
        }
        return quality
    }

    func start(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true

        let window = windowWrapper.window
        let application = applicationWrapper.application
        let display = displayWrapper.display

        // Store packet callback
        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        // Create HEVC encoder
        let encoder = HEVCEncoder(configuration: encoderConfig, inFlightLimit: maxInFlightFrames)
        self.encoder = encoder

        // Encode at scaled resolution for low latency
        let captureTarget = streamTargetDimensions(windowFrame: window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = window.frame
        updateQueueLimits()
        MirageLogger.stream("Stream init: scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)")
        try await encoder.createSession(width: Int(outputSize.width), height: Int(outputSize.height))
        activePixelFormat = await encoder.getActivePixelFormat()

        // Pre-heat encoder to eliminate warm-up latency on first real frames
        // Without this, first 5-10 frames take 70-80ms instead of 3-4ms
        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            // Capture all needed data immediately before dispatching
            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            // Reserve sequence numbers for all fragments
            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
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
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        // Create capture engine and start capturing
        // Uses app-level capture to include alerts, sheets, and dialogs
        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(configuration: captureConfig)
        self.captureEngine = captureEngine

        try await captureEngine.startCapture(
            window: window,
            application: application,
            display: display,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        MirageLogger.stream("Started stream \(streamID) for window \(windowID)")
    }

    /// Start stream for a login/lock display (display capture, not window capture)
    /// - Parameters:
    ///   - displayWrapper: The display to capture
    ///   - resolution: Optional pixel resolution override (used for HiDPI virtual displays)
    ///   - showsCursor: Whether to include the system cursor in captured frames.
    ///     - `true` for login screen (user needs to see cursor for interaction)
    ///     - `false` for desktop streaming (client renders its own cursor)
    ///   - onEncodedFrame: Callback for encoded video frames
    func startLoginDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        showsCursor: Bool = true,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true

        let display = displayWrapper.display

        // Store packet callback
        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        // Create HEVC encoder
        let encoder = HEVCEncoder(configuration: encoderConfig, inFlightLimit: maxInFlightFrames)
        self.encoder = encoder

        // Encode at scaled resolution from display native resolution or explicit pixel override
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        baseCaptureSize = captureResolution
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream("Display init: scale=\(streamScale), encoded=\(width)x\(height), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)")
        try await encoder.createSession(width: width, height: height)

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
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
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Login frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(configuration: captureConfig)
        self.captureEngine = captureEngine

        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: outputSize,
            showsCursor: showsCursor
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        MirageLogger.stream("Started login display stream \(streamID) at \(width)x\(height)")
    }

    /// Start stream for desktop streaming (full display capture with cursor hidden)
    /// Uses display-level capture like login display, but:
    /// - Cursor is hidden (client renders its own)
    /// - Different logging for clarity
    /// - Parameters:
    ///   - displayWrapper: The display to capture
    ///   - resolution: Optional pixel resolution for encoder sizing on HiDPI virtual displays
    ///   - onEncodedFrame: Callback for encoded video frames
    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true

        let display = displayWrapper.display

        // Store packet callback
        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        // Create HEVC encoder
        let encoder = HEVCEncoder(configuration: encoderConfig, inFlightLimit: maxInFlightFrames)
        self.encoder = encoder

        // Calculate capture and encoding resolutions
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        baseCaptureSize = captureResolution
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream("Desktop encoding at \(width)x\(height) (scale=\(streamScale), queue=\(maxQueuedBytes / 1024)KB)")
        try await encoder.createSession(width: width, height: height)

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber
            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
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
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Desktop frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(configuration: captureConfig)
        self.captureEngine = captureEngine

        // Desktop streaming hides cursor - client renders its own for smoother tracking.
        // Virtual display capture uses explicit dimensions; physical display capture uses .best.
        let captureSizeForSCK = CGVirtualDisplayBridge.isMirageDisplay(display.displayID) ? outputSize : nil
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureSizeForSCK,
            showsCursor: false
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        MirageLogger.stream("Started desktop display stream \(streamID) at \(width)x\(height)")
    }

    // MARK: - Virtual Display Start

    /// Start stream using shared virtual display architecture
    /// Acquires the shared virtual display at client's exact resolution, moves the window to it,
    /// and captures the window using WindowCaptureEngine (not display-level capture)
    /// - Parameter onVirtualDisplayReady: Called IMMEDIATELY after display is acquired, before other setup.
    ///   This is AWAITED to ensure bounds caching completes before any timers can fire.
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func startWithVirtualDisplay(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientDisplayResolution: CGSize,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader) -> Void,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void,
        onVirtualDisplayReady: @escaping @Sendable (CGRect) async -> Void = { _ in }
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true

        let application = applicationWrapper.application

        // Store callbacks (content bounds tracking simplified - not used with window capture)
        self.onEncodedPacket = onEncodedFrame
        self.onContentBoundsChanged = onContentBoundsChanged
        self.onNewWindowDetected = onNewWindowDetected
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        // Use exact client resolution - no upscaling needed since the shared display
        // is sized to match the client and windows can resize freely within it
        MirageLogger.stream("Starting stream \(streamID) with shared virtual display at \(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height))")

        // 1. Acquire shared virtual display at client's exact resolution
        let vdContext = try await SharedVirtualDisplayManager.shared.acquireDisplay(
            for: streamID,
            clientResolution: clientDisplayResolution,
            windowID: windowID,
            refreshRate: currentFrameRate,
            colorSpace: encoderConfig.colorSpace
        )
        self.virtualDisplayContext = vdContext

        // 2. Get authoritative display bounds from the ACTUAL created display
        // Use vdContext.resolution (what was actually created) not clientDisplayResolution (what was requested)
        // This ensures all subsequent code uses the same consistent resolution
        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(vdContext.displayID, knownResolution: vdContext.resolution)

        // CRITICAL: Await caller's bounds caching BEFORE any other async work
        // This prevents race condition where window centering timer runs before cache is populated
        await onVirtualDisplayReady(displayBounds)

        // 3. Move window to virtual display
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdContext.spaceID,
            displayID: vdContext.displayID,
            displayBounds: displayBounds
        )

        // 3. Get fresh SCShareableContent after moving window to virtual display
        // (the window's display association may have changed)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirageError.protocolError("Window \(windowID) not found after moving to virtual display")
        }
        guard let scApp = content.applications.first(where: { $0.processID == application.processID }) else {
            throw MirageError.protocolError("Application (PID \(application.processID)) not found")
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == vdContext.displayID }) else {
            throw MirageError.protocolError("Virtual display \(vdContext.displayID) not found in SCShareableContent")
        }

        // Wrap for Sendable crossing
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let appWrapper = SCApplicationWrapper(application: scApp)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        MirageLogger.stream("Found SCWindow \(scWindow.windowID) on virtual display \(scDisplay.displayID)")

        // 4. Create HEVC encoder
        let encoder = HEVCEncoder(configuration: encoderConfig, inFlightLimit: maxInFlightFrames)
        self.encoder = encoder

        // CRITICAL: Create encoder at ACTUAL capture dimensions, not virtual display dimensions
        // Capture uses window.frame × scaleFactor, so encoder must match exactly to avoid scaling blur
        // Virtual display resolution (2880×1800) is just for isolation - window may be smaller within it
        let captureScaleFactor: CGFloat = 2.0  // Virtual display is HiDPI 2x
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = scWindow.frame
        updateQueueLimits()
        MirageLogger.stream("Virtual display init: scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB")
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger.encoder("Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (capture \(captureTarget.width)x\(captureTarget.height), window \(Int(scWindow.frame.width))x\(Int(scWindow.frame.height)) × \(captureScaleFactor))")

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
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
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "VD Frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        // 5. Start WINDOW capture (not display capture)
        // Using WindowCaptureEngine captures the window content regardless of its position
        // The virtual display just provides isolation (prevents window overlap)
        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(configuration: captureConfig)
        self.captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: windowWrapper.window,
            application: appWrapper.application,
            display: displayWrapper.display,
            knownScaleFactor: 2.0,  // Virtual display is HiDPI 2x, NSScreen detection fails on headless Macs
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        MirageLogger.stream("Started stream \(streamID) with virtual display \(vdContext.displayID) for window \(windowID)")
    }

    /// Update virtual display resolution (when client moves to different display)
    func updateVirtualDisplayResolution(newResolution: CGSize) async throws {
        guard isRunning, useVirtualDisplay else { return }

        // Mark as resizing - any pending frames will be dropped
        isResizing = true
        defer { isResizing = false }

        // Reset contentRect to prevent stale dimensions in frame headers
        currentContentRect = .zero

        // Increment dimension token so client can reject old-dimension P-frames
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "virtual display resize")
        resetPipelineStateForReconfiguration(reason: "virtual display resize")

        MirageLogger.stream("Updating shared virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)")

        // Stop current capture
        await captureEngine?.stopCapture()

        // Update client resolution in shared display manager
        // This may trigger a display resize if the new resolution is larger
        try await SharedVirtualDisplayManager.shared.updateClientResolution(
            for: streamID,
            newResolution: newResolution,
            refreshRate: currentFrameRate
        )

        // Get the updated context
        guard let newContext = await SharedVirtualDisplayManager.shared.getDisplayContext() else {
            throw MirageError.protocolError("No shared virtual display available after resolution update")
        }
        self.virtualDisplayContext = newContext

        // Ensure window is still on the shared display's space
        // Use known resolution instead of CGDisplayBounds (which returns stale values)
        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(newContext.displayID, knownResolution: newContext.resolution)
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: newContext.spaceID,
            displayID: newContext.displayID,
            displayBounds: displayBounds
        )

        // Update encoder resolution to match ACTUAL capture dimensions
        // Capture is at window.frame × scaleFactor, so encoder must match exactly to avoid scaling blur
        // (We don't have the updated window frame yet, so we'll let the dimension update
        // happen when capture restarts with the new window reference below)

        // Get fresh SCShareableContent
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirageError.protocolError("Window \(windowID) not found after virtual display update")
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == newContext.displayID }) else {
            throw MirageError.protocolError("Virtual display \(newContext.displayID) not found")
        }

        // Get application PID from window info
        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]
        let pid = windowList?.first?[kCGWindowOwnerPID] as? pid_t ?? 0
        guard let scApp = content.applications.first(where: { $0.processID == pid }) else {
            throw MirageError.protocolError("Application (PID \(pid)) not found")
        }

        // Wrap for Sendable crossing
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let appWrapper = SCApplicationWrapper(application: scApp)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        // Update encoder to match new capture dimensions (window.frame × scaleFactor)
        let captureScaleFactor: CGFloat = 2.0  // Virtual display is HiDPI 2x
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = scWindow.frame
        updateQueueLimits()
        if let encoder {
            try await encoder.updateDimensions(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            MirageLogger.encoder("Encoder updated to \(Int(outputSize.width))x\(Int(outputSize.height)) for resolution change")
        }

        // Restart window capture
        let windowCaptureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: windowWrapper.window,
            application: appWrapper.application,
            display: displayWrapper.display,
            knownScaleFactor: 2.0,  // Virtual display is HiDPI 2x
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        // Force keyframe after virtual display update for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
    }

    /// Request a keyframe from the encoder
    /// CRITICAL: Uses flush() to clear the encoder pipeline, preventing old P-frames
    /// from being sent after the keyframe (which would cause decode errors)
    func requestKeyframe() async {
        if queueKeyframe(reason: "Keyframe request", checkInFlight: true, requiresReset: true, urgent: true) {
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }
    }

    /// Force an immediate keyframe by flushing the encoder pipeline.
    /// This is more aggressive than requestKeyframe() - it clears any pending frames
    /// so the next captured frame is immediately encoded as a keyframe.
    /// Use this when a client registers to ensure they receive a keyframe ASAP.
    func forceImmediateKeyframe() async {
        if shouldThrottleKeyframeRequest(requestLabel: "Immediate keyframe", checkInFlight: false) {
            return
        }

        markKeyframeRequestIssued()

        await packetSender?.resetQueue(reason: "immediate keyframe")
        await encoder?.flush()
        MirageLogger.stream("Forced immediate keyframe for stream \(streamID)")
    }

    /// Update stream frame rate for activity-based throttling
    /// - Parameter fps: Target frame rate (1 = throttled for inactive, normal = active)
    func updateFrameRate(_ fps: Int) async throws {
        guard isRunning, let captureEngine else { return }
        currentFrameRate = fps
        updateKeyframeCadence()
        updateQueueLimits()
        try await captureEngine.updateFrameRate(fps)
        await encoder?.updateFrameRate(fps)
        MirageLogger.stream("Stream \(streamID) frame rate updated to \(fps) fps")
    }

    /// Update stream dimensions when the host window is resized
    /// Encodes at the stream-scaled resolution for lower bandwidth
    func updateDimensions(windowFrame: CGRect) async throws {
        guard isRunning else { return }

        // Mark as resizing - frames will be dropped to prevent decode errors
        isResizing = true
        defer { isResizing = false }

        // Reset contentRect to prevent stale dimensions in frame headers
        currentContentRect = .zero

        // Increment dimension token so client can reject old-dimension P-frames
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "dimension update")
        resetPipelineStateForReconfiguration(reason: "dimension update")

        // Encode at scaled resolution based on stream scale
        let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        lastWindowFrame = windowFrame
        captureMode = .window

        MirageLogger.stream("Updating stream to scaled resolution: \(width)x\(height) (capture \(captureTarget.width)x\(captureTarget.height), scale: \(captureTarget.hostScaleFactor), from \(windowFrame.width)x\(windowFrame.height) pts) (frames paused)")

        // Update the capture engine configuration first
        if let captureEngine {
            try await captureEngine.updateDimensions(windowFrame: windowFrame, outputScale: streamScale)
        }

        // Update the encoder session (requires recreation)
        if let encoder {
            try await encoder.updateDimensions(width: width, height: height)
        }


        // Force keyframe after resize for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Dimension update complete (frames resumed)")
    }

    /// Update stream to capture at specific pixel dimensions (independent of window size)
    /// This allows the client to request exact resolution regardless of host window constraints
    func updateResolution(width: Int, height: Int) async throws {
        guard isRunning else { return }

        // Mark as resizing - frames will be dropped to prevent decode errors
        isResizing = true
        defer { isResizing = false }

        // Reset contentRect to prevent stale dimensions in frame headers
        // New frames will set the correct contentRect
        currentContentRect = .zero

        // Increment dimension token so client can reject old-dimension P-frames
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "resolution update")
        resetPipelineStateForReconfiguration(reason: "resolution update")

        baseCaptureSize = CGSize(width: width, height: height)
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        captureMode = .display

        MirageLogger.stream("Updating to client-requested resolution: \(width)x\(height) (scaled \(scaledWidth)x\(scaledHeight)) (frames paused)")

        // Update the capture engine to output at the scaled pixel dimensions
        if let captureEngine {
            try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
        }

        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        updateQueueLimits()

        // Update the encoder to match scaled output
        if let encoder {
            try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
            updateQueueLimits()
        }

        // Force keyframe after resize for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Resolution update to \(scaledWidth)x\(scaledHeight) complete (frames resumed)")
    }

    /// Update stream scale and reconfigure capture output size
    func updateStreamScale(_ newScale: CGFloat) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
        requestedStreamScale = clampedScale
        adaptiveScale = 1.0
        guard clampedScale != streamScale else { return }

        let previousScale = streamScale
        streamScale = clampedScale

        // Mark as resizing - frames will be dropped to prevent decode errors
        isResizing = true
        defer { isResizing = false }

        // Reset contentRect to prevent stale dimensions in frame headers
        currentContentRect = .zero

        // Increment dimension token so client can reject old-dimension P-frames
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "stream scale update")
        resetPipelineStateForReconfiguration(reason: "stream scale update")

        let derivedBaseSize: CGSize
        if baseCaptureSize != .zero {
            derivedBaseSize = baseCaptureSize
        } else if previousScale > 0 {
            let fallbackSize = currentCaptureSize == .zero ? currentEncodedSize : currentCaptureSize
            derivedBaseSize = CGSize(
                width: fallbackSize.width / previousScale,
                height: fallbackSize.height / previousScale
            )
        } else {
            derivedBaseSize = currentCaptureSize
        }
        baseCaptureSize = derivedBaseSize
        guard derivedBaseSize.width > 0, derivedBaseSize.height > 0 else { return }

        let outputSize = scaledOutputSize(for: derivedBaseSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize

        if let captureEngine {
            switch captureMode {
            case .display:
                try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
            case .window:
                if !lastWindowFrame.isEmpty {
                    try await captureEngine.updateDimensions(windowFrame: lastWindowFrame, outputScale: streamScale)
                }
            }
        }

        if let encoder {
            try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
            updateQueueLimits()
        }
        updateQueueLimits()

        await encoder?.forceKeyframe()
        MirageLogger.stream("Stream scale updated to \(streamScale), encoding at \(Int(outputSize.width))x\(Int(outputSize.height))")
    }

    private func applyStreamScale(_ newScale: CGFloat, logLabel: String) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
        guard clampedScale != streamScale else { return }

        let previousScale = streamScale
        streamScale = clampedScale

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "stream scale update")
        resetPipelineStateForReconfiguration(reason: "adaptive scale update")

        let derivedBaseSize: CGSize
        if baseCaptureSize != .zero {
            derivedBaseSize = baseCaptureSize
        } else if previousScale > 0 {
            let fallbackSize = currentCaptureSize == .zero ? currentEncodedSize : currentCaptureSize
            derivedBaseSize = CGSize(
                width: fallbackSize.width / previousScale,
                height: fallbackSize.height / previousScale
            )
        } else {
            derivedBaseSize = currentCaptureSize
        }
        baseCaptureSize = derivedBaseSize
        guard derivedBaseSize.width > 0, derivedBaseSize.height > 0 else { return }

        let outputSize = scaledOutputSize(for: derivedBaseSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize

        if let captureEngine {
            switch captureMode {
            case .display:
                try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
            case .window:
                if !lastWindowFrame.isEmpty {
                    try await captureEngine.updateDimensions(windowFrame: lastWindowFrame, outputScale: streamScale)
                }
            }
        }

        if let encoder {
            try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
            updateQueueLimits()
        }
        updateQueueLimits()

        await encoder?.forceKeyframe()
        MirageLogger.stream("\(logLabel): scale=\(streamScale), encoding \(scaledWidth)x\(scaledHeight)")
    }

    /// Update capture to a new display (after virtual display recreation)
    /// This switches the SCStream to capture the new display without restarting
    func updateCaptureDisplay(_ displayWrapper: SCDisplayWrapper, resolution: CGSize) async throws {
        guard isRunning else { return }

        // Mark as resizing - frames will be dropped to prevent decode errors
        isResizing = true
        defer { isResizing = false }

        // Reset contentRect to prevent stale dimensions in frame headers
        currentContentRect = .zero

        // Increment dimension token so client can reject old-dimension P-frames
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "display switch")
        resetPipelineStateForReconfiguration(reason: "display switch")

        baseCaptureSize = resolution
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)

        MirageLogger.stream("Switching to new display \(displayWrapper.display.displayID) at \(Int(resolution.width))x\(Int(resolution.height)) (scaled \(scaledWidth)x\(scaledHeight)) (frames paused)")

        // Update the capture engine to the new display
        if let captureEngine {
            try await captureEngine.updateCaptureDisplay(displayWrapper.display, resolution: outputSize)
        }

        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()

        // Update the encoder to match the new resolution
        if let encoder {
            try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
        }

        // Force keyframe after display switch for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Display switch complete (frames resumed)")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Stop window capture
        await captureEngine?.stopCapture()
        captureEngine = nil
        frameInbox.clear()

        if useVirtualDisplay {
            // Restore window to original position
            await WindowSpaceManager.shared.restoreWindowSilently(windowID)

            // Release shared virtual display (only destroyed when last client releases)
            await SharedVirtualDisplayManager.shared.releaseDisplay(for: streamID)

            virtualDisplayContext = nil
        }

        await packetSender?.stop()
        packetSender = nil

        await encoder?.stopEncoding()

        encoder = nil
        onEncodedPacket = nil
        onContentBoundsChanged = nil
        onNewWindowDetected = nil

        MirageLogger.stream("Stopped stream \(streamID)")
    }

    /// Check if this stream is using virtual display
    func isUsingVirtualDisplay() -> Bool {
        return useVirtualDisplay && virtualDisplayContext != nil
    }

    /// Get the virtual display ID for this stream
    func getVirtualDisplayID() -> CGDirectDisplayID? {
        return virtualDisplayContext?.displayID
    }

    /// Get the window ID for this stream
    /// nonisolated because windowID is immutable (let)
    nonisolated func getWindowID() -> WindowID {
        return windowID
    }

    /// Get the current dimension token for this stream.
    /// Used to send the initial token in stream started messages so clients can validate frames.
    func getDimensionToken() -> UInt16 {
        return dimensionToken
    }

    func getEncodedDimensions() -> (width: Int, height: Int) {
        let width = Int(currentEncodedSize.width)
        let height = Int(currentEncodedSize.height)
        return (width, height)
    }

    func getTargetFrameRate() -> Int {
        encoderConfig.targetFrameRate
    }

    func getCodec() -> MirageVideoCodec {
        encoderConfig.codec
    }

    func getStreamScale() -> CGFloat {
        streamScale
    }

    func getQualityPreset() -> MirageQualityPreset? {
        qualityPreset
    }

    func getAdaptiveScaleEnabled() -> Bool {
        adaptiveScaleEnabled
    }

    func setAdaptiveScaleEnabled(_ enabled: Bool) {
        adaptiveScaleEnabled = enabled
        adaptiveScale = 1.0
        adaptiveScaleLowStreak = 0
        adaptiveScaleHighStreak = 0
        lastAdaptiveScaleChangeTime = 0
    }

    func getEncoderSettings() -> (
        keyFrameInterval: Int,
        frameQuality: Float,
        keyframeQuality: Float,
        pixelFormat: MiragePixelFormat,
        colorSpace: MirageColorSpace,
        captureQueueDepth: Int?,
        minBitrate: Int?,
        maxBitrate: Int?
    ) {
        (
            encoderConfig.keyFrameInterval,
            encoderConfig.frameQuality,
            encoderConfig.keyframeQuality,
            activePixelFormat,
            encoderConfig.colorSpace,
            encoderConfig.captureQueueDepth,
            encoderConfig.minBitrate,
            encoderConfig.maxBitrate
        )
    }
}

#endif
