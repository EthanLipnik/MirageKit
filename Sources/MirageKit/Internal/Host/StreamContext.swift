//
//  StreamContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import CoreMedia
import CoreVideo

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
    nonisolated(unsafe) var shouldEncodeFrames: Bool = true

    // Window capture engine (used both for legacy and virtual display modes)
    var captureEngine: WindowCaptureEngine?

    // Virtual display components (provides window isolation)
    // Uses SharedVirtualDisplayManager for single shared display across all streams
    var virtualDisplayContext: SharedVirtualDisplayManager.ManagedDisplayContext?
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
    let qualityFloor: Float
    let qualityCeiling: Float
    let keyframeQualityFloor: Float
    var pendingKeyframeReason: String? = nil
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

    // Pipeline throughput metrics (interval counters)
    var captureIntervalCount: UInt64 = 0
    var captureDroppedIntervalCount: UInt64 = 0
    var encodeAttemptIntervalCount: UInt64 = 0
    var encodeAcceptedIntervalCount: UInt64 = 0
    var encodeRejectedIntervalCount: UInt64 = 0
    var encodeErrorIntervalCount: UInt64 = 0
    var lastPipelineStatsLogTime: CFAbsoluteTime = 0
    let pipelineStatsInterval: CFAbsoluteTime = 2.0
    var lastCapturedFrameTime: CFAbsoluteTime = 0
    var cadenceTask: Task<Void, Never>?
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
    let minQueuedBytes: Int = 1_000_000
    let maxQueuedBytesCap: Int = 8_000_000
    var maxQueuedBytes: Int = 2_000_000
    var queuePressureBytes: Int = 1_500_000
    let backpressureLogInterval: CFAbsoluteTime = 1.0
    var lastBackpressureLogTime: CFAbsoluteTime = 0
    var backpressureActive: Bool = false

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

    /// Frame rate for cadence and queue limits
    var currentFrameRate: Int
    /// Frame rate requested from ScreenCaptureKit.
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

    /// Drops capture frames when capture cadence exceeds the encoder target cadence.
    nonisolated let frameThrottle = StreamFrameThrottle()

    /// Whether idle frames should be encoded to maintain cadence.
    let shouldMaintainIdleFrames: Bool

    /// Quality preset used to configure latency-sensitive defaults.
    let qualityPreset: MirageQualityPreset?
    /// Latency preference for buffering behavior.
    let latencyMode: MirageStreamLatencyMode
    /// When true, force low-latency buffering regardless of preset.
    let useLowLatencyPipeline: Bool
    /// Client-requested stream scale (before adaptive adjustments).
    var requestedStreamScale: CGFloat
    /// Whether adaptive stream scaling is allowed for this stream.
    var adaptiveScaleEnabled: Bool
    /// Adaptive multiplier applied when capture FPS falls below target.
    var adaptiveScale: CGFloat = 1.0
    /// Adaptive stream scale update handler (host sends dimension update to client).
    var streamScaleUpdateHandler: (@Sendable (StreamID) -> Void)?
    var adaptiveScaleLowStreak: Int = 0
    var adaptiveScaleHighStreak: Int = 0
    var lastAdaptiveScaleChangeTime: CFAbsoluteTime = 0
    let adaptiveScaleCooldown: CFAbsoluteTime = 6.0
    let adaptiveScaleLowThreshold: Double = 0.85
    let adaptiveScaleHighThreshold: Double = 0.97
    let adaptiveScaleDownSamples: Int = 2
    let adaptiveScaleUpSamples: Int = 4
    let adaptiveScaleDownStep: CGFloat = 0.9
    let adaptiveScaleUpStep: CGFloat = 1.05
    let adaptiveScaleMin: CGFloat = 0.7

    init(
        streamID: StreamID,
        windowID: WindowID,
        encoderConfig: MirageEncoderConfiguration,
        qualityPreset: MirageQualityPreset? = nil,
        streamScale: CGFloat = 1.0,
        maxPacketSize: Int = MirageDefaultMaxPacketSize,
        additionalFrameFlags: FrameFlags = [],
        adaptiveScaleEnabled: Bool = true,
        latencyMode: MirageStreamLatencyMode = .smoothest
    ) {
        self.streamID = streamID
        self.windowID = windowID
        self.encoderConfig = encoderConfig
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        self.streamScale = clampedScale
        self.requestedStreamScale = clampedScale
        self.adaptiveScaleEnabled = adaptiveScaleEnabled
        self.baseFrameFlags = additionalFrameFlags
        self.shouldMaintainIdleFrames = additionalFrameFlags.contains(.desktopStream)
        self.maxPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        self.currentFrameRate = encoderConfig.targetFrameRate
        self.captureFrameRateOverride = nil
        self.captureFrameRate = encoderConfig.targetFrameRate
        self.activePixelFormat = encoderConfig.pixelFormat
        let prefersSmoothness = latencyMode == .smoothest
        let latencySensitive = latencyMode == .lowestLatency || qualityPreset == .lowLatency
        self.useLowLatencyPipeline = latencySensitive || (encoderConfig.targetFrameRate >= 120 && !prefersSmoothness)
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
        self.maxInFlightFramesCap = max(1, inFlightCap)
        self.minInFlightFrames = minInFlight
        self.maxInFlightFrames = min(minInFlight, maxInFlightFramesCap)
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
        frameThrottle.configure(
            targetFrameRate: currentFrameRate,
            captureFrameRate: captureFrameRate,
            isPaced: true
        )
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
        if let override = captureFrameRateOverride {
            return override
        }
        return targetFrameRate
    }

    func updateFrameThrottle() {
        frameThrottle.configure(
            targetFrameRate: currentFrameRate,
            captureFrameRate: captureFrameRate,
            isPaced: true
        )
    }

    static func frameBufferDepth(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        if useLowLatencyPipeline {
            return frameRate >= 120 ? 2 : 1
        }
        switch latencyMode {
        case .smoothest:
            if frameRate >= 120 {
                return 6
            }
            if frameRate >= 60 {
                return 5
            }
            return 3
        case .balanced:
            if frameRate >= 120 {
                return 4
            }
            if frameRate >= 60 {
                return 3
            }
            return 2
        case .lowestLatency:
            if frameRate >= 120 {
                return 2
            }
            if frameRate >= 60 {
                return 2
            }
            return 1
        }
    }

    static func inFlightCap(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        if useLowLatencyPipeline {
            return frameRate >= 120 ? 2 : 1
        }
        switch latencyMode {
        case .smoothest:
            if frameRate >= 120 {
                return 5
            }
            if frameRate >= 60 {
                return 4
            }
            return 2
        case .balanced:
            if frameRate >= 120 {
                return 3
            }
            if frameRate >= 60 {
                return 2
            }
            return 1
        case .lowestLatency:
            if frameRate >= 120 {
                return 2
            }
            return 1
        }
    }

    static func minInFlightFrames(
        useLowLatencyPipeline: Bool,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        if useLowLatencyPipeline {
            return 1
        }
        switch latencyMode {
        case .smoothest:
            if frameRate >= 120 {
                return 4
            }
            if frameRate >= 60 {
                return 3
            }
            return 1
        case .balanced:
            if frameRate >= 60 {
                return 2
            }
            return 1
        case .lowestLatency:
            return 1
        }
    }
}

#endif
