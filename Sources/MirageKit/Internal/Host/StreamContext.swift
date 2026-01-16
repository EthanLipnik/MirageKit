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
    private let scaler = PixelBufferScaler()
    private var currentEncodedSize: CGSize = .zero
    private var currentCaptureSize: CGSize = .zero
    /// Max payload size per UDP packet (excludes Mirage header).
    nonisolated let maxPayloadSize: Int

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
    /// Snapshot of current bitrate for encoder callbacks
    /// Updated on the actor whenever bitrate changes
    nonisolated(unsafe) private var bitrateSnapshot: Int = 0
    /// Latest dirty percentage from capture (used for motion-adaptive tuning)
    private var lastDirtyPercentage: Float = 0

    // Always-latest-frame tracking: ensures we encode the most recent frame, dropping stale ones
    private var pendingFrame: (wrapper: SampleBufferWrapper, frameInfo: CapturedFrameInfo)?
    private var isCurrentlyEncoding: Bool = false
    private var encodeStartTime: CFAbsoluteTime = 0
    private var droppedFrameCount: UInt64 = 0

    /// Maximum time to wait for an encode before considering encoder stuck (ms)
    /// During drag operations, VideoToolbox can block - we need to detect this and recover
    private let maxEncodeTimeMs: Double = 200

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

    // MARK: - Motion-Adaptive Quality

    /// Recent frame sizes for motion detection (in bytes)
    private var recentFrameSizes: [Int] = []

    /// Maximum recent frame sizes to track
    private let maxRecentFrames = 10

    /// Current quality level (0.1 to 1.0)
    private var currentQuality: Float

    /// Target quality when not in motion burst
    private let normalQuality: Float

    /// Minimum quality during extreme motion (prevents unusable quality)
    private let minQuality: Float = 0.3

    /// Bitrate bounds for adaptive motion control
    private let baseMaxBitrate: Int
    private let baseMinBitrate: Int
    private var maxBitrate: Int
    private var minBitrate: Int
    private var currentBitrate: Int

    /// Whether adaptive bitrate is enabled for this stream
    private let enableAdaptiveBitrate: Bool

    /// Cooldown between bitrate changes (seconds)
    private let bitrateChangeCooldown: CFAbsoluteTime = 0.5
    private var lastBitrateChangeTime: CFAbsoluteTime = 0

    /// Packet queue backpressure thresholds (seconds)
    private let maxQueueDelay: CFAbsoluteTime = 0.150
    private let queueDelayHighThreshold: CFAbsoluteTime = 0.120
    private let queueDelayLowThreshold: CFAbsoluteTime = 0.040
    private let queueDelayReduceMultiplier: Double = 0.85
    private let queueDelayIncreaseMultiplier: Double = 1.05
    private let backpressureLogInterval: CFAbsoluteTime = 1.0
    private var lastBackpressureLogTime: CFAbsoluteTime = 0
    private let queueFlushCooldown: CFAbsoluteTime = 0.25
    private var lastQueueFlushTime: CFAbsoluteTime = 0

    /// Network feedback-based bitrate cap (client quality feedback)
    private var networkBitrateCap: Int?
    private var lastFeedbackDropTime: CFAbsoluteTime = 0
    private var lastFeedbackAdjustmentTime: CFAbsoluteTime = 0
    private let feedbackDecreaseCooldown: CFAbsoluteTime = 0.25
    private let feedbackIncreaseCooldown: CFAbsoluteTime = 1.0
    private let feedbackRecoveryDelay: CFAbsoluteTime = 1.5
    private let feedbackDecreaseMultiplier: Double = 0.8
    private let feedbackSevereDecreaseMultiplier: Double = 0.6
    private let feedbackIncreaseMultiplier: Double = 1.05

    /// Motion thresholds relative to per-frame bitrate budget
    private let highMotionMultiplier: Double = 0.9
    private let extremeMotionMultiplier: Double = 1.5

    /// Frame rate used for bitrate budgeting
    private var currentFrameRate: Int

    /// How many frames of low motion before we start restoring quality
    private var lowMotionCounter = 0

    /// Frames needed at low motion before restoring quality
    private let qualityRestoreDelay = 30

    /// Callback for sending encoded packets
    private var onEncodedPacket: (@Sendable (Data, FrameHeader) -> Void)?

    /// Serializes packet fragmentation/sending to preserve frame order
    private var packetSender: StreamPacketSender?

    /// Callback for content bounds changes (menus, sheets appearing)
    private var onContentBoundsChanged: (@Sendable (CGRect) -> Void)?

    /// Callback for new independent window detection
    private var onNewWindowDetected: (@Sendable (MirageWindow) -> Void)?

    /// Additional flags to include on all frames for this stream
    private let additionalFrameFlags: FrameFlags

    init(
        streamID: StreamID,
        windowID: WindowID,
        encoderConfig: MirageEncoderConfiguration,
        streamScale: CGFloat = 1.0,
        maxPacketSize: Int = MirageDefaultMaxPacketSize,
        additionalFrameFlags: FrameFlags = []
    ) {
        self.streamID = streamID
        self.windowID = windowID
        self.encoderConfig = encoderConfig
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        self.streamScale = clampedScale
        self.additionalFrameFlags = additionalFrameFlags
        self.maxPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        self.normalQuality = encoderConfig.keyframeQuality
        self.currentQuality = encoderConfig.keyframeQuality
        self.baseMaxBitrate = encoderConfig.maxBitrate
        self.baseMinBitrate = encoderConfig.minBitrate
        let bounds = StreamContext.scaledBitrateBounds(
            maxBitrate: encoderConfig.maxBitrate,
            minBitrate: encoderConfig.minBitrate,
            scale: clampedScale
        )
        self.maxBitrate = bounds.max
        self.minBitrate = bounds.min
        self.currentBitrate = self.maxBitrate
        self.bitrateSnapshot = self.currentBitrate
        self.enableAdaptiveBitrate = encoderConfig.enableAdaptiveBitrate
        self.currentFrameRate = encoderConfig.targetFrameRate
    }

    private static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    private static func scaledBitrate(_ bitrate: Int, scale: CGFloat) -> Int {
        guard bitrate > 0 else { return 0 }
        let clampedScale = clampStreamScale(scale)
        let factor = Double(clampedScale * clampedScale)
        return Int((Double(bitrate) * factor).rounded())
    }

    private static func scaledBitrateBounds(
        maxBitrate: Int,
        minBitrate: Int,
        scale: CGFloat
    ) -> (max: Int, min: Int) {
        let scaledMax = max(1_000_000, scaledBitrate(maxBitrate, scale: scale))
        let scaledMin = max(500_000, scaledBitrate(minBitrate, scale: scale))
        return (max: scaledMax, min: min(scaledMax, scaledMin))
    }

    private static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }

    /// Update the current content rectangle (called per-frame from capture callback)
    private func setContentRect(_ rect: CGRect) {
        currentContentRect = rect
    }

    private func scaledOutputSize(for inputSize: CGSize) -> CGSize {
        let clampedScale = streamScale
        let width = StreamContext.alignedEvenPixel(inputSize.width * clampedScale)
        let height = StreamContext.alignedEvenPixel(inputSize.height * clampedScale)
        return CGSize(width: width, height: height)
    }

    private func scaleRect(_ rect: CGRect, scale: CGFloat, maxSize: CGSize) -> CGRect {
        guard scale != 1.0 else { return rect }
        let scaled = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )

        let maxWidth = maxSize.width
        let maxHeight = maxSize.height
        let clampedWidth = min(maxWidth, scaled.width)
        let clampedHeight = min(maxHeight, scaled.height)
        let clampedX = min(max(0, scaled.origin.x), maxWidth - clampedWidth)
        let clampedY = min(max(0, scaled.origin.y), maxHeight - clampedHeight)
        return CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    private func scaleFrameInfo(_ frameInfo: CapturedFrameInfo, scale: CGFloat, outputSize: CGSize) -> CapturedFrameInfo {
        guard scale != 1.0 else { return frameInfo }
        let scaledContentRect = scaleRect(frameInfo.contentRect, scale: scale, maxSize: outputSize)
        let scaledDirtyRects = frameInfo.dirtyRects.map { rect in
            scaleRect(rect, scale: scale, maxSize: outputSize)
        }
        return CapturedFrameInfo(
            contentRect: scaledContentRect,
            dirtyRects: scaledDirtyRects,
            dirtyPercentage: frameInfo.dirtyPercentage,
            forceKeyframe: frameInfo.forceKeyframe,
            isKeepalive: frameInfo.isKeepalive
        )
    }

    private func scaledSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        outputSize: CGSize
    ) -> CMSampleBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        if outputSize.width <= 0 || outputSize.height <= 0 {
            return nil
        }

        if Int(outputSize.width) == CVPixelBufferGetWidth(pixelBuffer),
           Int(outputSize.height) == CVPixelBufferGetHeight(pixelBuffer) {
            return sampleBuffer
        }

        guard let scaledBuffer = scaler.scale(pixelBuffer: pixelBuffer, outputSize: outputSize) else {
            return nil
        }

        let timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )

        return scaler.sampleBuffer(from: scaledBuffer, timingInfo: timingInfo)
    }

    /// Handle a captured frame with always-latest-frame logic
    /// Ensures we always encode the most recent frame, dropping stale ones
    func onCapturedFrame(_ wrapper: SampleBufferWrapper, _ frameInfo: CapturedFrameInfo) {
        // Track if we're replacing a pending frame (means we dropped one)
        if pendingFrame != nil {
            droppedFrameCount += 1
        }

        // Always store the latest frame (using wrapper for safe sending)
        pendingFrame = (wrapper, frameInfo)

        // Check if encoder has been stuck for too long (common during drag operations)
        // If so, mark for reset and process new frame
        let encoderStuck = isCurrentlyEncoding && encodeStartTime > 0 &&
            (CFAbsoluteTimeGetCurrent() - encodeStartTime) * 1000 > maxEncodeTimeMs

        if encoderStuck {
            let stuckTime = (CFAbsoluteTimeGetCurrent() - encodeStartTime) * 1000
            MirageLogger.stream("Encoder stuck for \(Int(stuckTime))ms, scheduling reset")
            isCurrentlyEncoding = false
            needsEncoderReset = true  // Will be handled in processLatestFrame
        }

        // If we're not currently encoding (or encoder was stuck), start encoding the latest
        if !isCurrentlyEncoding {
            Task { await processLatestFrame() }
        }
        // If we ARE encoding, the new frame will be picked up when encoding completes
    }

    /// Process the pending frame (encodes it using HEVC and checks for newer frames)
    private func processLatestFrame() async {
        // Skip encoding during resize operations - prevents decode errors and wasted CPU
        // Frames are dropped but connection stays alive; keyframe forced after resize
        if isResizing {
            pendingFrame = nil
            return
        }

        guard !isCurrentlyEncoding else {
            if let (_, frameInfo) = pendingFrame, frameInfo.isKeepalive {
                MirageLogger.stream("Keepalive frame waiting (encoder busy)")
            }
            return
        }
        guard let (wrapper, frameInfo) = pendingFrame else { return }

        pendingFrame = nil  // Clear - we're processing this one

        let inputSize: CGSize
        if let pixelBuffer = CMSampleBufferGetImageBuffer(wrapper.buffer) {
            inputSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        } else {
            inputSize = .zero
        }
        guard inputSize.width > 0, inputSize.height > 0 else {
            return
        }
        currentCaptureSize = inputSize
        let targetOutputSize = currentEncodedSize == .zero
            ? scaledOutputSize(for: inputSize)
            : currentEncodedSize
        if currentEncodedSize == .zero {
            currentEncodedSize = targetOutputSize
        }
        let scaleFactor = targetOutputSize.width / inputSize.width
        let scaledFrameInfo = scaleFrameInfo(frameInfo, scale: scaleFactor, outputSize: targetOutputSize)
        guard let scaledSampleBuffer = scaledSampleBuffer(wrapper.buffer, outputSize: targetOutputSize) else {
            return
        }
        let scaledWrapper = SampleBufferWrapper(buffer: scaledSampleBuffer)

        // Reset encoder if it was stuck on previous frame
        // This invalidates the VTCompressionSession and creates a new one
        // Uses cooldown to prevent cascading resets during SCK pauses
        var didResetEncoder = false
        if needsEncoderReset {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEncoderResetTime > encoderResetCooldown {
                MirageLogger.stream("Resetting stuck encoder before next frame")

                // Reduce quality before reset - the recovery keyframe will be smaller
                // and more likely to complete successfully during network congestion
                let previousQuality = currentQuality
                await encoder?.updateQuality(minQuality)

                do {
                    await packetSender?.bumpGeneration(reason: "encoder reset")
                    try await encoder?.reset()
                    didResetEncoder = true
                    lastEncoderResetTime = now
                    MirageLogger.stream("Recovery keyframe: using quality \(minQuality)")

                    // Schedule quality restoration after recovery keyframe is likely sent
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        if currentQuality == minQuality && previousQuality > minQuality {
                            currentQuality = previousQuality
                            await encoder?.updateQuality(currentQuality)
                            MirageLogger.stream("Recovery complete, restored quality to \(String(format: "%.1f", currentQuality))")
                        }
                    }
                } catch {
                    MirageLogger.error(.stream, "Encoder reset failed: \(error)")
                }
            } else {
                MirageLogger.stream("Encoder reset skipped (cooldown active, \(String(format: "%.1f", encoderResetCooldown - (now - lastEncoderResetTime)))s remaining)")
            }
            needsEncoderReset = false  // Clear flag even if we skipped due to cooldown
        }

        // Skip encoding if nothing changed (client keeps previous frame)
        // EXCEPT for keepalive frames - these must be sent to maintain stream during SCK pauses
        // This should rarely happen as CaptureStreamOutput already filters these
        if scaledFrameInfo.dirtyPercentage == 0 && scaledFrameInfo.dirtyRects.isEmpty && !scaledFrameInfo.isKeepalive {
            // Check for newer frames
            if pendingFrame != nil {
                Task { await processLatestFrame() }
            }
            return
        }

        // Encode using HEVC - P-frames automatically encode only what changed
        // Pass forceKeyframe hint (set when SCK resumes after a fallback period, or after encoder reset)
        var forceKeyframe = scaledFrameInfo.forceKeyframe || didResetEncoder

        if let packetSender {
            let queueDelay = await packetSender.estimatedQueueDelay(bitrate: currentBitrate)
            if queueDelay > maxQueueDelay {
                let now = CFAbsoluteTimeGetCurrent()
                let canFlush = now - lastQueueFlushTime >= queueFlushCooldown
                if canFlush {
                    lastQueueFlushTime = now
                    await packetSender.resetQueue(reason: "backpressure \(Int(queueDelay * 1000))ms")
                    await encoder?.flush()
                    forceKeyframe = true
                    MirageLogger.stream("Backpressure: flushed queue (\(Int(queueDelay * 1000))ms)")
                } else if !forceKeyframe && !scaledFrameInfo.isKeepalive {
                    droppedFrameCount += 1
                    if now - lastBackpressureLogTime > backpressureLogInterval {
                        lastBackpressureLogTime = now
                        MirageLogger.stream("Backpressure: dropping frame (queue \(Int(queueDelay * 1000))ms)")
                    }
                    if pendingFrame != nil {
                        Task { await processLatestFrame() }
                    }
                    return
                }
            }
        }

        if scaledFrameInfo.isKeepalive {
            MirageLogger.stream("Encoding keepalive frame (dirty=\(scaledFrameInfo.dirtyPercentage)%)")
        }

        isCurrentlyEncoding = true
        encodeStartTime = CFAbsoluteTimeGetCurrent()

        lastDirtyPercentage = scaledFrameInfo.dirtyPercentage
        // Store contentRect for use in frame header
        setContentRect(scaledFrameInfo.contentRect)

        do {
            try await encoder?.encodeFrame(scaledWrapper, forceKeyframe: forceKeyframe)
        } catch {
            MirageLogger.error(.stream, "Encode error: \(error)")
        }

        isCurrentlyEncoding = false
        encodeStartTime = 0

        // If a new frame arrived while encoding, process it immediately
        if pendingFrame != nil {
            Task { await processLatestFrame() }
        }
    }

    /// Get dropped frame statistics
    func getDroppedFrameCount() -> UInt64 {
        return droppedFrameCount
    }

    private func effectiveMaxBitrate() -> Int {
        if let cap = networkBitrateCap {
            return min(maxBitrate, cap)
        }
        return maxBitrate
    }

    private func applyBitrateCap(reason: String) async {
        let cappedMax = effectiveMaxBitrate()
        if currentBitrate > cappedMax {
            currentBitrate = cappedMax
            bitrateSnapshot = currentBitrate
            await encoder?.updateBitrate(currentBitrate)
            MirageLogger.stream("Feedback: bitrate capped at \(currentBitrate / 1_000_000)Mbps (\(reason))")
        }
    }

    /// Update quality based on recent frame sizes (motion-adaptive encoding)
    /// Called after each encoded frame to adjust quality for next frame
    private func updateQualityForFrameSize(_ frameSize: Int, isKeyframe: Bool) async {
        // Track recent frame sizes (exclude keyframes from average - they're naturally large)
        if !isKeyframe {
            recentFrameSizes.append(frameSize)
            if recentFrameSizes.count > maxRecentFrames {
                recentFrameSizes.removeFirst()
            }
        }

        // Calculate average recent P-frame size
        let avgFrameSize = recentFrameSizes.isEmpty ? 0 :
            recentFrameSizes.reduce(0, +) / recentFrameSizes.count
        let avgFrameSizeBytes = Double(avgFrameSize)

        let frameRate = max(1, currentFrameRate)
        let maxAdaptiveBitrate = effectiveMaxBitrate()
        let bitrateForBudget = min(currentBitrate, maxAdaptiveBitrate)
        let frameBudgetBytes = Double(bitrateForBudget) / 8.0 / Double(frameRate)
        let highMotionThreshold = frameBudgetBytes * highMotionMultiplier
        let extremeMotionThreshold = frameBudgetBytes * extremeMotionMultiplier

        // Determine target quality + bitrate based on motion level
        var targetQuality = currentQuality
        var targetBitrate = currentBitrate

        let sizeMotionRatio: Double
        if avgFrameSizeBytes <= highMotionThreshold {
            sizeMotionRatio = 0.0
        } else if avgFrameSizeBytes >= extremeMotionThreshold {
            sizeMotionRatio = 1.0
        } else {
            let ratioDenominator = max(1.0, extremeMotionThreshold - highMotionThreshold)
            sizeMotionRatio = max(0.0, min(1.0, (avgFrameSizeBytes - highMotionThreshold) / ratioDenominator))
        }

        let dirtyRatio = max(0.0, min(1.0, Double(lastDirtyPercentage) / 100.0))
        let dirtyMotionRatio: Double
        if dirtyRatio <= 0.2 {
            dirtyMotionRatio = 0.0
        } else {
            dirtyMotionRatio = min(1.0, (dirtyRatio - 0.2) / 0.6)
        }

        let motionRatio = max(sizeMotionRatio, dirtyMotionRatio)

        if motionRatio > 0 {
            targetQuality = normalQuality - (normalQuality - minQuality) * Float(motionRatio)
            let bitrateRange = max(0, maxAdaptiveBitrate - minBitrate)
            let scaledBitrate = Double(maxAdaptiveBitrate) - Double(bitrateRange) * motionRatio
            targetBitrate = max(minBitrate, Int(scaledBitrate.rounded()))
            lowMotionCounter = 0
        } else {
            // Low motion - consider restoring quality
            lowMotionCounter += 1
            if lowMotionCounter > qualityRestoreDelay {
                targetQuality = normalQuality
                targetBitrate = maxAdaptiveBitrate
            } else {
                // Keep current settings during restore delay
                targetQuality = currentQuality
                targetBitrate = currentBitrate
            }
        }

        if enableAdaptiveBitrate, let packetSender {
            let queueDelay = await packetSender.estimatedQueueDelay(bitrate: currentBitrate)
            if queueDelay > queueDelayHighThreshold {
                let reduced = Int(Double(currentBitrate) * queueDelayReduceMultiplier)
                targetBitrate = min(targetBitrate, reduced)
                lowMotionCounter = 0
            } else if queueDelay < queueDelayLowThreshold, lowMotionCounter > qualityRestoreDelay {
                let increased = Int(Double(currentBitrate) * queueDelayIncreaseMultiplier)
                targetBitrate = max(targetBitrate, increased)
            }
        }

        // Apply quality change if significant (avoid constant VT API calls)
        if abs(targetQuality - currentQuality) > 0.05 {
            currentQuality = targetQuality
            await encoder?.updateQuality(currentQuality)

            if targetQuality < normalQuality {
                MirageLogger.stream("Motion-adaptive: quality reduced to \(String(format: "%.1f", currentQuality)) (avg frame: \(avgFrameSize / 1024)KB)")
            } else {
                MirageLogger.stream("Motion-adaptive: quality restored to \(String(format: "%.1f", currentQuality))")
            }
        }

        if enableAdaptiveBitrate {
            let delta = abs(targetBitrate - currentBitrate)
            let now = CFAbsoluteTimeGetCurrent()
            let changeThreshold = max(1_000_000, maxAdaptiveBitrate / 20)
            if delta >= changeThreshold, now - lastBitrateChangeTime >= bitrateChangeCooldown {
                currentBitrate = max(minBitrate, min(maxAdaptiveBitrate, targetBitrate))
                bitrateSnapshot = currentBitrate
                lastBitrateChangeTime = now
                await encoder?.updateBitrate(currentBitrate)
                if currentBitrate < maxAdaptiveBitrate {
                    MirageLogger.stream("Motion-adaptive: bitrate reduced to \(currentBitrate / 1_000_000)Mbps")
                } else {
                    MirageLogger.stream("Motion-adaptive: bitrate restored to \(currentBitrate / 1_000_000)Mbps")
                }
            }
        }
    }

    func applyQualityFeedback(_ feedback: QualityFeedbackMessage) async {
        let now = CFAbsoluteTimeGetCurrent()
        let dropDetected = feedback.droppedFrames > 0 || feedback.bufferHealth < 0.9

        if dropDetected {
            lastFeedbackDropTime = now
            if now - lastFeedbackAdjustmentTime >= feedbackDecreaseCooldown {
                let severe = feedback.bufferHealth < 0.8 || feedback.droppedFrames > 5
                let factor = severe ? feedbackSevereDecreaseMultiplier : feedbackDecreaseMultiplier
                let reduced = Int(Double(currentBitrate) * factor)
                let capped = max(minBitrate, min(maxBitrate, reduced))
                if let existingCap = networkBitrateCap {
                    networkBitrateCap = min(existingCap, capped)
                } else {
                    networkBitrateCap = capped
                }
                await applyBitrateCap(reason: "quality feedback")

                if currentQuality > minQuality {
                    let newQuality = max(minQuality, currentQuality - (severe ? 0.2 : 0.1))
                    if abs(newQuality - currentQuality) > 0.01 {
                        currentQuality = newQuality
                        await encoder?.updateQuality(currentQuality)
                    }
                }

                lastFeedbackAdjustmentTime = now
            }
            return
        }

        guard let currentCap = networkBitrateCap else { return }
        guard now - lastFeedbackDropTime >= feedbackRecoveryDelay else { return }
        guard now - lastFeedbackAdjustmentTime >= feedbackIncreaseCooldown else { return }

        let increased = min(maxBitrate, Int(Double(currentCap) * feedbackIncreaseMultiplier))
        if increased != currentCap {
            networkBitrateCap = increased
            if currentBitrate < increased {
                let bumped = min(increased, Int(Double(currentBitrate) * feedbackIncreaseMultiplier))
                currentBitrate = bumped
                bitrateSnapshot = currentBitrate
                await encoder?.updateBitrate(currentBitrate)
                MirageLogger.stream("Feedback: bitrate increased to \(currentBitrate / 1_000_000)Mbps")
            } else {
                await applyBitrateCap(reason: "quality feedback recovery")
            }
            lastFeedbackAdjustmentTime = now
        }
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
        let encoder = HEVCEncoder(configuration: encoderConfig)
        self.encoder = encoder

        // Encode at scaled resolution for low latency
        let captureTarget = streamTargetDimensions(windowFrame: window.frame)
        currentCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize
        try await encoder.createSession(width: Int(outputSize.width), height: Int(outputSize.height))

        // Pre-heat encoder to eliminate warm-up latency on first real frames
        // Without this, first 5-10 frames take 70-80ms instead of 3-4ms
        try await encoder.preheat()

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding { [weak self] encodedData, isKeyframe, presentationTime in
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

            let flags = self.additionalFrameFlags
            let dimToken = self.dimensionToken
            let generation = packetSender.currentGenerationSnapshot()
            let targetBitrate = self.bitrateSnapshot
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
                targetBitrate: targetBitrate,
                logPrefix: "Frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }

        // Create capture engine and start capturing
        // Uses app-level capture to include alerts, sheets, and dialogs
        let captureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = captureEngine

        try await captureEngine.startCapture(
            window: window,
            application: application,
            display: display
        ) { [weak self] sampleBuffer, frameInfo in
            guard let self else { return }
            // Wrap the sample buffer for safe sending across actor boundary
            let wrapper = SampleBufferWrapper(buffer: sampleBuffer)
            // Use always-latest-frame logic: drops stale frames if encoding is slower than capture
            // frameInfo contains contentRect, dirtyRects, and dirtyPercentage for encoding decisions
            Task {
                await self.onCapturedFrame(wrapper, frameInfo)
            }
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
        let encoder = HEVCEncoder(configuration: encoderConfig)
        self.encoder = encoder

        // Encode at scaled resolution from display native resolution or explicit pixel override
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        currentCaptureSize = captureResolution
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        try await encoder.createSession(width: width, height: height)

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.additionalFrameFlags
            let dimToken = self.dimensionToken
            let generation = packetSender.currentGenerationSnapshot()
            let targetBitrate = self.bitrateSnapshot
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
                targetBitrate: targetBitrate,
                logPrefix: "Login frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }

        let captureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = captureEngine

        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureResolution,
            showsCursor: showsCursor
        ) { [weak self] sampleBuffer, frameInfo in
            guard let self else { return }
            let wrapper = SampleBufferWrapper(buffer: sampleBuffer)
            Task {
                await self.onCapturedFrame(wrapper, frameInfo)
            }
        }

        MirageLogger.stream("Started login display stream \(streamID) at \(width)x\(height)")
    }

    /// Start stream for desktop streaming (full display capture with cursor hidden)
    /// Uses display-level capture like login display, but:
    /// - Cursor is hidden (client renders its own)
    /// - Different logging for clarity
    /// - Parameters:
    ///   - displayWrapper: The display to capture
    ///   - resolution: Optional pixel resolution override (used for HiDPI virtual displays)
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
        let encoder = HEVCEncoder(configuration: encoderConfig)
        self.encoder = encoder

        // Calculate capture and encoding resolutions
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        currentCaptureSize = captureResolution
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream("Desktop encoding at \(width)x\(height)")
        try await encoder.createSession(width: width, height: height)

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber
            let frameSize = encodedData.count

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.additionalFrameFlags
            let dimToken = self.dimensionToken

            // Update quality based on frame size (motion-adaptive encoding)
            // Dispatched to actor to not block VT callback
            Task {
                await self.updateQualityForFrameSize(frameSize, isKeyframe: isKeyframe)
            }

            let generation = packetSender.currentGenerationSnapshot()
            let targetBitrate = self.bitrateSnapshot
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
                targetBitrate: targetBitrate,
                logPrefix: "Desktop frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }

        let captureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = captureEngine

        // Desktop streaming hides cursor - client renders its own for smoother tracking
        // Capture at full resolution even if encoding at 5K (VT handles scaling)
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureResolution,
            showsCursor: false
        ) { [weak self] sampleBuffer, frameInfo in
            guard let self else { return }
            let wrapper = SampleBufferWrapper(buffer: sampleBuffer)
            Task {
                await self.onCapturedFrame(wrapper, frameInfo)
            }
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
            refreshRate: encoderConfig.targetFrameRate
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
        let encoder = HEVCEncoder(configuration: encoderConfig)
        self.encoder = encoder

        // CRITICAL: Create encoder at ACTUAL capture dimensions, not virtual display dimensions
        // Capture uses window.frame × scaleFactor, so encoder must match exactly to avoid scaling blur
        // Virtual display resolution (2880×1800) is just for isolation - window may be smaller within it
        let captureScaleFactor: CGFloat = 2.0  // Virtual display is HiDPI 2x
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
        currentCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger.encoder("Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (capture \(captureTarget.width)x\(captureTarget.height), window \(Int(scWindow.frame.width))x\(Int(scWindow.frame.height)) × \(captureScaleFactor))")

        // Pre-heat encoder to eliminate warm-up latency
        try await encoder.preheat()

        // Set up frame handler
        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding { [weak self] encodedData, isKeyframe, presentationTime in
            // CRITICAL: Return immediately from VT callback to avoid blocking encoder during drags/menus
            // Packets are enqueued for serialized fragmentation/sending
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.additionalFrameFlags
            let dimToken = self.dimensionToken
            let generation = packetSender.currentGenerationSnapshot()
            let targetBitrate = self.bitrateSnapshot
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
                targetBitrate: targetBitrate,
                logPrefix: "VD Frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }

        // 5. Start WINDOW capture (not display capture)
        // Using WindowCaptureEngine captures the window content regardless of its position
        // The virtual display just provides isolation (prevents window overlap)
        let windowCaptureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: windowWrapper.window,
            application: appWrapper.application,
            display: displayWrapper.display,
            knownScaleFactor: 2.0  // Virtual display is HiDPI 2x, NSScreen detection fails on headless Macs
        ) { [weak self] sampleBuffer, frameInfo in
            guard let self else { return }
            let wrapper = SampleBufferWrapper(buffer: sampleBuffer)
            Task {
                await self.onCapturedFrame(wrapper, frameInfo)
            }
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

        MirageLogger.stream("Updating shared virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)")

        // Stop current capture
        await captureEngine?.stopCapture()

        // Update client resolution in shared display manager
        // This may trigger a display resize if the new resolution is larger
        try await SharedVirtualDisplayManager.shared.updateClientResolution(
            for: streamID,
            newResolution: newResolution,
            refreshRate: encoderConfig.targetFrameRate
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
        currentCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize
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
            knownScaleFactor: 2.0  // Virtual display is HiDPI 2x
        ) { [weak self] sampleBuffer, frameInfo in
            guard let self else { return }
            let wrapper = SampleBufferWrapper(buffer: sampleBuffer)
            Task {
                await self.onCapturedFrame(wrapper, frameInfo)
            }
        }

        // Force keyframe after virtual display update for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
    }

    /// Request a keyframe from the encoder
    /// Uses reduced quality for recovery keyframes since they happen during motion
    /// CRITICAL: Uses flush() to clear the encoder pipeline, preventing old P-frames
    /// from being sent after the keyframe (which would cause decode errors)
    func requestKeyframe() async {
        // Temporarily reduce quality for recovery keyframe
        // Recovery happens during motion/errors when quality matters less
        let previousQuality = currentQuality
        let previousBitrate = currentBitrate
        if currentQuality > minQuality {
            currentQuality = minQuality
            await encoder?.updateQuality(currentQuality)
            MirageLogger.stream("Recovery keyframe: temporarily reduced quality to \(minQuality)")
        }
        let reducedBitrate = max(minBitrate, Int(Double(currentBitrate) * 0.6))
        if reducedBitrate < currentBitrate {
            currentBitrate = reducedBitrate
            bitrateSnapshot = currentBitrate
            await encoder?.updateBitrate(currentBitrate)
            MirageLogger.stream("Recovery keyframe: temporarily reduced bitrate to \(currentBitrate / 1_000_000)Mbps")
        }

        // CRITICAL: flush() instead of forceKeyframe() - clears the encoder pipeline
        // This prevents old P-frames (encoded before the reset) from being sent after
        // the keyframe, which would cause decode errors because they reference frames
        // from the old encoder session that don't exist in the new session.
        await packetSender?.bumpGeneration(reason: "keyframe request")
        await encoder?.flush()

        // Schedule quality restoration after the keyframe is likely sent
        // This gives time for the keyframe to be encoded at lower quality
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            if currentQuality == minQuality && previousQuality > minQuality {
                // Only restore if motion-adaptive hasn't already changed it
                currentQuality = previousQuality
                await encoder?.updateQuality(currentQuality)
                MirageLogger.stream("Recovery keyframe sent, restored quality to \(String(format: "%.1f", currentQuality))")
            }
            if currentBitrate == reducedBitrate {
                currentBitrate = min(previousBitrate, effectiveMaxBitrate())
                bitrateSnapshot = currentBitrate
                await encoder?.updateBitrate(currentBitrate)
                MirageLogger.stream("Recovery keyframe sent, restored bitrate to \(currentBitrate / 1_000_000)Mbps")
            }
        }
    }

    /// Force an immediate keyframe by flushing the encoder pipeline.
    /// This is more aggressive than requestKeyframe() - it clears any pending frames
    /// so the next captured frame is immediately encoded as a keyframe.
    /// Use this when a client registers to ensure they receive a keyframe ASAP.
    func forceImmediateKeyframe() async {
        // Temporarily reduce quality for recovery keyframe
        let previousQuality = currentQuality
        let previousBitrate = currentBitrate
        if currentQuality > minQuality {
            currentQuality = minQuality
            await encoder?.updateQuality(currentQuality)
            MirageLogger.stream("Immediate keyframe: temporarily reduced quality to \(minQuality)")
        }
        let reducedBitrate = max(minBitrate, Int(Double(currentBitrate) * 0.6))
        if reducedBitrate < currentBitrate {
            currentBitrate = reducedBitrate
            bitrateSnapshot = currentBitrate
            await encoder?.updateBitrate(currentBitrate)
            MirageLogger.stream("Immediate keyframe: temporarily reduced bitrate to \(currentBitrate / 1_000_000)Mbps")
        }

        await packetSender?.bumpGeneration(reason: "immediate keyframe")
        await encoder?.flush()
        MirageLogger.stream("Forced immediate keyframe for stream \(streamID)")

        // Schedule quality restoration
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            if currentQuality == minQuality && previousQuality > minQuality {
                currentQuality = previousQuality
                await encoder?.updateQuality(currentQuality)
                MirageLogger.stream("Immediate keyframe sent, restored quality to \(String(format: "%.1f", currentQuality))")
            }
            if currentBitrate == reducedBitrate {
                currentBitrate = min(previousBitrate, effectiveMaxBitrate())
                bitrateSnapshot = currentBitrate
                await encoder?.updateBitrate(currentBitrate)
                MirageLogger.stream("Immediate keyframe sent, restored bitrate to \(currentBitrate / 1_000_000)Mbps")
            }
        }
    }

    /// Update stream frame rate for activity-based throttling
    /// - Parameter fps: Target frame rate (1 = throttled for inactive, normal = active)
    func updateFrameRate(_ fps: Int) async throws {
        guard isRunning, let captureEngine else { return }
        currentFrameRate = fps
        try await captureEngine.updateFrameRate(fps)
        MirageLogger.stream("Stream \(streamID) frame rate updated to \(fps) fps")
    }

    /// Update stream dimensions when the host window is resized
    /// Always encodes at native resolution for maximum quality
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

        // Encode at scaled resolution based on stream scale
        let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
        currentCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        currentEncodedSize = outputSize

        MirageLogger.stream("Updating stream to scaled resolution: \(width)x\(height) (capture \(captureTarget.width)x\(captureTarget.height), scale: \(captureTarget.hostScaleFactor), from \(windowFrame.width)x\(windowFrame.height) pts) (frames paused)")

        // Update the capture engine configuration first
        if let captureEngine {
            try await captureEngine.updateDimensions(windowFrame: windowFrame)
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

        MirageLogger.stream("Updating to client-requested resolution: \(width)x\(height) (frames paused)")

        // Update the capture engine to output at client's exact pixel dimensions
        if let captureEngine {
            try await captureEngine.updateResolution(width: width, height: height)
        }

        currentCaptureSize = CGSize(width: width, height: height)
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize

        // Update the encoder to match scaled output
        if let encoder {
            try await encoder.updateDimensions(width: Int(outputSize.width), height: Int(outputSize.height))
        }

        // Force keyframe after resize for clean restart
        await encoder?.forceKeyframe()

        MirageLogger.stream("Resolution update to \(width)x\(height) complete (frames resumed)")
    }

    /// Update stream scale without resizing the capture source
    func updateStreamScale(_ newScale: CGFloat) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
        guard clampedScale != streamScale else { return }

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

        let captureSize = currentCaptureSize == .zero ? currentEncodedSize : currentCaptureSize
        guard captureSize.width > 0, captureSize.height > 0 else { return }

        let outputSize = scaledOutputSize(for: captureSize)
        currentEncodedSize = outputSize

        if let encoder {
            try await encoder.updateDimensions(width: Int(outputSize.width), height: Int(outputSize.height))
        }

        let previousMaxBitrate = maxBitrate
        let previousMinBitrate = minBitrate
        let bounds = StreamContext.scaledBitrateBounds(
            maxBitrate: baseMaxBitrate,
            minBitrate: baseMinBitrate,
            scale: streamScale
        )
        maxBitrate = bounds.max
        minBitrate = bounds.min

        if previousMaxBitrate != maxBitrate || previousMinBitrate != minBitrate {
            let scaledCurrent: Int
            if previousMaxBitrate > 0 {
                scaledCurrent = Int((Double(currentBitrate) * Double(maxBitrate) / Double(previousMaxBitrate)).rounded())
            } else {
                scaledCurrent = maxBitrate
            }
            let clampedBitrate = max(minBitrate, min(maxBitrate, scaledCurrent))
            if clampedBitrate != currentBitrate {
                currentBitrate = clampedBitrate
                bitrateSnapshot = currentBitrate
                await encoder?.updateBitrate(currentBitrate)
            }
            MirageLogger.stream("Stream scale bitrate bounds updated: \(maxBitrate / 1_000_000)Mbps max, \(minBitrate / 1_000_000)Mbps min")
        }

        await encoder?.forceKeyframe()
        MirageLogger.stream("Stream scale updated to \(streamScale), encoding at \(Int(outputSize.width))x\(Int(outputSize.height))")
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

        MirageLogger.stream("Switching to new display \(displayWrapper.display.displayID) at \(Int(resolution.width))x\(Int(resolution.height)) (frames paused)")

        // Update the capture engine to the new display
        if let captureEngine {
            try await captureEngine.updateCaptureDisplay(displayWrapper.display, resolution: resolution)
        }

        currentCaptureSize = resolution
        let outputSize = scaledOutputSize(for: currentCaptureSize)
        currentEncodedSize = outputSize

        // Update the encoder to match the new resolution
        if let encoder {
            try await encoder.updateDimensions(width: Int(outputSize.width), height: Int(outputSize.height))
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
        currentFrameRate
    }

    func getCodec() -> MirageVideoCodec {
        encoderConfig.codec
    }

    func getStreamScale() -> CGFloat {
        streamScale
    }

    func getEncoderSettings() -> (maxBitrate: Int, keyFrameInterval: Int, keyframeQuality: Float) {
        (baseMaxBitrate, encoderConfig.keyFrameInterval, encoderConfig.keyframeQuality)
    }
}

#endif
