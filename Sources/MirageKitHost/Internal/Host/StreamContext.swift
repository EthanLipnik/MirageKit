//
//  StreamContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

/// Manages the capture → encode → send pipeline for a single stream
/// Uses virtual displays for window isolation, with window-level capture
actor StreamContext {
    let streamID: StreamID
    let windowID: WindowID
    var encoderConfig: MirageEncoderConfiguration
    var streamScale: CGFloat
    var baseCaptureSize: CGSize = .zero
    var currentEncodedSize: CGSize = .zero
    var currentCaptureSize: CGSize = .zero
    var activePixelFormat: MiragePixelFormat
    var lastWindowFrame: CGRect = .zero
    var applicationProcessID: pid_t = 0
    enum CaptureMode {
        case window
        case display
    }

    var captureMode: CaptureMode = .window
    /// Max payload size per UDP packet (excludes Mirage header).
    nonisolated let maxPayloadSize: Int
    let mediaSecurityContext: MirageMediaSecurityContext?
    nonisolated(unsafe) var shouldEncodeFrames: Bool = true

    /// Window capture engine (used both for legacy and virtual display modes)
    var captureEngine: WindowCaptureEngine?

    // Virtual display components (provides window isolation)
    // Uses SharedVirtualDisplayManager for single shared display across all streams
    var virtualDisplayContext: SharedVirtualDisplayManager.DisplaySnapshot?
    var useVirtualDisplay: Bool = true
    var sharedDisplayGeneration: UInt64 = 0

    var encoder: HEVCEncoder?
    var isRunning = false
    var frameNumber: UInt32 = 0
    var sequenceNumber: UInt32 = 0

    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Incremented each time encoder dimensions change. Sent in every frame header
    /// so client can discard frames with mismatched tokens.
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (token is incremented on actor, read in callback)
    nonisolated(unsafe) var dimensionToken: UInt16 = 0

    /// Current content rectangle within the capture buffer
    /// Updated per-frame from ScreenCaptureKit to handle black padding
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (always set before read, in frame order)
    nonisolated(unsafe) var currentContentRect: CGRect = .zero

    // Bounded frame inbox to decouple capture from encode with low latency.
    nonisolated let frameInbox: StreamFrameInbox
    var inFlightCount: Int = 0
    let minInFlightFrames: Int
    var maxInFlightFrames: Int
    let maxInFlightFramesCap: Int
    let frameBufferDepth: Int
    var lastEncodeActivityTime: CFAbsoluteTime = 0
    var droppedFrameCount: UInt64 = 0
    var idleSkippedCount: UInt64 = 0
    var idleEncodedCount: UInt64 = 0
    var encodedFrameCount: UInt64 = 0
    var syntheticFrameCount: UInt64 = 0
    var syntheticIntervalCount: UInt64 = 0
    var lastCapturedFrame: CapturedFrame?
    var lastCapturedDuration: CMTime = .invalid
    var lastEncodedPresentationTime: CMTime = .invalid
    var lastSyntheticFrameTime: CFAbsoluteTime = 0
    var lastSyntheticLogTime: CFAbsoluteTime = 0
    var lastStreamStatsLogTime: CFAbsoluteTime = 0
    var metricsUpdateHandler: (@Sendable (StreamMetricsMessage) -> Void)?
    var activeQuality: Float
    var qualityFloor: Float
    var qualityCeiling: Float
    var steadyQualityCeiling: Float
    var keyframeQualityFloor: Float
    let compressionQualityCeiling: Float = 0.80
    let qualityFloorFactor: Float = 0.6
    let keyframeFloorFactor: Float = 0.6
    var pendingKeyframeReason: String?
    var pendingKeyframeDeadline: CFAbsoluteTime = 0
    var isKeyframeEncoding: Bool = false
    var pendingKeyframeRequiresFlush: Bool = false
    var pendingKeyframeUrgent: Bool = false
    var pendingKeyframeRequiresReset: Bool = false
    var lastQualityAdjustmentTime: CFAbsoluteTime = 0
    let qualityAdjustmentCooldown: CFAbsoluteTime = 0.35
    var qualityOverBudgetCount: Int = 0
    var qualityUnderBudgetCount: Int = 0
    let qualityDropThreshold: Int = 3
    let qualityRaiseThreshold: Int = 4
    let qualityDropStep: Float = 0.02
    let qualityDropStepHighPressure: Float = 0.05
    let qualityRaiseStep: Float = 0.03
    var lastInFlightAdjustmentTime: CFAbsoluteTime = 0
    let inFlightAdjustmentCooldown: CFAbsoluteTime = 1.0
    let typingBurstWindow: CFAbsoluteTime = 0.35
    let typingBurstInFlightLimit = 1
    let typingBurstQualityCap: Float = 0.62
    var typingBurstDeadline: CFAbsoluteTime = 0
    var typingBurstActive = false
    var typingBurstExpiryTask: Task<Void, Never>?

    // Pipeline throughput metrics (interval counters)
    var captureIngressIntervalCount: UInt64 = 0
    var captureIntervalCount: UInt64 = 0
    var captureDroppedIntervalCount: UInt64 = 0
    var encodeAttemptIntervalCount: UInt64 = 0
    var encodeAcceptedIntervalCount: UInt64 = 0
    var encodeRejectedIntervalCount: UInt64 = 0
    var encodeErrorIntervalCount: UInt64 = 0
    var backpressureDropIntervalCount: UInt64 = 0
    var encodeSkipQueueFullIntervalCount: UInt64 = 0
    var encodeSkipDimensionIntervalCount: UInt64 = 0
    var encodeSkipInactiveIntervalCount: UInt64 = 0
    var encodeSkipNoSessionIntervalCount: UInt64 = 0
    var lastPipelineStatsLogTime: CFAbsoluteTime = 0
    let pipelineStatsInterval: CFAbsoluteTime = 2.0
    var lastCapturedFrameTime: CFAbsoluteTime = 0
    var startupBaseTime: CFAbsoluteTime = 0
    var startupLabel: String = ""
    var startupFirstCaptureLogged = false
    var startupFirstEncodeLogged = false
    var startupRegistrationLogged = false

    /// Maximum time to wait for encode progress before considering encoder stuck (ms)
    /// During drag operations, VideoToolbox can block - we need to detect this and recover
    let maxEncodeTimeMs: Double

    /// Flag indicating encoder needs to be reset on next encode attempt
    /// Set when encoder is detected as stuck, cleared after reset
    var needsEncoderReset: Bool = false

    /// Timestamp of last encoder reset (for cooldown)
    var lastEncoderResetTime: CFAbsoluteTime = 0

    /// Minimum time between encoder resets (seconds)
    /// Prevents cascading resets during SCK pauses which cause multiple keyframes
    let encoderResetCooldown: CFAbsoluteTime = 1.0

    /// Flag to skip encoding during resize operations
    /// When true, incoming frames are dropped to prevent decode errors and wasted CPU
    /// Set before dimension updates begin, cleared after completion
    var isResizing: Bool = false

    // MARK: - Backpressure

    /// Packet queue backpressure thresholds (bytes)
    let minQueuedBytes: Int = 400_000
    let maxQueuedBytesCap: Int = 8_000_000
    var maxQueuedBytes: Int = 2_000_000
    var queuePressureBytes: Int = 1_200_000
    let backpressureLogInterval: CFAbsoluteTime = 1.0
    var lastBackpressureLogTime: CFAbsoluteTime = 0
    var backpressureActive: Bool = false
    nonisolated(unsafe) var backpressureActiveSnapshot: Bool = false
    var backpressureActivatedAt: CFAbsoluteTime = 0
    var lastBackpressureRecoveryTime: CFAbsoluteTime = 0
    let backpressureRecoveryThreshold: CFAbsoluteTime = 0.75
    let backpressureRecoveryCooldown: CFAbsoluteTime = 2.0

    /// Keyframe request throttling
    let keyframeRequestCooldown: CFAbsoluteTime = 0.25
    let keyframeInFlightCap: CFAbsoluteTime = 1.0
    let keyframeSettleTimeout: CFAbsoluteTime = 2.0
    let keyframeQueueSettleFactor: Double = 0.4
    var lastKeyframeRequestTime: CFAbsoluteTime = 0
    var keyframeSendDeadline: CFAbsoluteTime = 0

    /// Scheduled keyframe cadence derived from keyFrameInterval/currentFrameRate.
    var keyframeIntervalSeconds: CFAbsoluteTime = 0
    var keyframeMaxIntervalSeconds: CFAbsoluteTime = 0
    var lastKeyframeTime: CFAbsoluteTime = 0
    let recoveryOnlyKeyframes = true

    /// Two-tier recovery tracking.
    let softRecoveryWindow: CFAbsoluteTime = 4.0
    let hardRecoveryThreshold: Int = 2
    var recoveryWindowStart: CFAbsoluteTime = 0
    var recoveryRequestCount: Int = 0
    var softRecoveryCount: UInt64 = 0
    var hardRecoveryCount: UInt64 = 0

    /// Loss-mode deadline for adaptive redundancy and pacing.
    /// When active, keyframes and P-frames include FEC parity fragments.
    nonisolated(unsafe) var lossModeDeadline: CFAbsoluteTime = 0
    nonisolated(unsafe) var lossModePFrameFECDeadline: CFAbsoluteTime = 0
    let lossModeHold: CFAbsoluteTime = 4.0
    let pFrameFECLossModeHold: CFAbsoluteTime = 8.0

    /// Frame rate for cadence and queue limits
    var currentFrameRate: Int
    /// Effective capture cadence reported by ScreenCaptureKit.
    var captureFrameRate: Int
    /// Optional override for capture frame rate.
    var captureFrameRateOverride: Int?

    /// Maximum encoded resolution (5K cap)
    static let maxEncodedWidth: CGFloat = 5120
    static let maxEncodedHeight: CGFloat = 2880

    /// Smoothed dirty percentage (0-1) used to avoid keyframes during high motion.
    var smoothedDirtyPercentage: Double = 0
    let motionSmoothingFactor: Double = 0.2
    let keyframeMotionThreshold: Double = 0.25

    /// Callback for sending encoded packets
    var onEncodedPacket: (@Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void)?
    /// Callback for captured audio buffers from ScreenCaptureKit.
    var onCapturedAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?

    /// Serializes packet fragmentation/sending to preserve frame order
    var packetSender: StreamPacketSender?

    /// Callback for content bounds changes (menus, sheets appearing)
    var onContentBoundsChanged: (@Sendable (CGRect) -> Void)?

    /// Callback for new independent window detection
    var onNewWindowDetected: (@Sendable (MirageWindow) -> Void)?

    /// Base flags to include on all frames for this stream
    let baseFrameFlags: FrameFlags

    /// Dynamic flags applied to the next encoded frame.
    nonisolated(unsafe) var dynamicFrameFlags: FrameFlags = []

    /// Stream epoch for discontinuity boundaries.
    /// Incremented when the host resets capture or send state.
    nonisolated(unsafe) var epoch: UInt16 = 0

    /// Latency preference for buffering behavior.
    let latencyMode: MirageStreamLatencyMode
    /// Aggressive typing burst is active only in auto mode.
    let supportsTypingBurst: Bool
    /// When true, force low-latency buffering regardless of overrides.
    let useLowLatencyPipeline: Bool
    /// Client-requested stream scale.
    var requestedStreamScale: CGFloat
    /// When false, runtime quality adjustments remain fixed at derived baseline quality.
    let runtimeQualityAdjustmentEnabled: Bool
    /// When true, bypasses the host-side encoded-dimension cap.
    let disableResolutionCap: Bool

    init(
        streamID: StreamID,
        windowID: WindowID,
        encoderConfig: MirageEncoderConfiguration,
        streamScale: CGFloat = 1.0,
        maxPacketSize: Int = mirageDefaultMaxPacketSize,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        additionalFrameFlags: FrameFlags = [],
        runtimeQualityAdjustmentEnabled: Bool = true,
        disableResolutionCap: Bool = false,
        latencyMode: MirageStreamLatencyMode = .auto
    ) {
        self.streamID = streamID
        self.windowID = windowID
        self.encoderConfig = encoderConfig
        self.latencyMode = latencyMode
        supportsTypingBurst = latencyMode == .auto
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        self.streamScale = clampedScale
        requestedStreamScale = clampedScale
        baseFrameFlags = additionalFrameFlags
        maxPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        self.mediaSecurityContext = mediaSecurityContext
        currentFrameRate = encoderConfig.targetFrameRate
        captureFrameRateOverride = nil
        captureFrameRate = encoderConfig.targetFrameRate
        self.runtimeQualityAdjustmentEnabled = runtimeQualityAdjustmentEnabled
        self.disableResolutionCap = disableResolutionCap
        activePixelFormat = encoderConfig.pixelFormat
        let prefersSmoothness = latencyMode == .smoothest || latencyMode == .auto
        let latencySensitive = latencyMode == .lowestLatency
        useLowLatencyPipeline = latencySensitive || (encoderConfig.targetFrameRate >= 120 && !prefersSmoothness)
        let bufferDepth = Self.frameBufferDepth(
            useLowLatencyPipeline: useLowLatencyPipeline,
            frameRate: encoderConfig.targetFrameRate,
            latencyMode: latencyMode
        )
        let minInFlight = Self.minInFlightFrames(
            useLowLatencyPipeline: useLowLatencyPipeline,
            frameRate: encoderConfig.targetFrameRate,
            latencyMode: latencyMode
        )
        let inFlightCap = min(
            bufferDepth,
            Self.inFlightCap(
                useLowLatencyPipeline: useLowLatencyPipeline,
                frameRate: encoderConfig.targetFrameRate,
                latencyMode: latencyMode
            )
        )
        maxInFlightFramesCap = max(1, inFlightCap)
        minInFlightFrames = minInFlight
        maxInFlightFrames = min(minInFlight, maxInFlightFramesCap)
        frameBufferDepth = bufferDepth
        frameInbox = StreamFrameInbox(capacity: bufferDepth)
        maxEncodeTimeMs = encoderConfig.targetFrameRate >= 120 ? 900 : 600
        shouldEncodeFrames = false
        let cappedFrameQuality = min(encoderConfig.frameQuality, compressionQualityCeiling)
        steadyQualityCeiling = cappedFrameQuality
        qualityCeiling = cappedFrameQuality
        qualityFloor = max(0.1, cappedFrameQuality * qualityFloorFactor)
        activeQuality = cappedFrameQuality
        let cappedKeyframeQuality = min(encoderConfig.keyframeQuality, cappedFrameQuality)
        keyframeQualityFloor = max(0.1, cappedKeyframeQuality * keyframeFloorFactor)
        let cadence = Self.keyframeCadence(
            intervalFrames: encoderConfig.keyFrameInterval,
            frameRate: encoderConfig.targetFrameRate
        )
        keyframeIntervalSeconds = cadence.interval
        keyframeMaxIntervalSeconds = cadence.maxInterval
    }

    func setStartupBaseTime(_ baseTime: CFAbsoluteTime, label: String) {
        startupBaseTime = baseTime
        startupLabel = label
        startupFirstCaptureLogged = false
        startupFirstEncodeLogged = false
        startupRegistrationLogged = false
    }

    func logStartupEvent(_ event: String) {
        guard startupBaseTime > 0 else { return }
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - startupBaseTime) * 1000)
        let label = startupLabel.isEmpty ? "stream \(streamID)" : startupLabel
        MirageLogger.stream("\(label) start: \(event) (+\(deltaMs)ms)")
    }

    static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    func resolvedCaptureFrameRate(for targetFrameRate: Int) -> Int {
        if let override = captureFrameRateOverride { return override }
        return targetFrameRate
    }

    func refreshCaptureCadence() async {
        guard let captureEngine else { return }
        let effectiveRate = await captureEngine.effectiveCaptureRate()
        captureFrameRate = effectiveRate
    }

    static func frameBufferDepth(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return frameRate >= 120 ? 2 : 1 }
        switch latencyMode {
        case .smoothest:
            if frameRate >= 120 { return 6 }
            if frameRate >= 60 { return 5 }
            return 3
        case .auto:
            if frameRate >= 120 { return 6 }
            if frameRate >= 60 { return 5 }
            return 3
        case .lowestLatency:
            if frameRate >= 120 { return 2 }
            if frameRate >= 60 { return 2 }
            return 1
        }
    }

    static func inFlightCap(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return frameRate >= 120 ? 2 : 1 }
        switch latencyMode {
        case .smoothest, .auto:
            if frameRate >= 120 { return 5 }
            if frameRate >= 60 { return 4 }
            return 2
        case .lowestLatency:
            if frameRate >= 120 { return 2 }
            return 1
        }
    }

    static func minInFlightFrames(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    )
    -> Int {
        if useLowLatencyPipeline { return 1 }
        switch latencyMode {
        case .smoothest, .auto:
            if frameRate >= 120 { return 4 }
            if frameRate >= 60 { return 3 }
            return 1
        case .lowestLatency:
            return 1
        }
    }
}

#endif
