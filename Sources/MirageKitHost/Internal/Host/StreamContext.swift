//
//  StreamContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import CoreMedia
import CoreVideo
import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

/// Manages the capture → encode → send pipeline for a single stream
/// Uses virtual displays for window isolation, with display-level capture cropped to visible bounds
actor StreamContext {
    let streamID: StreamID
    var windowID: WindowID
    let streamKind: VideoEncoder.StreamKind
    var encoderConfig: MirageEncoderConfiguration
    var streamScale: CGFloat
    var baseCaptureSize: CGSize = .zero
    var currentEncodedSize: CGSize = .zero
    var currentCaptureSize: CGSize = .zero
    var activePixelFormat: MiragePixelFormat
    var lastWindowFrame: CGRect = .zero
    var applicationProcessID: pid_t = 0
    var isAppStream: Bool = false
    var appStreamBundleIdentifier: String?
    var capturedWindowClusterWindowIDs: [WindowID] = []
    enum CaptureMode: Sendable {
        case window
        case display
    }

    let mediaMaxPacketSize: Int
    var mediaSendProfile: LoomQueuedUnreliableSendProfile?
    var mediaSendProfileRawValue: String?
    var mediaSendProfileMaxOutstandingPackets: Int?
    var mediaSendProfileMaxOutstandingBytes: Int?
    var mediaSendProfileMaxQueuedPackets: Int?
    var mediaSendProfileReference: Locked<LoomQueuedUnreliableSendProfile>?
    var mediaSendDiagnosticsProvider:
        (@Sendable (LoomQueuedUnreliableSendProfile) async -> LoomQueuedUnreliableSendDiagnostics?)?

    var captureMode: CaptureMode = .window
    /// Max payload size per UDP packet (excludes Mirage header).
    nonisolated let maxPayloadSize: Int
    let mediaSecurityContext: MirageMediaSecurityContext?
    nonisolated(unsafe) var shouldEncodeFrames: Bool = true

    /// Window capture engine (used for window and virtual-display modes).
    var captureEngine: WindowCaptureEngine?

    // Virtual display components (provides window isolation)
    // Uses SharedVirtualDisplayManager dedicated stream displays.
    var virtualDisplayContext: SharedVirtualDisplayManager.DisplaySnapshot?
    var virtualDisplayVisibleBounds: CGRect = .zero
    var virtualDisplayCaptureSourceRect: CGRect = .zero
    var virtualDisplayCapturePresentationRect: CGRect = .zero
    var displayP3CoverageStatusOverride: MirageDisplayP3CoverageStatus?
    var useVirtualDisplay: Bool = true
    var captureShowsCursor: Bool = false
    var desktopCaptureUsesDisplayRefreshCadenceOverride: Bool?

    var encoder: VideoEncoder?
    var isRunning = false

    /// Dimension token for rejecting old-dimension P-frames after client-visible geometry changes.
    /// Legacy emergency recovery scale changes may keep this stable when the presentation surface is unchanged.
    /// AWDL interactive resolution steps advance it so newer keyframes become the receiver's clean geometry anchor.
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (token is incremented on actor, read in callback)
    nonisolated(unsafe) var dimensionToken: UInt16 = 0

    /// Current content rectangle within the capture buffer
    /// Updated per-frame from ScreenCaptureKit to handle black padding
    /// Using nonisolated(unsafe) because we need to access from @Sendable encoder callback
    /// and the access pattern is safe (always set before read, in frame order)
    nonisolated(unsafe) var currentContentRect: CGRect = .zero

    // MARK: - Host Traffic-Light Clone-Stamp State

    var trafficLightMaskGeometryCache: HostTrafficLightMaskGeometryResolver.CacheEntry?
    let trafficLightMaskGeometryCacheTTL: CFAbsoluteTime = 0.35
    let trafficLightMaskGeometryFrameTolerance: CGFloat = 6
    var lastTrafficLightMaskLogTime: CFAbsoluteTime = 0
    let trafficLightMaskLogInterval: CFAbsoluteTime = 1.0
    lazy var trafficLightCloneStampCompositor = HostTrafficLightCloneStampCompositor()

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
    var lastNonIdleCapturedFrameTime: CFAbsoluteTime = 0
    var cachedStartupFrame: CapturedFrame?
    var lastStreamStatsLogTime: CFAbsoluteTime = 0
    var metricsUpdateHandler: (@Sendable (StreamMetricsMessage) -> Void)?
    var captureStallStageHandler: (@Sendable (CaptureStreamOutput.StallStage) -> Void)?
    var activeQuality: Float
    var qualityFloor: Float
    var qualityCeiling: Float
    var configuredQualityCeiling: Float
    var steadyQualityCeiling: Float
    var keyframeQualityFloor: Float
    let compressionQualityCeiling: Float = 0.94
    let qualityFloorFactor: Float = 0.45
    let keyframeFloorFactor: Float = 0.35
    let bitrateCappedQualityFloorFactor: Float = 0.45
    let bitrateCappedKeyframeFloorFactor: Float = 0.32
    let uncappedQualityFloorMinimum: Float = 0.06
    let bitrateCappedQualityFloorMinimum: Float = 0.04
    let bitrateCappedKeyframeFloorMinimum: Float = 0.02
    var pendingKeyframeReason: String?
    var pendingKeyframeDeadline: CFAbsoluteTime = 0
    var isKeyframeEncoding: Bool = false
    var pendingKeyframeRequiresFlush: Bool = false
    var pendingKeyframeUrgent: Bool = false
    var pendingKeyframeRequiresReset: Bool = false
    var protectedGeometryRecoveryKeyframeReason: String?
    var pendingEmergencyKeyframeQuality: Float?
    var lastClientInputTime: CFAbsoluteTime = 0
    nonisolated(unsafe) var suppressEncodedNonKeyframesUntilKeyframe = false
    enum HostFrameChainState: Sendable, Equatable {
        case normal
        case chainBroken(reason: String, firstBrokenFrame: UInt32?, openedAt: CFAbsoluteTime)
        case emergencyKeyframePending(reason: String, openedAt: CFAbsoluteTime)
        case postKeyframeCooling(untilCleanPFrames: Int)
    }
    var frameChainState: HostFrameChainState = .normal
    let recoveryKeyframeCooldown: CFAbsoluteTime = 5.0
    let postEmergencyKeyframeCleanPFrameCount = 8
    let recoveryScaleRestoreCleanPFrameCount = 90
    let emergencyKeyframeBudgetRatio: Double = 0.70
    var lastSuccessfulKeyframeSendTime: CFAbsoluteTime = 0
    var latestReceiverRecoveryCause: MirageMediaFeedbackRecoveryCause = .none
    var lastAcceptedExplicitKeyframeRequestCause: MirageMediaFeedbackRecoveryCause = .none
    var lastAcceptedExplicitKeyframeRequestTime: CFAbsoluteTime = 0
    let explicitKeyframeRequestDuplicateWindow: CFAbsoluteTime = 1.0
    var frameChainRepairKeyframeRetryTask: Task<Void, Never>?
    var pendingReceiverAcceptedKeyframeFrameNumber: UInt32?
    var emergencyRecoveryBaseStreamScale: CGFloat?
    var emergencyRecoveryScaleIndex: Int = 0
    var emergencyRecoveryCleanPFrames: Int = 0
    var emergencyRecoveryScaleChangeInProgress = false
    var encodedFrameQualityLastLogTime: CFAbsoluteTime = 0
    var encodeStageLastLogTime: CFAbsoluteTime = 0
    var senderFreshnessLastLogTime: CFAbsoluteTime = 0
    var receiverPFrameTimingSampleLastLogTime: CFAbsoluteTime = 0
    var lastStillQualityProbeEncodeTime: CFAbsoluteTime = 0
    var lastStillQualityRefreshKeyframeTime: CFAbsoluteTime = 0
    nonisolated(unsafe) var shouldAdmitIdleQualityProbeFrame = false
    var lastInFlightAdjustmentTime: CFAbsoluteTime = 0
    let inFlightAdjustmentCooldown: CFAbsoluteTime = 1.0
    var freshnessBurstActive = false
    var freshnessBurstEntryCount: UInt64 = 0
    var softFreshnessDrainActive = false
    var softFreshnessDrainDeadline: CFAbsoluteTime = 0
    var softFreshnessDrainCount: UInt64 = 0
    var latencyBurstActive = false
    var latencyBurstDrainsNewestFrames = false
    var latencyBurstCaptureQueueDepthOverride: Int?
    var preLatencyBurstCaptureQueueDepthOverride: Int?
    var enteredTargetBitrate: Int?
    var explicitEnteredTargetBitrate: Int?
    var bitrateAdaptationCeiling: Int?
    var requestedTargetBitrate: Int?
    var startupBitrate: Int?
    var ultraValidationFailureHandled = false
    var ultraValidationSuccessLogged = false
    var rateControlRetuneValidationTask: Task<Void, Never>?
    var rateControlRetuneValidationID: UInt64 = 0
    var rateControlRetuneValidationResult: String?
    var keyframeForRetuneCount: UInt64 = 0
    var encoderSessionRecreationCount: UInt64 = 0
    var adaptiveStreamScaleReason: String?
    var hostAdaptiveBudgetApplied = false

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
    var pipelineStatsLogScheduled = false
    let pipelineStatsInterval: CFAbsoluteTime = 2.0
    var lastCaptureIngressFPS: Double?
    var lastCaptureFPS: Double?
    var lastEncodeAttemptFPS: Double?
    var lastCaptureCadenceMetrics: StreamCaptureCadenceMetrics?
    var lastCapturedFrameTime: CFAbsoluteTime = 0
    var latestEncodeStartCaptureAgeMs: Double = 0
    var worstEncodeStartCaptureAgeMs: Double = 0
    var encoderThroughputHealthyBaselineMs: Double?
    var encoderThroughputHealthyBaselineKey: String?
    var startupBaseTime: CFAbsoluteTime = 0
    var startupLabel: String = ""
    var startupFirstCaptureLogged = false
    var startupFirstEncodeLogged = false
    var startupRegistrationLogged = false
    var startupFrameCachingEnabled = false

    /// Maximum time to wait for encode progress before considering encoder stuck (ms)
    /// During drag operations, VideoToolbox can block - we need to detect this and recover
    let maxEncodeTimeMs: Double

    /// Flag indicating encoder needs to be reset on next encode attempt
    /// Set when encoder is detected as stuck, cleared after reset
    var needsEncoderReset: Bool = false

    /// Timestamp of last encoder reset (for cooldown)
    var lastEncoderResetTime: CFAbsoluteTime = 0
    var encoderResetRetryTask: Task<Void, Never>?

    /// Minimum time between encoder resets (seconds)
    /// Prevents cascading resets during SCK pauses which cause multiple keyframes
    let encoderResetCooldown: CFAbsoluteTime = 1.0

    /// Flag to skip encoding during resize operations
    /// When true, incoming frames are dropped to prevent decode errors and wasted CPU
    /// Set before dimension updates begin, cleared after completion
    var isResizing: Bool = false
    /// True when desktop resize orchestration has explicitly paused encode admission.
    var encodingSuspendedForResize: Bool = false

    // MARK: - Backpressure

    /// Packet queue backpressure thresholds (bytes)
    let minQueuedBytes: Int = 400_000
    let maxQueuedBytesCap: Int = 8_000_000
    var maxQueuedBytes: Int = 2_000_000
    var queuePressureBytes: Int = 1_200_000
    var backpressureActive: Bool = false
    nonisolated(unsafe) var backpressureActiveSnapshot: Bool = false
    nonisolated(unsafe) var encoderAverageEncodeMsSnapshot: Double = 0
    nonisolated(unsafe) var encoderInFlightCountSnapshot: Int = 0
    var backpressureActivatedAt: CFAbsoluteTime = 0
    var transportSendErrorTimestamps: [CFAbsoluteTime] = []
    var lastTransportSendErrorRecoveryTime: CFAbsoluteTime = 0
    let transportSendErrorWindow: CFAbsoluteTime = 1.0
    let transportSendErrorThreshold: Int = 6
    let transportSendErrorRecoveryCooldown: CFAbsoluteTime = 2.0
    var transportSendErrorBursts: UInt64 = 0
    var transportController = HostStreamTransportController()
    var adaptivePFrameController = HostAdaptivePFrameController()
    var realtimeRuntimeQualityCeiling: Float?
    var realtimeRuntimeBitrateCeilingBps: Int?
    var realtimeEncoderRateHintBps: Int?
    var realtimeSenderPacingBitrateBps: Int?
    var realtimeLastEncoderRateRaiseTime: CFAbsoluteTime = 0
    var realtimeLastEncoderThroughputAdjustmentTime: CFAbsoluteTime = 0
    var realtimePressureState: HostAdaptivePFrameController.PressureState = .observing
    var realtimePressureReason: String?
    var realtimeLastLoggedState: HostAdaptivePFrameController.PressureState = .observing
    var realtimeLastLoggedBitrateCeilingBps: Int?
    var realtimeLastLogTime: CFAbsoluteTime = 0
    nonisolated(unsafe) var realtimeMinimumBitrateFloorBps: Int = 12_000_000
    var encoderThroughputMinimumBitrateFloorBps: Int = 12_000_000
    var receiverReassemblyBacklogFrames = 0
    var receiverReassemblyBacklogBytes = 0
    var receiverDecodeBacklogFrames = 0
    var receiverPresentationBacklogFrames = 0
    var receiverLatestAcceptedFrameNumber: UInt32?
    var receiverLatestPresentedFrameNumber: UInt32?
    var receiverLatestPresentedFrameAgeMs: Double?
    var receiverCapacityLearningQuarantineUntil: CFAbsoluteTime = 0
    var receiverCapacityLearningQuarantineReason: String?
    var receiverLostFrameCount: UInt64 = 0
    var receiverDiscardedPacketCount: UInt64 = 0
    var lastObservedReceiverLostFrameCount: UInt64?
    var lastObservedReceiverDiscardedPacketCount: UInt64?
    var receiverFrameBudgetLossHoldUntil: CFAbsoluteTime = 0
    var receiverPlayoutDelayTargetMs: Double?
    var receiverAcknowledgedFrameNumber: UInt32?
    var receiverAckLagMs: Double?
    var lastReceiverAckTime: CFAbsoluteTime = 0
    var recentFrameTransportCompletions: [StreamPacketSender.FrameTransportCompletion] = []
    let recentFrameTransportCompletionLimit = 240
    var lastReceiverFeedbackTime: CFAbsoluteTime = 0
    var lastAwdlReceiverFeedbackLogTime: CFAbsoluteTime = 0
    var lastAwdlReceiverFeedbackTrigger: HostStreamTransportController.PressureTrigger = .none
    var lastAwdlInteractiveFrameRateAdjustmentTime: CFAbsoluteTime = 0
    var lastAwdlInteractiveScaleAdjustmentTime: CFAbsoluteTime = 0
    var awdlInteractiveBaseStreamScale: CGFloat?
    var awdlHostEncoderStructuralQualityReductionAllowed = false
    var awdlHostEncoderStructuralQualityReductionDeadline: CFAbsoluteTime = 0
    let awdlHostEncoderStructuralQualityReductionHold: CFAbsoluteTime = 3.0
    var pendingAwdlInteractiveFrameRate: Int?
    var pendingAwdlInteractiveFrameRateReason: String?
    var pendingAwdlInteractiveResolutionScale: Double?
    var pendingAwdlInteractiveScaleReason: String?
    nonisolated(unsafe) var latestAwdlMediaDecisionSnapshot: MirageAwdlMediaController.Decision?

    /// Keyframe request throttling
    let keyframeRequestCooldown: CFAbsoluteTime = 0.25
    let keyframeInFlightCap: CFAbsoluteTime = 1.0
    let keyframeSettleTimeout: CFAbsoluteTime = 2.0
    let keyframeQueueSettleFactor: Double = 0.4
    let startupTransportProtectionHold: CFAbsoluteTime = 5.0
    let startupKeyframeFECBlockSize: Int = 4
    var lastKeyframeRequestTime: CFAbsoluteTime = 0
    var keyframeSendDeadline: CFAbsoluteTime = 0
    var keyframeInFlightFrameNumber: UInt32?
    var recentKeyframeRequestTimes: [CFAbsoluteTime] = []
    var dependencyRecoveryKeyframeRetryTask: Task<Void, Never>?
    var dependencyRecoveryPendingDropFrameNumber: UInt32?
    var dependencyRecoveryPendingDropReason: StreamPacketSender.DependencyFrameDropReason?
    var dependencyRecoveryPendingQueuedBytes: Int = 0
    var dependencyRecoveryRetryNecessary = false
    var lastObservedSenderLocalDeadlineDrops: UInt64?
    var lastObservedNonKeyframeHoldDrops: UInt64?
    var senderFrameBudgetDropHoldUntil: CFAbsoluteTime = 0

    /// Scheduled keyframe cadence derived from keyFrameInterval/currentFrameRate.
    var keyframeIntervalSeconds: CFAbsoluteTime = 0
    var keyframeMaxIntervalSeconds: CFAbsoluteTime = 0
    var lastKeyframeTime: CFAbsoluteTime = 0
    let scheduledKeyframesEnabled = false

    /// Recovery request tracking.
    var softRecoveryCount: UInt64 = 0

    /// Loss-mode deadline for adaptive redundancy and pacing.
    /// When active, keyframes and P-frames include FEC parity fragments.
    nonisolated(unsafe) var lossModeDeadline: CFAbsoluteTime = 0
    nonisolated(unsafe) var lossModePFrameFECDeadline: CFAbsoluteTime = 0
    nonisolated(unsafe) var startupTransportProtectionDeadline: CFAbsoluteTime = 0
    let lossModeHold: CFAbsoluteTime = 4.0
    let pFrameFECLossModeHold: CFAbsoluteTime = 8.0

    /// Frame rate for cadence and queue limits
    nonisolated(unsafe) var currentFrameRate: Int
    /// AWDL restore ceiling preserved across runtime cadence demotions.
    nonisolated(unsafe) var awdlInteractiveFrameRateCeiling: Int
    /// Bitrate snapshot read from encoder callbacks for packet pacing policy.
    nonisolated(unsafe) var currentTargetBitrateBps: Int?
    /// Effective capture cadence reported by ScreenCaptureKit.
    var captureFrameRate: Int
    /// Optional override for capture frame rate.
    var captureFrameRateOverride: Int?

    /// Maximum encoded resolution (5K cap)
    static let maxEncodedWidth: CGFloat = 5120
    static let maxEncodedHeight: CGFloat = 2880

    /// Callback for captured audio buffers from ScreenCaptureKit.
    var onCapturedAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    /// Host callback used to announce AWDL-driven desktop dimension changes before the recovery keyframe.
    var onAwdlInteractiveDesktopGeometryUpdate: (@MainActor @Sendable (StreamID) async -> Void)?
    /// Requested ScreenCaptureKit audio capture channel count for this stream.
    var requestedAudioChannelCount: Int = MirageAudioChannelLayout.stereo.channelCount

    /// Serializes packet fragmentation/sending to preserve frame order
    var packetSender: StreamPacketSender?

    /// Base flags to include on all frames for this stream
    let baseFrameFlags: FrameFlags

    /// Dynamic flags applied to the next encoded frame.
    nonisolated(unsafe) var dynamicFrameFlags: FrameFlags = []

    /// Stream epoch for discontinuity boundaries.
    /// Incremented when the host resets capture or send state.
    nonisolated(unsafe) var epoch: UInt16 = 0

    /// Latency preference for buffering behavior.
    let latencyMode: MirageStreamLatencyMode
    /// Client/requested latency preference before media-path policy normalization.
    let requestedLatencyMode: MirageStreamLatencyMode
    /// Host-side capture-to-encode buffering preference.
    let hostBufferingPolicy: MirageHostBufferingPolicy
    /// Client/requested host buffering preference before media-path policy normalization.
    let requestedHostBufferingPolicy: MirageHostBufferingPolicy
    /// Classified transport path used for proximity-specific media policy.
    let transportPathKind: MirageNetworkPathKind
    /// Media behavior profile used for real-time pacing and admission policy.
    let mediaPathProfile: MirageMediaPathProfile
    /// Raw/client policy/effective path summary captured at stream startup for boundary diagnostics.
    let mediaPathDiagnosticSummary: String
    /// Video transport contract selected for dependency-coded media packets.
    /// When true, force low-latency buffering regardless of overrides.
    let useLowLatencyPipeline: Bool
    /// Client-requested stream scale.
    var requestedStreamScale: CGFloat
    /// When false, runtime quality adjustments remain fixed at derived baseline quality.
    var runtimeQualityAdjustmentEnabled: Bool
    /// Whether the client supplied an adaptive ceiling before host startup budgeting normalized it.
    let clientRequestedBitrateAdaptationCeiling: Bool
    /// When true, encoder overload may temporarily lower quality below the manual readability floor.
    var encoderCatchUpQualityAdjustmentEnabled: Bool
    /// When true, lowest-latency high-resolution streams use stronger compression.
    let lowLatencyHighResolutionCompressionBoostEnabled: Bool
    /// When true, bypasses the host-side encoded-dimension cap.
    let disableResolutionCap: Bool
    /// Maximum encoded width in pixels for host-computed stream scaling.
    var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels for host-computed stream scaling.
    var encoderMaxHeight: Int?
    /// When true, request VideoToolbox power-efficiency preference on the encoder session.
    var encoderLowPowerEnabled: Bool
    /// Capture pressure profile for SCK buffering/copy behavior.
    let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
    nonisolated static let minAudioCaptureChannelCount: Int = 1
    nonisolated static let maxAudioCaptureChannelCount: Int = 8

    nonisolated static func clampedAudioCaptureChannelCount(_ channelCount: Int) -> Int {
        min(max(channelCount, minAudioCaptureChannelCount), maxAudioCaptureChannelCount)
    }

    nonisolated static func resolvedMediaPathProfile(
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile?
    ) -> MirageMediaPathProfile {
        MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    init(
        streamID: StreamID,
        windowID: WindowID,
        streamKind: VideoEncoder.StreamKind = .window,
        encoderConfig: MirageEncoderConfiguration,
        streamScale: CGFloat = 1.0,
        requestedAudioChannelCount: Int = MirageAudioChannelLayout.stereo.channelCount,
        maxPacketSize: Int = mirageDefaultMaxPacketSize,
        mediaSecurityContext: MirageMediaSecurityContext? = nil,
        additionalFrameFlags: FrameFlags = [],
        runtimeQualityAdjustmentEnabled: Bool = true,
        encoderCatchUpQualityAdjustmentEnabled: Bool = true,
        lowLatencyHighResolutionCompressionBoostEnabled: Bool = false,
        disableResolutionCap: Bool = false,
        encoderLowPowerEnabled: Bool = false,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        hostBufferingPolicy: MirageHostBufferingPolicy = .freshestFrame,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile? = nil,
        mediaPathDiagnosticSummary: String? = nil,
        enteredBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        captureShowsCursor: Bool = false
    ) {
        var resolvedEncoderConfig = encoderConfig
        if let bitrateAdaptationCeiling,
           let requestedBitrate = resolvedEncoderConfig.bitrate,
           requestedBitrate > bitrateAdaptationCeiling {
            resolvedEncoderConfig.bitrate = bitrateAdaptationCeiling
        }
        let requestedTargetBitrate = resolvedEncoderConfig.bitrate

        let resolvedMediaPathProfile = Self.resolvedMediaPathProfile(
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
        let effectiveLatencyMode = MirageAwdlMediaController.fixedLatencyMode(
            requestedLatencyMode: latencyMode,
            mediaPathProfile: resolvedMediaPathProfile
        )
        let effectiveHostBufferingPolicy = resolvedMediaPathProfile.usesAwdlRadioPolicy
            ? MirageHostBufferingPolicy.stability
            : hostBufferingPolicy
        resolvedEncoderConfig.targetFrameRate = MirageAwdlMediaController.fixedDisplayTargetFrameRate(
            requestedFrameRate: resolvedEncoderConfig.targetFrameRate,
            mediaPathProfile: resolvedMediaPathProfile
        )
        let awdlInteractiveFrameRateCeiling = resolvedEncoderConfig.targetFrameRate

        self.streamID = streamID
        self.windowID = windowID
        self.streamKind = streamKind
        self.encoderConfig = resolvedEncoderConfig
        requestedLatencyMode = latencyMode
        self.latencyMode = effectiveLatencyMode
        requestedHostBufferingPolicy = hostBufferingPolicy
        self.hostBufferingPolicy = effectiveHostBufferingPolicy
        self.transportPathKind = transportPathKind
        self.mediaPathProfile = resolvedMediaPathProfile
        self.mediaPathDiagnosticSummary = mediaPathDiagnosticSummary ??
            "hostPath=unknown/unknown clientPath=unknown/unknown clientPolicy=unknown/unknown " +
            "resolved=\(transportPathKind.rawValue)/\(resolvedMediaPathProfile.rawValue)"
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        self.streamScale = clampedScale
        requestedStreamScale = clampedScale
        self.captureShowsCursor = captureShowsCursor
        baseFrameFlags = resolvedEncoderConfig.codec == .proRes4444
            ? additionalFrameFlags.union(.proResCodec)
            : additionalFrameFlags
        maxPayloadSize = miragePayloadSize(maxPacketSize: maxPacketSize)
        mediaMaxPacketSize = maxPacketSize
        self.mediaSecurityContext = mediaSecurityContext
        currentFrameRate = resolvedEncoderConfig.targetFrameRate
        self.awdlInteractiveFrameRateCeiling = awdlInteractiveFrameRateCeiling
        currentTargetBitrateBps = resolvedEncoderConfig.bitrate
        captureFrameRateOverride = nil
        captureFrameRate = resolvedEncoderConfig.targetFrameRate
        self.runtimeQualityAdjustmentEnabled = runtimeQualityAdjustmentEnabled
        clientRequestedBitrateAdaptationCeiling = bitrateAdaptationCeiling != nil
        self.encoderCatchUpQualityAdjustmentEnabled = encoderCatchUpQualityAdjustmentEnabled
        self.lowLatencyHighResolutionCompressionBoostEnabled =
            lowLatencyHighResolutionCompressionBoostEnabled
        self.disableResolutionCap = disableResolutionCap
        self.encoderMaxWidth = encoderMaxWidth
        self.encoderMaxHeight = encoderMaxHeight
        self.encoderLowPowerEnabled = encoderLowPowerEnabled
        self.capturePressureProfile = capturePressureProfile
        self.requestedAudioChannelCount = Self.clampedAudioCaptureChannelCount(requestedAudioChannelCount)
        activePixelFormat = resolvedEncoderConfig.pixelFormat
        let prefersSmoothness = effectiveLatencyMode == .smoothest
        let latencySensitive = effectiveLatencyMode == .lowestLatency
        useLowLatencyPipeline = latencySensitive || (resolvedEncoderConfig.targetFrameRate >= 120 && !prefersSmoothness)
        let bufferPolicy = Self.resolvedBufferPolicy(
            streamKind: streamKind,
            frameRate: resolvedEncoderConfig.targetFrameRate,
            latencyMode: effectiveLatencyMode,
            hostBufferingPolicy: effectiveHostBufferingPolicy,
            mediaPathProfile: resolvedMediaPathProfile,
            useLowLatencyPipeline: useLowLatencyPipeline
        )
        maxInFlightFramesCap = bufferPolicy.maxInFlightFramesCap
        minInFlightFrames = bufferPolicy.minimumInFlightFrames
        maxInFlightFrames = bufferPolicy.initialInFlightFrames
        frameBufferDepth = bufferPolicy.bufferDepth
        frameInbox = StreamFrameInbox(capacity: bufferPolicy.bufferDepth)
        maxEncodeTimeMs = resolvedEncoderConfig.targetFrameRate >= 120 ? 900 : 600
        shouldEncodeFrames = false
        let cappedFrameQuality = min(resolvedEncoderConfig.frameQuality, compressionQualityCeiling)
        configuredQualityCeiling = cappedFrameQuality
        steadyQualityCeiling = cappedFrameQuality
        qualityCeiling = cappedFrameQuality
        let hasBitrateCap = (resolvedEncoderConfig.bitrate ?? 0) > 0
        let runtimeFloorFactor = hasBitrateCap ? bitrateCappedQualityFloorFactor : qualityFloorFactor
        let runtimeFloorMinimum = hasBitrateCap ? bitrateCappedQualityFloorMinimum : uncappedQualityFloorMinimum
        qualityFloor = min(cappedFrameQuality, max(runtimeFloorMinimum, cappedFrameQuality * runtimeFloorFactor))
        activeQuality = cappedFrameQuality
        let cappedKeyframeQuality = min(resolvedEncoderConfig.keyframeQuality, cappedFrameQuality)
        let keyframeFloorFactor = hasBitrateCap ? bitrateCappedKeyframeFloorFactor : self.keyframeFloorFactor
        let keyframeFloorMinimum = hasBitrateCap ? bitrateCappedKeyframeFloorMinimum : uncappedQualityFloorMinimum
        keyframeQualityFloor = min(cappedKeyframeQuality, max(keyframeFloorMinimum, cappedKeyframeQuality * keyframeFloorFactor))
        let cadence = Self.keyframeCadence(
            intervalFrames: resolvedEncoderConfig.keyFrameInterval,
            frameRate: resolvedEncoderConfig.targetFrameRate
        )
        keyframeIntervalSeconds = cadence.interval
        keyframeMaxIntervalSeconds = cadence.maxInterval
        self.enteredTargetBitrate = enteredBitrate ?? requestedTargetBitrate
        self.explicitEnteredTargetBitrate = enteredBitrate
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.requestedTargetBitrate = requestedTargetBitrate
        startupBitrate = resolvedEncoderConfig.bitrate
    }

    func setAwdlInteractiveDesktopGeometryUpdateHandler(
        _ handler: (@MainActor @Sendable (StreamID) async -> Void)?
    ) {
        onAwdlInteractiveDesktopGeometryUpdate = handler
    }

}

#endif
