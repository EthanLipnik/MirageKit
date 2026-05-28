//
//  MirageClientMetricsSnapshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

/// Point-in-time client and host telemetry for one rendered stream.
public struct MirageClientMetricsSnapshot: Sendable, Equatable {
    /// Frames decoded per second by the client video decoder.
    public var decodedFPS: Double
    /// Media frames received per second from the host.
    public var receivedFPS: Double
    /// Worst inter-arrival gap observed in received client frames, in milliseconds.
    public var clientReceivedWorstGapMs: Double
    /// 95th percentile received-frame interval, in milliseconds.
    public var clientReceivedFrameIntervalP95Ms: Double
    /// 99th percentile received-frame interval, in milliseconds.
    public var clientReceivedFrameIntervalP99Ms: Double
    /// Display-clock ticks per second observed by the client renderer.
    public var clientDisplayTickFPS: Double
    /// Frame submission attempts per second made by the client renderer.
    public var clientSubmitAttemptFPS: Double
    /// Submitted frames per second accepted by the display layer.
    public var clientLayerAcceptedFPS: Double
    /// Unique accepted frame submissions per second. This is not guaranteed scan-out cadence.
    public var clientPresentedFPS: Double
    /// Frame submissions per second, including repeated frames.
    public var submittedFPS: Double
    /// Unique frame submissions per second.
    public var uniqueSubmittedFPS: Double
    /// Number of decoded frames waiting for presentation.
    public var pendingFrameCount: Int
    /// Age of the oldest pending decoded frame, in milliseconds.
    public var clientPendingFrameAgeMs: Double
    /// Current Smoothest-mode display debt, in milliseconds.
    public var clientSmoothestDisplayDebtMs: Double
    /// Active Smoothest-mode display debt cap, in milliseconds.
    public var clientSmoothestDisplayDebtCapMs: Double
    /// Current Smoothest-mode target playout delay, in milliseconds.
    public var clientSmoothestTargetDelayMs: Double
    /// Number of Smoothest display ticks that found no frame ready for playout.
    public var clientSmoothestUnderflowCount: UInt64
    /// Number of pending decoded frames overwritten before presentation.
    public var clientOverwrittenPendingFrames: UInt64
    /// Number of Smoothest-mode decoded frames dropped by local playout queue bounds.
    public var clientSmoothestQueueDrops: UInt64
    /// Number of Smoothest-mode frames dropped because queued display debt exceeded the live threshold.
    public var clientSmoothestDisplayDebtDrops: UInt64
    /// Number of Smoothest-mode FIFO resets caused by stale or excessive display debt.
    public var clientSmoothestFifoResetCount: UInt64
    /// Number of Smoothest-mode frames dropped because the queue exceeded its depth bound.
    public var clientSmoothestDepthDrops: UInt64
    /// Number of Smoothest-mode frames dropped because queued frames exceeded the stale-age bound.
    public var clientSmoothestAgeDrops: UInt64
    /// Number of Smoothest-mode frames dropped while younger than 100 ms.
    public var clientSmoothestDropsUnder100ms: UInt64
    /// Maximum local age for a Smoothest-mode dropped frame.
    public var clientSmoothestDroppedFrameAgeMaxMs: Double
    /// Number of frames dropped because they arrived too late for presentation.
    public var clientLateFrameDrops: UInt64
    /// Number of times the display layer rejected submission because it was not ready.
    public var clientDisplayLayerNotReadyCount: UInt64
    /// Number of repeated-frame presentations used to preserve cadence.
    public var clientRepeatedFrameCount: UInt64
    private var clientRepeatedDeliveredSourceFrameCountStorage: UInt64
    /// Number of expected display ticks that did not present a new frame.
    public var clientMissedVSyncCount: UInt64
    /// 95th percentile display-tick interval, in milliseconds.
    public var clientDisplayTickIntervalP95Ms: Double
    /// 99th percentile display-tick interval, in milliseconds.
    public var clientDisplayTickIntervalP99Ms: Double
    /// Current playout delay measured in frames.
    public var clientPlayoutDelayFrames: Int
    /// Number of detected presentation stalls.
    public var clientPresentationStallCount: UInt64
    /// Worst gap between presented frames, in milliseconds.
    public var clientWorstPresentationGapMs: Double
    /// 95th percentile presented-frame interval, in milliseconds.
    public var clientFrameIntervalP95Ms: Double
    /// 99th percentile presented-frame interval, in milliseconds.
    public var clientFrameIntervalP99Ms: Double
    /// Whether the decode pipeline currently appears healthy.
    public var decodeHealthy: Bool
    /// Total frames dropped by client-side decode or render admission.
    public var clientDroppedFrames: UInt64
    /// Number of incomplete frames currently retained by the packet reassembler.
    public var clientReassemblerPendingFrameCount: Int
    /// Number of pending reassembled frames that are keyframes.
    public var clientReassemblerPendingKeyframeCount: Int
    /// Bytes retained by the packet reassembler for incomplete frames.
    public var clientReassemblerPendingBytes: Int
    /// Bytes retained by the decoded frame buffer pool.
    public var clientFrameBufferPoolRetainedBytes: Int
    /// Number of packet reassembler evictions caused by memory budget pressure.
    public var clientReassemblerBudgetEvictions: UInt64
    /// Number of timed-out non-keyframes that were missing one or more media fragments.
    public var clientReassemblerIncompleteFrameTimeouts: UInt64
    /// Number of incomplete non-keyframes that timed out after no fragment progress.
    public var clientReassemblerIncompleteFrameNoProgressTimeouts: UInt64
    /// Number of incomplete non-keyframes that reached the absolute lifetime cap.
    public var clientReassemblerIncompleteFrameLifetimeTimeouts: UInt64
    /// Number of media fragments missing from timed-out incomplete non-keyframes.
    public var clientReassemblerMissingFragmentTimeouts: UInt64
    /// Number of buffered forward gaps that reached the reorder timeout.
    public var clientReassemblerForwardGapTimeouts: UInt64
    /// Recent P-frame assembly latency p50, in milliseconds.
    public var clientPFrameCompletionLatencyP50Ms: Double
    /// Recent P-frame assembly latency p95, in milliseconds.
    public var clientPFrameCompletionLatencyP95Ms: Double
    /// Recent maximum P-frame assembly latency, in milliseconds.
    public var clientPFrameCompletionLatencyMaxMs: Double
    /// Recent P-frames whose assembly latency exceeded the late threshold.
    public var clientLatePFrameCompletionCount: UInt64
    private var clientDecodeBacklogFrameCountStorage: Int
    /// Frames encoded per second by the host encoder.
    public var hostEncodedFPS: Double
    /// Idle frames per second emitted by the host when no new capture content is available.
    public var hostIdleFPS: Double
    /// Total frames dropped by the host capture or encoding pipeline.
    public var hostDroppedFrames: UInt64
    /// Active host encoder quality value.
    public var hostActiveQuality: Double
    /// Host target frame rate for the active stream.
    public var hostTargetFrameRate: Int
    /// User-entered host bitrate, in bits per second.
    public var hostEnteredBitrate: Int?
    /// Current host encoder bitrate, in bits per second.
    public var hostCurrentBitrate: Int?
    /// Host-requested encoder bitrate, in bits per second.
    public var hostEncoderRequestedBitrateBps: Int?
    /// Measured host encoded-output bitrate, in bits per second.
    public var hostEncoderActualBitrateBps: Int?
    /// Measurement window used for encoded-output bitrate, in milliseconds.
    public var hostEncoderActualWindowMs: Int?
    /// 50th percentile encoded frame size, in bytes.
    public var hostEncodedFrameBytesP50: Int?
    /// 95th percentile encoded frame size, in bytes.
    public var hostEncodedFrameBytesP95: Int?
    /// 99th percentile encoded frame size, in bytes.
    public var hostEncodedFrameBytesP99: Int?
    /// 50th percentile encoded keyframe size, in bytes.
    public var hostEncodedKeyframeBytesP50: Int?
    /// 95th percentile encoded keyframe size, in bytes.
    public var hostEncodedKeyframeBytesP95: Int?
    /// 99th percentile encoded keyframe size, in bytes.
    public var hostEncodedKeyframeBytesP99: Int?
    /// Active host encoder rate-control strategy.
    public var hostEncoderRateControlStrategy: MirageEncoderRateControlStrategy?
    /// Host encoder data-rate limit, in bytes.
    public var hostEncoderRateLimitBytes: Int?
    /// Host encoder data-rate limit window, in milliseconds.
    public var hostEncoderRateLimitWindowMs: Int?
    /// Effective encoded stream scale selected by the host.
    public var hostEffectiveStreamScale: Double?
    /// Most recent adaptive stream-scale reason.
    public var hostAdaptiveStreamScaleReason: String?
    /// Most recent host retune validation result.
    public var hostEncoderRetuneValidationResult: String?
    /// Number of keyframes forced for bitrate-retune validation.
    public var hostEncoderKeyframeForRetuneCount: UInt64?
    /// Number of VT session recreations forced for bitrate-retune validation.
    public var hostEncoderSessionRecreationCount: UInt64?
    /// Most recent client-requested target bitrate, in bits per second.
    public var hostRequestedTargetBitrate: Int?
    /// Current host-side bitrate adaptation ceiling, in bits per second.
    public var hostBitrateAdaptationCeiling: Int?
    /// Startup bitrate selected by the host encoder, in bits per second.
    public var hostStartupBitrate: Int?
    /// Host-side realtime bitrate ceiling, in bits per second.
    public var hostRealtimeBitrateCeiling: Int?
    /// Host-side realtime pressure state.
    public var hostRealtimePressureState: String?
    /// Host-side realtime pressure reason.
    public var hostRealtimePressureReason: String?
    /// Number of frames rejected by host capture admission control.
    public var hostCaptureAdmissionDrops: UInt64?
    /// Host frame budget, in milliseconds.
    public var hostFrameBudgetMs: Double?
    /// Average host encode duration, in milliseconds.
    public var hostAverageEncodeMs: Double?
    /// Frames per second entering the host capture pipeline.
    public var hostCaptureIngressFPS: Double?
    /// Frames per second delivered by host capture.
    public var hostCaptureFPS: Double?
    /// Host encode attempts per second.
    public var hostEncodeAttemptFPS: Double?
    /// Whether the host is using hardware video encoding.
    public var hostUsingHardwareEncoder: Bool?
    /// Registry identifier for the GPU used by the host encoder.
    public var hostEncoderGPURegistryID: UInt64?
    /// Width of encoded host frames, in pixels.
    public var hostEncodedWidth: Int?
    /// Height of encoded host frames, in pixels.
    public var hostEncodedHeight: Int?
    /// Pixel format reported by host capture.
    public var hostCapturePixelFormat: String?
    /// Color primaries reported by host capture.
    public var hostCaptureColorPrimaries: String?
    /// Pixel format emitted by the host encoder.
    public var hostEncoderPixelFormat: String?
    /// Chroma sampling emitted by the host encoder.
    public var hostEncoderChromaSampling: String?
    /// Codec profile used by the host encoder.
    public var hostEncoderProfile: String?
    /// Color primaries emitted by the host encoder.
    public var hostEncoderColorPrimaries: String?
    /// Transfer function emitted by the host encoder.
    public var hostEncoderTransferFunction: String?
    /// YCbCr matrix emitted by the host encoder.
    public var hostEncoderYCbCrMatrix: String?
    /// Host validation status for Display P3 coverage.
    public var hostDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus?
    /// Whether the host validated ten-bit Display P3 output.
    public var hostTenBitDisplayP3Validated: Bool?
    /// Whether the host validated Ultra 4:4:4 output.
    public var hostUltra444Validated: Bool?
    /// Pixel format emitted by the client decoder.
    public var clientDecoderOutputPixelFormat: String?
    /// Whether the client is using hardware video decoding.
    public var clientUsingHardwareDecoder: Bool?
    /// Worst host capture wall-clock frame gap, in milliseconds.
    public var hostCaptureWallClockGapWorstMs: Double?
    /// 95th percentile host capture wall-clock frame gap, in milliseconds.
    public var hostCaptureWallClockGapP95Ms: Double?
    /// 99th percentile host capture wall-clock frame gap, in milliseconds.
    public var hostCaptureWallClockGapP99Ms: Double?
    /// Worst host capture display-time frame gap, in milliseconds.
    public var hostCaptureDisplayTimeGapWorstMs: Double?
    /// 95th percentile host capture display-time frame gap, in milliseconds.
    public var hostCaptureDisplayTimeGapP95Ms: Double?
    /// 99th percentile host capture display-time frame gap, in milliseconds.
    public var hostCaptureDisplayTimeGapP99Ms: Double?
    /// Worst delivered-frame gap from host capture, in milliseconds.
    public var hostCaptureDeliveredFrameGapWorstMs: Double?
    /// 95th percentile delivered-frame gap from host capture, in milliseconds.
    public var hostCaptureDeliveredFrameGapP95Ms: Double?
    /// 99th percentile delivered-frame gap from host capture, in milliseconds.
    public var hostCaptureDeliveredFrameGapP99Ms: Double?
    /// 95th percentile host capture callback interval, in milliseconds.
    public var hostCaptureCallbackP95Ms: Double?
    /// 99th percentile host capture callback interval, in milliseconds.
    public var hostCaptureCallbackP99Ms: Double?
    /// Number of long frame gaps observed by host capture.
    public var hostCaptureLongFrameGapCount: UInt64?
    /// Number of host capture display-time drift events.
    public var hostCaptureDisplayTimeDriftCount: UInt64?
    /// Whether host capture timing appears suspicious for a virtual display.
    public var hostCaptureVirtualDisplayTimingSuspect: Bool?
    /// ScreenCaptureKit telemetry sample duration, in seconds.
    public var hostSCKSampleDurationSeconds: Double?
    /// Raw ScreenCaptureKit screen callback rate, in frames per second.
    public var hostRawScreenCallbackFPS: Double?
    /// Complete ScreenCaptureKit frame rate, in frames per second.
    public var hostCompleteFrameFPS: Double?
    /// Renderable ScreenCaptureKit frame rate, in frames per second.
    public var hostRenderableFrameFPS: Double?
    /// Cadence-admitted ScreenCaptureKit frame rate, in frames per second.
    public var hostCadenceAdmittedFrameFPS: Double?
    /// Complete-frame ScreenCaptureKit rate used for post-capture validation.
    public var hostObservedSCKFPS: Double?
    /// Raw ScreenCaptureKit screen callback count in the host sample window.
    public var hostRawScreenCallbackCount: UInt64?
    /// Complete ScreenCaptureKit frame count in the host sample window.
    public var hostCompleteFrameCount: UInt64?
    /// Renderable ScreenCaptureKit frame count in the host sample window.
    public var hostRenderableFrameCount: UInt64?
    /// Idle ScreenCaptureKit frame count in the host sample window.
    public var hostIdleFrameCount: UInt64?
    /// Cadence-admitted ScreenCaptureKit frame count in the host sample window.
    public var hostCadenceAdmittedFrameCount: UInt64?
    /// Whether host capture is paced by display refresh cadence.
    public var hostCaptureUsesDisplayRefreshCadence: Bool?
    /// Whether host capture uses the native refresh rate as its minimum frame interval.
    public var hostCaptureUsesNativeRefreshMinimumFrameInterval: Bool?
    /// Minimum frame interval rate reported by host capture, in hertz.
    public var hostCaptureMinimumFrameIntervalRate: Int?
    /// Display refresh rate reported by host capture, in hertz.
    public var hostCaptureDisplayRefreshRate: Int?
    /// Identifier of the host virtual display used for capture.
    public var hostVirtualDisplayID: UInt32?
    /// Refresh rate of the host virtual display, in hertz.
    public var hostVirtualDisplayRefreshRate: Double?
    /// Scale factor of the host virtual display.
    public var hostVirtualDisplayScaleFactor: Double?
    /// Bytes currently queued for host packet sending.
    public var hostSendQueueBytes: Int?
    /// Average delay before host packet sending starts, in milliseconds.
    public var hostSendStartDelayAverageMs: Double?
    package var hostSendStartDelayMaxMs: Double?
    /// Average host packet send completion duration, in milliseconds.
    public var hostSendCompletionAverageMs: Double?
    package var hostSendCompletionMaxMs: Double?
    /// Average packet-pacer sleep duration on the host, in milliseconds.
    public var hostPacketPacerAverageSleepMs: Double?
    /// Total packet-pacer sleep time on the host, in milliseconds.
    public var hostPacketPacerTotalSleepMs: Int?
    /// Maximum packet-pacer sleep duration on the host, in milliseconds.
    public var hostPacketPacerMaxSleepMs: Int?
    /// Maximum per-frame packet-pacer sleep duration on the host, in milliseconds.
    public var hostPacketPacerFrameMaxSleepMs: Int?
    /// Host-selected maximum media packet size, including Mirage headers.
    public var hostMediaMaxPacketSize: Int?
    /// Host-selected Loom media send profile.
    public var hostMediaSendProfile: String?
    /// Number of stale packets dropped by the host sender.
    public var hostStalePacketDrops: UInt64?
    package var hostSenderLocalDeadlineDrops: UInt64?
    /// Number of packets dropped because their stream generation was aborted.
    public var hostGenerationAbortDrops: UInt64?
    /// Number of non-keyframes dropped while waiting for a keyframe.
    public var hostNonKeyframeHoldDrops: UInt64?
    /// Whether this snapshot includes host-side metrics.
    public var hasHostMetrics: Bool

    /// Creates a metrics snapshot with client presentation data and optional host telemetry.
    public init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        clientReceivedWorstGapMs: Double = 0,
        clientReceivedFrameIntervalP95Ms: Double = 0,
        clientReceivedFrameIntervalP99Ms: Double = 0,
        clientDisplayTickFPS: Double = 0,
        clientSubmitAttemptFPS: Double = 0,
        clientLayerAcceptedFPS: Double = 0,
        clientPresentedFPS: Double = 0,
        submittedFPS: Double = 0,
        uniqueSubmittedFPS: Double = 0,
        pendingFrameCount: Int = 0,
        clientPendingFrameAgeMs: Double = 0,
        clientSmoothestDisplayDebtMs: Double = 0,
        clientSmoothestDisplayDebtCapMs: Double = 0,
        clientSmoothestTargetDelayMs: Double = 0,
        clientSmoothestUnderflowCount: UInt64 = 0,
        clientOverwrittenPendingFrames: UInt64 = 0,
        clientSmoothestQueueDrops: UInt64 = 0,
        clientSmoothestDisplayDebtDrops: UInt64 = 0,
        clientSmoothestFifoResetCount: UInt64 = 0,
        clientSmoothestDepthDrops: UInt64 = 0,
        clientSmoothestAgeDrops: UInt64 = 0,
        clientSmoothestDropsUnder100ms: UInt64 = 0,
        clientSmoothestDroppedFrameAgeMaxMs: Double = 0,
        clientLateFrameDrops: UInt64 = 0,
        clientDisplayLayerNotReadyCount: UInt64 = 0,
        clientRepeatedFrameCount: UInt64 = 0,
        clientMissedVSyncCount: UInt64 = 0,
        clientDisplayTickIntervalP95Ms: Double = 0,
        clientDisplayTickIntervalP99Ms: Double = 0,
        clientPlayoutDelayFrames: Int = 0,
        clientPresentationStallCount: UInt64 = 0,
        clientWorstPresentationGapMs: Double = 0,
        clientFrameIntervalP95Ms: Double = 0,
        clientFrameIntervalP99Ms: Double = 0,
        decodeHealthy: Bool = true,
        clientDroppedFrames: UInt64 = 0,
        clientReassemblerPendingFrameCount: Int = 0,
        clientReassemblerPendingKeyframeCount: Int = 0,
        clientReassemblerPendingBytes: Int = 0,
        clientFrameBufferPoolRetainedBytes: Int = 0,
        clientReassemblerBudgetEvictions: UInt64 = 0,
        clientReassemblerIncompleteFrameTimeouts: UInt64 = 0,
        clientReassemblerIncompleteFrameNoProgressTimeouts: UInt64 = 0,
        clientReassemblerIncompleteFrameLifetimeTimeouts: UInt64 = 0,
        clientReassemblerMissingFragmentTimeouts: UInt64 = 0,
        clientReassemblerForwardGapTimeouts: UInt64 = 0,
        clientPFrameCompletionLatencyP50Ms: Double = 0,
        clientPFrameCompletionLatencyP95Ms: Double = 0,
        clientPFrameCompletionLatencyMaxMs: Double = 0,
        clientLatePFrameCompletionCount: UInt64 = 0,
        hostEncodedFPS: Double = 0,
        hostIdleFPS: Double = 0,
        hostDroppedFrames: UInt64 = 0,
        hostActiveQuality: Double = 0,
        hostTargetFrameRate: Int = 0,
        hostEnteredBitrate: Int? = nil,
        hostCurrentBitrate: Int? = nil,
        hostEncoderRequestedBitrateBps: Int? = nil,
        hostEncoderActualBitrateBps: Int? = nil,
        hostEncoderActualWindowMs: Int? = nil,
        hostEncodedFrameBytesP50: Int? = nil,
        hostEncodedFrameBytesP95: Int? = nil,
        hostEncodedFrameBytesP99: Int? = nil,
        hostEncodedKeyframeBytesP50: Int? = nil,
        hostEncodedKeyframeBytesP95: Int? = nil,
        hostEncodedKeyframeBytesP99: Int? = nil,
        hostEncoderRateControlStrategy: MirageEncoderRateControlStrategy? = nil,
        hostEncoderRateLimitBytes: Int? = nil,
        hostEncoderRateLimitWindowMs: Int? = nil,
        hostEffectiveStreamScale: Double? = nil,
        hostAdaptiveStreamScaleReason: String? = nil,
        hostEncoderRetuneValidationResult: String? = nil,
        hostEncoderKeyframeForRetuneCount: UInt64? = nil,
        hostEncoderSessionRecreationCount: UInt64? = nil,
        hostRequestedTargetBitrate: Int? = nil,
        hostBitrateAdaptationCeiling: Int? = nil,
        hostStartupBitrate: Int? = nil,
        hostRealtimeBitrateCeiling: Int? = nil,
        hostRealtimePressureState: String? = nil,
        hostRealtimePressureReason: String? = nil,
        hostCaptureAdmissionDrops: UInt64? = nil,
        hostFrameBudgetMs: Double? = nil,
        hostAverageEncodeMs: Double? = nil,
        hostCaptureIngressFPS: Double? = nil,
        hostCaptureFPS: Double? = nil,
        hostEncodeAttemptFPS: Double? = nil,
        hostUsingHardwareEncoder: Bool? = nil,
        hostEncoderGPURegistryID: UInt64? = nil,
        hostEncodedWidth: Int? = nil,
        hostEncodedHeight: Int? = nil,
        hostCapturePixelFormat: String? = nil,
        hostCaptureColorPrimaries: String? = nil,
        hostEncoderPixelFormat: String? = nil,
        hostEncoderChromaSampling: String? = nil,
        hostEncoderProfile: String? = nil,
        hostEncoderColorPrimaries: String? = nil,
        hostEncoderTransferFunction: String? = nil,
        hostEncoderYCbCrMatrix: String? = nil,
        hostDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus? = nil,
        hostTenBitDisplayP3Validated: Bool? = nil,
        hostUltra444Validated: Bool? = nil,
        clientDecoderOutputPixelFormat: String? = nil,
        clientUsingHardwareDecoder: Bool? = nil,
        hasHostMetrics: Bool = false
    ) {
        self.decodedFPS = decodedFPS
        self.receivedFPS = receivedFPS
        self.clientReceivedWorstGapMs = clientReceivedWorstGapMs
        self.clientReceivedFrameIntervalP95Ms = clientReceivedFrameIntervalP95Ms
        self.clientReceivedFrameIntervalP99Ms = clientReceivedFrameIntervalP99Ms
        self.clientDisplayTickFPS = clientDisplayTickFPS
        self.clientSubmitAttemptFPS = clientSubmitAttemptFPS
        self.clientLayerAcceptedFPS = clientLayerAcceptedFPS
        self.clientPresentedFPS = clientPresentedFPS
        self.submittedFPS = submittedFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS
        self.pendingFrameCount = pendingFrameCount
        self.clientPendingFrameAgeMs = clientPendingFrameAgeMs
        self.clientSmoothestDisplayDebtMs = max(0, clientSmoothestDisplayDebtMs)
        self.clientSmoothestDisplayDebtCapMs = max(0, clientSmoothestDisplayDebtCapMs)
        self.clientSmoothestTargetDelayMs = max(0, clientSmoothestTargetDelayMs)
        self.clientSmoothestUnderflowCount = clientSmoothestUnderflowCount
        self.clientOverwrittenPendingFrames = clientOverwrittenPendingFrames
        self.clientSmoothestQueueDrops = clientSmoothestQueueDrops
        self.clientSmoothestDisplayDebtDrops = clientSmoothestDisplayDebtDrops
        self.clientSmoothestFifoResetCount = clientSmoothestFifoResetCount
        self.clientSmoothestDepthDrops = clientSmoothestDepthDrops
        self.clientSmoothestAgeDrops = clientSmoothestAgeDrops
        self.clientSmoothestDropsUnder100ms = clientSmoothestDropsUnder100ms
        self.clientSmoothestDroppedFrameAgeMaxMs = clientSmoothestDroppedFrameAgeMaxMs
        self.clientLateFrameDrops = clientLateFrameDrops
        self.clientDisplayLayerNotReadyCount = clientDisplayLayerNotReadyCount
        self.clientRepeatedFrameCount = clientRepeatedFrameCount
        clientRepeatedDeliveredSourceFrameCountStorage = 0
        self.clientMissedVSyncCount = clientMissedVSyncCount
        self.clientDisplayTickIntervalP95Ms = clientDisplayTickIntervalP95Ms
        self.clientDisplayTickIntervalP99Ms = clientDisplayTickIntervalP99Ms
        self.clientPlayoutDelayFrames = clientPlayoutDelayFrames
        self.clientPresentationStallCount = clientPresentationStallCount
        self.clientWorstPresentationGapMs = clientWorstPresentationGapMs
        self.clientFrameIntervalP95Ms = clientFrameIntervalP95Ms
        self.clientFrameIntervalP99Ms = clientFrameIntervalP99Ms
        self.decodeHealthy = decodeHealthy
        self.clientDroppedFrames = clientDroppedFrames
        self.clientReassemblerPendingFrameCount = clientReassemblerPendingFrameCount
        self.clientReassemblerPendingKeyframeCount = clientReassemblerPendingKeyframeCount
        self.clientReassemblerPendingBytes = clientReassemblerPendingBytes
        self.clientFrameBufferPoolRetainedBytes = clientFrameBufferPoolRetainedBytes
        self.clientReassemblerBudgetEvictions = clientReassemblerBudgetEvictions
        self.clientReassemblerIncompleteFrameTimeouts = clientReassemblerIncompleteFrameTimeouts
        self.clientReassemblerIncompleteFrameNoProgressTimeouts = clientReassemblerIncompleteFrameNoProgressTimeouts
        self.clientReassemblerIncompleteFrameLifetimeTimeouts = clientReassemblerIncompleteFrameLifetimeTimeouts
        self.clientReassemblerMissingFragmentTimeouts = clientReassemblerMissingFragmentTimeouts
        self.clientReassemblerForwardGapTimeouts = clientReassemblerForwardGapTimeouts
        self.clientPFrameCompletionLatencyP50Ms = max(0, clientPFrameCompletionLatencyP50Ms)
        self.clientPFrameCompletionLatencyP95Ms = max(0, clientPFrameCompletionLatencyP95Ms)
        self.clientPFrameCompletionLatencyMaxMs = max(0, clientPFrameCompletionLatencyMaxMs)
        self.clientLatePFrameCompletionCount = clientLatePFrameCompletionCount
        clientDecodeBacklogFrameCountStorage = 0
        self.hostEncodedFPS = hostEncodedFPS
        self.hostIdleFPS = hostIdleFPS
        self.hostDroppedFrames = hostDroppedFrames
        self.hostActiveQuality = hostActiveQuality
        self.hostTargetFrameRate = hostTargetFrameRate
        self.hostEnteredBitrate = hostEnteredBitrate
        self.hostCurrentBitrate = hostCurrentBitrate
        self.hostEncoderRequestedBitrateBps = hostEncoderRequestedBitrateBps
        self.hostEncoderActualBitrateBps = hostEncoderActualBitrateBps
        self.hostEncoderActualWindowMs = hostEncoderActualWindowMs
        self.hostEncodedFrameBytesP50 = hostEncodedFrameBytesP50
        self.hostEncodedFrameBytesP95 = hostEncodedFrameBytesP95
        self.hostEncodedFrameBytesP99 = hostEncodedFrameBytesP99
        self.hostEncodedKeyframeBytesP50 = hostEncodedKeyframeBytesP50
        self.hostEncodedKeyframeBytesP95 = hostEncodedKeyframeBytesP95
        self.hostEncodedKeyframeBytesP99 = hostEncodedKeyframeBytesP99
        self.hostEncoderRateControlStrategy = hostEncoderRateControlStrategy
        self.hostEncoderRateLimitBytes = hostEncoderRateLimitBytes
        self.hostEncoderRateLimitWindowMs = hostEncoderRateLimitWindowMs
        self.hostEffectiveStreamScale = hostEffectiveStreamScale
        self.hostAdaptiveStreamScaleReason = hostAdaptiveStreamScaleReason
        self.hostEncoderRetuneValidationResult = hostEncoderRetuneValidationResult
        self.hostEncoderKeyframeForRetuneCount = hostEncoderKeyframeForRetuneCount
        self.hostEncoderSessionRecreationCount = hostEncoderSessionRecreationCount
        self.hostRequestedTargetBitrate = hostRequestedTargetBitrate
        self.hostBitrateAdaptationCeiling = hostBitrateAdaptationCeiling
        self.hostStartupBitrate = hostStartupBitrate
        self.hostRealtimeBitrateCeiling = hostRealtimeBitrateCeiling
        self.hostRealtimePressureState = hostRealtimePressureState
        self.hostRealtimePressureReason = hostRealtimePressureReason
        self.hostCaptureAdmissionDrops = hostCaptureAdmissionDrops
        self.hostFrameBudgetMs = hostFrameBudgetMs
        self.hostAverageEncodeMs = hostAverageEncodeMs
        self.hostCaptureIngressFPS = hostCaptureIngressFPS
        self.hostCaptureFPS = hostCaptureFPS
        self.hostEncodeAttemptFPS = hostEncodeAttemptFPS
        self.hostUsingHardwareEncoder = hostUsingHardwareEncoder
        self.hostEncoderGPURegistryID = hostEncoderGPURegistryID
        self.hostEncodedWidth = hostEncodedWidth
        self.hostEncodedHeight = hostEncodedHeight
        self.hostCapturePixelFormat = hostCapturePixelFormat
        self.hostCaptureColorPrimaries = hostCaptureColorPrimaries
        self.hostEncoderPixelFormat = hostEncoderPixelFormat
        self.hostEncoderChromaSampling = hostEncoderChromaSampling
        self.hostEncoderProfile = hostEncoderProfile
        self.hostEncoderColorPrimaries = hostEncoderColorPrimaries
        self.hostEncoderTransferFunction = hostEncoderTransferFunction
        self.hostEncoderYCbCrMatrix = hostEncoderYCbCrMatrix
        self.hostDisplayP3CoverageStatus = hostDisplayP3CoverageStatus
        self.hostTenBitDisplayP3Validated = hostTenBitDisplayP3Validated
        self.hostUltra444Validated = hostUltra444Validated
        self.clientDecoderOutputPixelFormat = clientDecoderOutputPixelFormat
        self.clientUsingHardwareDecoder = clientUsingHardwareDecoder
        hostSCKSampleDurationSeconds = nil
        hostRawScreenCallbackFPS = nil
        hostCompleteFrameFPS = nil
        hostRenderableFrameFPS = nil
        hostCadenceAdmittedFrameFPS = nil
        hostObservedSCKFPS = nil
        hostRawScreenCallbackCount = nil
        hostCompleteFrameCount = nil
        hostRenderableFrameCount = nil
        hostIdleFrameCount = nil
        hostCadenceAdmittedFrameCount = nil
        hostMediaMaxPacketSize = nil
        hostMediaSendProfile = nil
        self.hasHostMetrics = hasHostMetrics
    }

    /// Applies host capture cadence telemetry while preserving existing client and encoder metrics.
    mutating func applyHostCaptureCadence(_ cadence: StreamCaptureCadenceMetrics?) {
        hostCaptureWallClockGapWorstMs = cadence?.wallClockGapWorstMs
        hostCaptureWallClockGapP95Ms = cadence?.wallClockGapP95Ms
        hostCaptureWallClockGapP99Ms = cadence?.wallClockGapP99Ms
        hostCaptureDisplayTimeGapWorstMs = cadence?.displayTimeGapWorstMs
        hostCaptureDisplayTimeGapP95Ms = cadence?.displayTimeGapP95Ms
        hostCaptureDisplayTimeGapP99Ms = cadence?.displayTimeGapP99Ms
        hostCaptureDeliveredFrameGapWorstMs = cadence?.deliveredFrameGapWorstMs
        hostCaptureDeliveredFrameGapP95Ms = cadence?.deliveredFrameGapP95Ms
        hostCaptureDeliveredFrameGapP99Ms = cadence?.deliveredFrameGapP99Ms
        hostCaptureCallbackP95Ms = cadence?.callbackDurationP95Ms
        hostCaptureCallbackP99Ms = cadence?.callbackDurationP99Ms
        hostCaptureLongFrameGapCount = cadence?.longFrameGapCount
        hostCaptureDisplayTimeDriftCount = cadence?.displayTimeDriftCount
        hostCaptureVirtualDisplayTimingSuspect = cadence?.virtualDisplayTimingSuspect
        hostSCKSampleDurationSeconds = cadence?.sampleDurationSeconds
        hostRawScreenCallbackFPS = cadence?.rawScreenCallbackFPS
        hostCompleteFrameFPS = cadence?.completeFrameFPS
        hostRenderableFrameFPS = cadence?.renderableFrameFPS
        hostCadenceAdmittedFrameFPS = cadence?.cadenceAdmittedFrameFPS
        hostObservedSCKFPS = cadence?.observedSCKFPS
        hostRawScreenCallbackCount = cadence?.rawScreenCallbackCount
        hostCompleteFrameCount = cadence?.completeFrameCount
        hostRenderableFrameCount = cadence?.renderableFrameCount
        hostIdleFrameCount = cadence?.idleFrameCount
        hostCadenceAdmittedFrameCount = cadence?.cadenceAdmittedFrameCount
        hostCaptureUsesDisplayRefreshCadence = cadence?.usesDisplayRefreshCadence
        hostCaptureUsesNativeRefreshMinimumFrameInterval = cadence?.usesNativeRefreshMinimumFrameInterval
        hostCaptureMinimumFrameIntervalRate = cadence?.minimumFrameIntervalRate
        hostCaptureDisplayRefreshRate = cadence?.displayRefreshRate
        hostVirtualDisplayID = cadence?.virtualDisplayID
        hostVirtualDisplayRefreshRate = cadence?.virtualDisplayRefreshRate
        hostVirtualDisplayScaleFactor = cadence?.virtualDisplayScaleFactor
    }
}

public extension MirageClientMetricsSnapshot {
    init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        layerEnqueueFPS: Double = 0,
        uniqueLayerEnqueueFPS: Double = 0,
        clientVisibleFrameFPS: Double = 0,
        clientVisibleFrameCadenceKnown: Bool = false,
        pendingFrameCount: Int = 0,
        decodeHealthy: Bool = true,
        hostEncodedFPS: Double = 0,
        hostActiveQuality: Double = 0,
        hostTargetFrameRate: Int = 0,
        hostFrameBudgetMs: Double? = nil,
        hostAverageEncodeMs: Double? = nil,
        hostCaptureIngressFPS: Double? = nil,
        hostCaptureFPS: Double? = nil,
        hostEncodeAttemptFPS: Double? = nil,
        hasHostMetrics: Bool = false
    ) {
        self.init(
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            clientSubmitAttemptFPS: layerEnqueueFPS,
            clientLayerAcceptedFPS: layerEnqueueFPS,
            clientPresentedFPS: clientVisibleFrameFPS,
            submittedFPS: layerEnqueueFPS,
            uniqueSubmittedFPS: uniqueLayerEnqueueFPS,
            pendingFrameCount: pendingFrameCount,
            decodeHealthy: decodeHealthy,
            hostEncodedFPS: hostEncodedFPS,
            hostActiveQuality: hostActiveQuality,
            hostTargetFrameRate: hostTargetFrameRate,
            hostFrameBudgetMs: hostFrameBudgetMs,
            hostAverageEncodeMs: hostAverageEncodeMs,
            hostCaptureIngressFPS: hostCaptureIngressFPS,
            hostCaptureFPS: hostCaptureFPS,
            hostEncodeAttemptFPS: hostEncodeAttemptFPS,
            hasHostMetrics: hasHostMetrics
        )
        self.clientVisibleFrameCadenceKnown = clientVisibleFrameCadenceKnown
    }

    var layerEnqueueFPS: Double {
        get { submittedFPS }
        set {
            submittedFPS = newValue
            clientSubmitAttemptFPS = newValue
            clientLayerAcceptedFPS = newValue
        }
    }

    var uniqueLayerEnqueueFPS: Double {
        get { uniqueSubmittedFPS }
        set { uniqueSubmittedFPS = newValue }
    }

    var clientRendererEnqueueFPS: Double {
        get { submittedFPS }
        set { layerEnqueueFPS = newValue }
    }

    var clientUniqueRendererEnqueueFPS: Double {
        get { uniqueSubmittedFPS }
        set { uniqueSubmittedFPS = newValue }
    }

    var clientVisibleFrameFPS: Double {
        get { clientPresentedFPS }
        set { clientPresentedFPS = newValue }
    }

    var clientUniqueDeliveredSourceFrameFPS: Double {
        get { clientPresentedFPS }
        set { clientPresentedFPS = newValue }
    }

    var clientVisibleFrameCadenceKnown: Bool {
        get { clientPresentedFPS > 0 || uniqueSubmittedFPS > 0 }
        set {
            if !newValue {
                clientPresentedFPS = 0
            }
        }
    }

    var clientDeliveredSourceFrameCadenceKnown: Bool {
        get { clientVisibleFrameCadenceKnown }
        set { clientVisibleFrameCadenceKnown = newValue }
    }

    var clientVisibleWorstPresentationGapMs: Double {
        get { clientWorstPresentationGapMs }
        set { clientWorstPresentationGapMs = newValue }
    }

    var clientVisibleFrameIntervalP99Ms: Double {
        get { clientFrameIntervalP99Ms }
        set { clientFrameIntervalP99Ms = newValue }
    }

    var clientRepeatedDeliveredSourceFrameCount: UInt64 {
        get { clientRepeatedDeliveredSourceFrameCountStorage }
        set { clientRepeatedDeliveredSourceFrameCountStorage = newValue }
    }

    var clientRepeatedSourceFrameCount: UInt64 {
        get { clientRepeatedDeliveredSourceFrameCountStorage }
        set { clientRepeatedDeliveredSourceFrameCountStorage = newValue }
    }

    var clientRepeatedDisplayTickFrameCount: UInt64 {
        get { clientRepeatedFrameCount }
        set { clientRepeatedFrameCount = newValue }
    }

    var clientDisplayRefreshTickFPS: Double {
        get { clientDisplayTickFPS }
        set { clientDisplayTickFPS = newValue }
    }

    var clientRenderQueueBacklogFrames: Int {
        get { pendingFrameCount }
        set { pendingFrameCount = newValue }
    }

    var clientDecodeQueueBacklogFrames: Int {
        get { clientDecodeBacklogFrameCountStorage }
        set { clientDecodeBacklogFrameCountStorage = newValue }
    }

    var clientUnsubmittedPendingFrameCount: Int {
        get { pendingFrameCount }
        set { pendingFrameCount = newValue }
    }

    var clientDecodeBacklogFrames: Int {
        get { clientDecodeBacklogFrameCountStorage }
        set { clientDecodeBacklogFrameCountStorage = newValue }
    }

    var clientDecodeSubmissionInFlightCount: Int {
        get { 0 }
        set { _ = newValue }
    }

    var clientDecodeSubmissionLimit: Int {
        get { 0 }
        set { _ = newValue }
    }

    var clientIncomingMediaBatchIntervalMaxMs: Double {
        get { clientReceivedWorstGapMs }
        set { clientReceivedWorstGapMs = newValue }
    }
}
