//
//  MirageClientMetricsSnapshot.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia

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
    /// 95th percentile raw ingress jitter above the source frame budget, in milliseconds.
    public var clientReceiverIngressJitterP95Ms: Double
    /// 99th percentile raw ingress jitter above the source frame budget, in milliseconds.
    public var clientReceiverIngressJitterP99Ms: Double
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
    /// Number of display ticks where a pending decoded frame was not ready for playout.
    public var clientPendingFrameNotReadyDisplayTickCount: UInt64
    /// Number of repeated-frame presentations used to preserve cadence.
    public var clientRepeatedFrameCount: UInt64
    /// Number of repeated delivered source frames used by the presentation pipeline.
    public var clientRepeatedDeliveredSourceFrameCount: UInt64
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
    /// Number of timed-out frames that were missing one or more media fragments.
    public var clientReassemblerIncompleteFrameTimeouts: UInt64
    /// Number of incomplete frames that timed out after no fragment progress.
    public var clientReassemblerIncompleteFrameNoProgressTimeouts: UInt64
    /// Number of incomplete frames that reached the absolute lifetime cap.
    public var clientReassemblerIncompleteFrameLifetimeTimeouts: UInt64
    /// Number of media fragments missing from timed-out incomplete frames.
    public var clientReassemblerMissingFragmentTimeouts: UInt64
    /// Number of buffered forward gaps that reached the reorder timeout.
    public var clientReassemblerForwardGapTimeouts: UInt64
    /// Recent all-frame assembly latency p50, in milliseconds.
    public var clientFrameCompletionLatencyP50Ms: Double
    /// Recent all-frame assembly latency p95, in milliseconds.
    public var clientFrameCompletionLatencyP95Ms: Double
    /// Recent maximum all-frame assembly latency, in milliseconds.
    public var clientFrameCompletionLatencyMaxMs: Double
    /// Recent keyframe assembly latency p50, in milliseconds.
    public var clientKeyframeCompletionLatencyP50Ms: Double
    /// Recent keyframe assembly latency p95, in milliseconds.
    public var clientKeyframeCompletionLatencyP95Ms: Double
    /// Recent maximum keyframe assembly latency, in milliseconds.
    public var clientKeyframeCompletionLatencyMaxMs: Double
    /// Recent P-frame assembly latency p50, in milliseconds.
    public var clientPFrameCompletionLatencyP50Ms: Double
    /// Recent P-frame assembly latency p95, in milliseconds.
    public var clientPFrameCompletionLatencyP95Ms: Double
    /// Recent maximum P-frame assembly latency, in milliseconds.
    public var clientPFrameCompletionLatencyMaxMs: Double
    /// Recent P-frames whose assembly latency exceeded the late threshold.
    public var clientLatePFrameCompletionCount: UInt64
    /// Media fragments recovered by the client reassembler through FEC.
    public var clientReassemblerFECRecoveredFragmentCount: UInt64
    /// Number of decoded frames waiting behind the decode submission path.
    public var clientDecodeBacklogFrameCount: Int
    /// Frames encoded per second by the host encoder.
    public var hostEncodedFPS: Double
    /// Idle frames per second emitted by the host when no new capture content is available.
    public var hostIdleFPS: Double
    /// Total frames dropped by the host capture or encoding pipeline.
    public var hostDroppedFrames: UInt64
    /// Active host encoder quality value.
    public var hostActiveQuality: Double
    /// Latest quality value attached to a frame reserved for encoding/sending.
    public var hostLatestAppliedFrameQuality: Double?
    /// Latest bitrate target attached to a frame reserved for encoding/sending.
    public var hostLatestAppliedFrameBitrateTargetBps: Int?
    /// Latest sender pacing target attached to a frame reserved for encoding/sending.
    public var hostLatestAppliedFrameSenderPacingBps: Int?
    /// Latest adaptive frame intent attached to a frame reserved for encoding/sending.
    public var hostLatestAppliedFrameIntent: String?
    /// Latest frame-rate target attached to a frame reserved for encoding/sending.
    public var hostLatestAppliedFrameRate: Int?
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
    public var hostEncoderRateControlStrategy: MirageMedia.MirageEncoderRateControlStrategy?
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
    public var hostRealtimeControlRevision: Int?
    public var hostAdaptiveGovernorRevision: Int?
    public var hostAdaptiveGovernorDecisionID: UInt64?
    public var hostAdaptiveGovernorState: String?
    public var hostAdaptiveGovernorEvidenceClass: String?
    public var hostAdaptiveGovernorCause: String?
    public var hostAdaptiveGovernorSelectedLever: String?
    public var hostAdaptiveGovernorBlockedLeverReason: String?
    public var hostAdaptiveGovernorEvidenceSummary: String?
    /// Host-side realtime pressure reason.
    public var hostRealtimePressureReason: String?
    /// Host-side frame delivery class for the latest adaptive P-frame decision.
    public var hostRealtimeDeliveryMode: String?
    /// Host-computed bitrate required to carry the current P-frame quality, in bits per second.
    public var hostRealtimeRequiredBitrateForQualityBps: Int?
    /// Host-observed 95th percentile P-frame wire size for the current quality bucket, in bytes.
    public var hostRealtimeObservedPFrameWireBytesP95: Int?
    /// Host-side effective P-frame wire budget, in bytes per frame.
    public var hostRealtimeFrameBudgetBytes: Int?
    /// Host-side effective P-frame wire budget expressed as bitrate, in bits per second.
    public var hostRealtimeFrameBudgetBitrateBps: Int?
    /// Host-side AWDL media controller state.
    public var hostAwdlPolicyState: String?
    /// Host-side AWDL media controller trigger.
    public var hostAwdlPolicyTrigger: String?
    /// Host-side AWDL media controller selected adaptation lever.
    public var hostAwdlSelectedLever: String?
    /// Host-side AWDL playout target, in milliseconds.
    public var hostAwdlPlayoutDelayMs: Double?
    /// Host-side AWDL encoded resolution scale multiplier.
    public var hostAwdlResolutionScale: Double?
    /// Whether host-side AWDL quality reduction is currently permitted.
    public var hostAwdlQualityReductionAllowed: Bool?
    /// Host-side AWDL pacing budget, in bits per second.
    public var hostAwdlPacingBudgetBps: Int?
    /// Number of frames rejected by host capture admission control.
    public var hostCaptureAdmissionDrops: UInt64?
    /// Number of host frames skipped before encode due to transport admission throttling.
    public var hostTransportAdmissionSkips: UInt64?
    /// Current host-side pre-encode transport admission mode.
    public var hostTransportAdmissionMode: String?
    /// Host-side reason for pre-encode transport admission throttling.
    public var hostTransportAdmissionReason: String?
    /// Host-side evidence summary for pre-encode transport admission throttling.
    public var hostTransportAdmissionEvidence: String?
    /// Minimum interval between admitted P-frames while transport admission throttling is active.
    public var hostTransportAdmissionMinimumFrameIntervalMs: Double?
    /// Remaining hold time for sustained host transport admission pressure.
    public var hostTransportAdmissionActiveHoldMs: Double?
    /// Current skip-burst count for host transport admission throttling.
    public var hostTransportAdmissionSkipBurstCount: UInt64?
    /// Number of host frames skipped before encode to avoid stale high-refresh catch-up bursts.
    public var hostHighRefreshPacingSkips: UInt64?
    /// Current host-side high-refresh pacing mode.
    public var hostHighRefreshPacingMode: String?
    /// Host-side reason for high-refresh pacing skip admission.
    public var hostHighRefreshPacingReason: String?
    /// Protected frame-rate floor while host high-refresh pacing is active.
    public var hostHighRefreshPacingFloorFPS: Int?
    /// Number of host frames skipped before encode to preserve readability near the runtime quality floor.
    public var hostReadabilityProtectionSkips: UInt64?
    /// Current host-side readability protection mode.
    public var hostReadabilityProtectionMode: String?
    /// Host-side reason for readability protection skip admission.
    public var hostReadabilityProtectionReason: String?
    /// Target admitted frame rate while host readability protection is active.
    public var hostReadabilityProtectionAdmitTargetFPS: Int?
    /// Host-side runtime quality floor.
    public var hostRuntimeQualityFloor: Double?
    /// Host-side runtime quality ceiling.
    public var hostRuntimeQualityCeiling: Double?
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
    public var hostDisplayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus?
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
    /// Loom queued-unreliable drop counts reported by the host sender.
    public var hostQueuedUnreliableDropCounts: MirageHostQueuedUnreliableDropCounts?
    /// Pending packets in the selected host Loom queued-unreliable profile.
    public var hostQueuedUnreliablePendingPackets: Int?
    /// Packets submitted to Network.framework but not completed by the selected host Loom profile.
    public var hostQueuedUnreliableOutstandingPackets: Int?
    /// Bytes retained by the selected host Loom queued-unreliable profile.
    public var hostQueuedUnreliableQueuedBytes: Int?
    /// Maximum pending packet count in the selected host Loom profile during the sample.
    public var hostQueuedUnreliablePendingPacketMax: Int?
    /// Maximum outstanding packet count in the selected host Loom profile during the sample.
    public var hostQueuedUnreliableOutstandingPacketMax: Int?
    /// Maximum retained bytes in the selected host Loom profile during the sample.
    public var hostQueuedUnreliableQueuedBytesMax: Int?
    /// Packets enqueued into the selected host Loom profile during the sample.
    public var hostQueuedUnreliableEnqueuedCount: UInt64?
    /// Packets started by the selected host Loom profile during the sample.
    public var hostQueuedUnreliableSentCount: UInt64?
    /// Packets completed by the selected host Loom profile during the sample.
    public var hostQueuedUnreliableCompletedCount: UInt64?
    /// Packets dropped by the selected host Loom profile during the sample.
    public var hostQueuedUnreliableDroppedCount: UInt64?
    /// Send errors observed by the selected host Loom profile during the sample.
    public var hostQueuedUnreliableErrorCount: UInt64?
    /// 50th percentile host Loom queued-unreliable dwell time, in milliseconds.
    public var hostQueuedUnreliableQueueDwellP50Ms: Double?
    /// 95th percentile host Loom queued-unreliable dwell time, in milliseconds.
    public var hostQueuedUnreliableQueueDwellP95Ms: Double?
    /// 99th percentile host Loom queued-unreliable dwell time, in milliseconds.
    public var hostQueuedUnreliableQueueDwellP99Ms: Double?
    /// 50th percentile gap between host Loom queued-unreliable send starts, in milliseconds.
    public var hostQueuedUnreliableSendGapP50Ms: Double?
    /// 95th percentile gap between host Loom queued-unreliable send starts, in milliseconds.
    public var hostQueuedUnreliableSendGapP95Ms: Double?
    /// 99th percentile gap between host Loom queued-unreliable send starts, in milliseconds.
    public var hostQueuedUnreliableSendGapP99Ms: Double?
    /// 50th percentile host Loom content-processed latency, in milliseconds.
    public var hostQueuedUnreliableContentProcessedP50Ms: Double?
    /// 95th percentile host Loom content-processed latency, in milliseconds.
    public var hostQueuedUnreliableContentProcessedP95Ms: Double?
    /// 99th percentile host Loom content-processed latency, in milliseconds.
    public var hostQueuedUnreliableContentProcessedP99Ms: Double?
    /// Whether this snapshot includes host-side metrics.
    public var hasHostMetrics: Bool

}

public extension MirageClientMetricsSnapshot {
    /// Total host-side drops attributable to transport-pressure shedding.
    var hostTransportPressureDropCount: UInt64 {
        (hostStalePacketDrops ?? 0) +
            (hostSenderLocalDeadlineDrops ?? 0) +
            (hostQueuedUnreliableDropCounts?.total ?? 0)
    }

    /// True only when the host is ACTIVELY constraining bitrate (pressured,
    /// severe, or recovery). A non-nil bitrate ceiling or the idle `observing`
    /// state — both reported from stream init onward — must not count, otherwise
    /// the client permanently delegates to the host budget and never probes the
    /// bitrate upward. The string values mirror the host `PressureState` enum.
    var hostRealtimeBudgetIsActivelyThrottling: Bool {
        switch hostRealtimePressureState {
        case "pressured", "severe", "recovery":
            return true
        default:
            return false
        }
    }
}
