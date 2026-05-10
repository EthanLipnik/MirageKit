//
//  MirageClientMetricsStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

/// Thread-safe metrics store for client stream telemetry.
public struct MirageClientMetricsSnapshot: Sendable, Equatable {
    public var decodedFPS: Double
    public var receivedFPS: Double
    public var clientDecodedWorstGapMs: Double
    public var clientDecodedFrameIntervalP95Ms: Double
    public var clientDecodedFrameIntervalP99Ms: Double
    public var clientReceivedWorstGapMs: Double
    public var clientReceivedFrameIntervalP95Ms: Double
    public var clientReceivedFrameIntervalP99Ms: Double
    public var clientLoomStreamDeliveryFPS: Double
    public var clientLoomStreamDeliveryGapMaxMs: Double
    public var clientRawMediaPacketIngressFPS: Double
    public var clientIncomingMediaBatchFPS: Double
    public var clientIncomingMediaBatchIntervalP95Ms: Double
    public var clientIncomingMediaBatchIntervalP99Ms: Double
    public var clientIncomingMediaBatchIntervalMaxMs: Double
    public var clientIncomingMediaBatchMaxSize: Int
    public var clientIncomingMediaBatchAverageSize: Double
    public var clientVideoIngressQueuedBatchCount: Int
    public var clientVideoIngressQueuedPacketCount: Int
    public var clientVideoIngressQueueAgeMaxMs: Double
    public var clientVideoIngressStalePacketDropCount: UInt64
    public var clientVideoIngressProcessedPacketCount: UInt64
    public var clientVideoIngressProcessorWakeDelayMaxMs: Double
    public var clientAcceptedMediaMaxPacketSize: Int?
    public var clientMediaPayloadEncryptionEnabled: Bool?
    public var clientRenderStoreEnqueueFPS: Double
    public var clientDisplayLinkCallbackFPS: Double
    public var clientDisplayTickWorkerFPS: Double
    public var clientDisplayTickMainRelayFPS: Double
    public var clientDisplayTickFPS: Double
    public var clientPresentationPassFPS: Double
    public var clientPresentationEligibleFPS: Double
    public var clientSubmitAttemptFPS: Double
    public var layerEnqueueFPS: Double
    public var uniqueLayerEnqueueFPS: Double
    public var clientVisibleFrameFPS: Double
    public var clientVisibleFrameCadenceKnown: Bool
    public var clientVisiblePresentationStallCount: UInt64
    public var clientVisibleWorstPresentationGapMs: Double
    public var clientVisibleFrameIntervalP95Ms: Double
    public var clientVisibleFrameIntervalP99Ms: Double
    public var clientVisibleFrameIntervalMaxMs: Double
    public var clientRepeatedSourceFrameCount: UInt64
    public var clientFramesSubmittedPerPassAverage: Double
    public var clientFramesSubmittedPerPassMax: UInt64
    public var pendingFrameCount: Int
    public var clientUnsubmittedPendingFrameCount: Int
    public var clientRetainedSubmittedFrameCount: Int
    public var clientPendingFrameAgeMs: Double
    public var clientOldestUnsubmittedAgeMs: Double
    public var clientNewestUnsubmittedAgeMs: Double
    public var clientOverwrittenPendingFrames: UInt64
    public var clientRenderStoreOverwriteFPS: Double
    public var clientLowestLatencyFreshBacklogDrops: UInt64
    public var clientLateFrameDrops: UInt64
    public internal(set) var clientCoalescedBeforeSubmitCount: UInt64
    package var clientDuplicateRemoteTimestampCount: UInt64
    package var clientCorrectedStreamTimestampCount: UInt64
    public var clientDisplayLayerNotReadyCount: UInt64
    public var clientSampleBufferRendererNotReadyCount: UInt64
    public var clientDisplayImmediatelySubmittedCount: UInt64
    public var clientRendererReadyDrainPassCount: UInt64
    public var clientRendererReadyDrainSubmittedCount: UInt64
    public var clientRendererReadyRearmCount: UInt64
    public var clientRepeatedFrameCount: UInt64
    public var clientDisplayTickNoFrameCount: UInt64
    public var clientTickNoEligibleFrameCount: UInt64
    public var clientFrameArrivedAfterNoFrameTickCount: UInt64
    public var clientFrameArrivalFallbackCount: UInt64
    public var clientFrameArrivalFallbackScheduledCount: UInt64
    public var clientFrameArrivalFallbackSubmittedCount: UInt64
    public var clientNoFrameTickToFrameArrivalMaxMs: Double
    public var clientMissedVSyncCount: UInt64
    public var clientSmoothestOneFrameHoldCount: UInt64
    public var clientDisplayCadenceBelowSourceCount: UInt64
    public var clientDisplayTickIntervalP95Ms: Double
    public var clientDisplayTickIntervalP99Ms: Double
    public var clientPlayoutDelayFrames: Int
    public var clientPresentationStallCount: UInt64
    public var clientWorstPresentationGapMs: Double
    public var clientFrameIntervalP95Ms: Double
    public var clientFrameIntervalP99Ms: Double
    public var clientFrameIntervalMaxMs: Double
    public var clientDisplayTickIntervalMaxMs: Double
    public var clientDisplayTickMainDelayMaxMs: Double
    public var clientRenderWorkerSubmitDelayMaxMs: Double
    public internal(set) var clientAudioStaleVideoGateCount: UInt64
    public internal(set) var clientAudioStaleVideoSoftHoldCount: UInt64
    public internal(set) var clientAudioStaleVideoConfirmedGateCount: UInt64
    public internal(set) var clientAudioStaleVideoMaxSnapshotAgeMs: Double
    public internal(set) var clientRenderStoreClearCount: UInt64
    public internal(set) var clientRenderGenerationBumpCount: UInt64
    public internal(set) var clientRenderMemoryTrimClearCount: UInt64
    public internal(set) var clientPresenterTimingResetCount: UInt64
    public internal(set) var clientDisplayLayerLivenessResetCount: UInt64
    public internal(set) var clientPresentationRecoveryRequestCount: UInt64
    public internal(set) var clientPresentationRecoveryHandlerDispatchCount: UInt64
    public internal(set) var clientLastRenderGenerationBumpReason: String?
    public internal(set) var clientLastPresentationRecoveryOutcome: String?
    public var decodeHealthy: Bool
    public var clientDroppedFrames: UInt64
    public var clientDecodeBacklogFrames: Int
    public var clientDecodeSubmissionInFlightCount: Int
    public var clientDecodeSubmissionLimit: Int
    public var clientReassemblerPendingFrameCount: Int
    public var clientReassemblerPendingKeyframeCount: Int
    public var clientReassemblerPendingBytes: Int
    public var clientFrameBufferPoolRetainedBytes: Int
    public var clientReassemblerBudgetEvictions: UInt64
    public var hostEncodedFPS: Double
    public var hostIdleFPS: Double
    public var hostDroppedFrames: UInt64
    public var hostActiveQuality: Double
    public var hostTargetFrameRate: Int
    public var hostEnteredBitrate: Int?
    public var hostCurrentBitrate: Int?
    public var hostRequestedTargetBitrate: Int?
    public var hostBitrateAdaptationCeiling: Int?
    public var hostStartupBitrate: Int?
    public var hostCaptureAdmissionDrops: UInt64?
    public var hostFrameBudgetMs: Double?
    public var hostAverageEncodeMs: Double?
    public var hostCaptureIngressFPS: Double?
    public var hostCaptureFPS: Double?
    public var hostEncodeAttemptFPS: Double?
    public var hostUsingHardwareEncoder: Bool?
    public var hostEncoderGPURegistryID: UInt64?
    public var hostEncodedWidth: Int?
    public var hostEncodedHeight: Int?
    public var hostCapturePixelFormat: String?
    public var hostCaptureColorPrimaries: String?
    public var hostEncoderPixelFormat: String?
    public var hostEncoderChromaSampling: String?
    public var hostEncoderProfile: String?
    public var hostEncoderColorPrimaries: String?
    public var hostEncoderTransferFunction: String?
    public var hostEncoderYCbCrMatrix: String?
    public var hostDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus?
    public var hostTenBitDisplayP3Validated: Bool?
    public var hostUltra444Validated: Bool?
    public var clientDecoderOutputPixelFormat: String?
    public var clientUsingHardwareDecoder: Bool?
    package var hostCaptureIngressAverageMs: Double? = nil
    package var hostCaptureIngressMaxMs: Double? = nil
    package var hostPreEncodeWaitAverageMs: Double? = nil
    package var hostPreEncodeWaitMaxMs: Double? = nil
    package var hostCaptureCallbackAverageMs: Double? = nil
    package var hostCaptureCallbackMaxMs: Double? = nil
    public var hostCaptureWallClockGapWorstMs: Double? = nil
    public var hostCaptureWallClockGapP95Ms: Double? = nil
    public var hostCaptureWallClockGapP99Ms: Double? = nil
    public var hostCaptureDisplayTimeGapWorstMs: Double? = nil
    public var hostCaptureDisplayTimeGapP95Ms: Double? = nil
    public var hostCaptureDisplayTimeGapP99Ms: Double? = nil
    public var hostCaptureDeliveredFrameGapWorstMs: Double? = nil
    public var hostCaptureDeliveredFrameGapP95Ms: Double? = nil
    public var hostCaptureDeliveredFrameGapP99Ms: Double? = nil
    public var hostCaptureCallbackP95Ms: Double? = nil
    public var hostCaptureCallbackP99Ms: Double? = nil
    public var hostCaptureLongFrameGapCount: UInt64? = nil
    public var hostCaptureDisplayTimeDriftCount: UInt64? = nil
    public var hostCaptureVirtualDisplayTimingSuspect: Bool? = nil
    public var hostCaptureUsesDisplayRefreshCadence: Bool? = nil
    public var hostCaptureUsesNativeRefreshMinimumFrameInterval: Bool? = nil
    public var hostCaptureMinimumFrameIntervalRate: Int? = nil
    public var hostCaptureDisplayRefreshRate: Int? = nil
    public var hostVirtualDisplayID: UInt32? = nil
    public var hostVirtualDisplayRefreshRate: Double? = nil
    public var hostVirtualDisplayScaleFactor: Double? = nil
    package var hostCaptureStatusCompleteCount: UInt64? = nil
    package var hostCaptureStatusIdleCount: UInt64? = nil
    package var hostCaptureStatusBlankCount: UInt64? = nil
    package var hostCaptureStatusSuspendedCount: UInt64? = nil
    package var hostCaptureStatusStartedCount: UInt64? = nil
    package var hostCaptureStatusStoppedCount: UInt64? = nil
    package var hostCaptureStatusUnknownCount: UInt64? = nil
    package var hostCaptureCadenceDropCount: UInt64? = nil
    package var hostCaptureCadenceSampleOverwriteCount: UInt64? = nil
    package var hostSendQueueBytes: Int? = nil
    package var hostSendStartDelayAverageMs: Double? = nil
    package var hostSendStartDelayMaxMs: Double? = nil
    package var hostSendCompletionAverageMs: Double? = nil
    package var hostSendCompletionMaxMs: Double? = nil
    package var hostNonKeyframeSendStartDelayAverageMs: Double? = nil
    package var hostNonKeyframeSendStartDelayMaxMs: Double? = nil
    package var hostNonKeyframeSendCompletionAverageMs: Double? = nil
    package var hostNonKeyframeSendCompletionMaxMs: Double? = nil
    package var hostPacketPacerAverageSleepMs: Double? = nil
    package var hostPacketPacerTotalSleepMs: Int? = nil
    package var hostPacketPacerMaxSleepMs: Int? = nil
    package var hostPacketPacerFrameMaxSleepMs: Int? = nil
    package var hostStalePacketDrops: UInt64? = nil
    package var hostSenderLocalDeadlineDrops: UInt64? = nil
    package var hostGenerationAbortDrops: UInt64? = nil
    package var hostNonKeyframeHoldDrops: UInt64? = nil
    public var hasHostMetrics: Bool

    public var hostTransportSendQueueBytes: Int? { hostSendQueueBytes }
    public var hostTransportSendStartDelayAverageMs: Double? { hostSendStartDelayAverageMs }
    public var hostTransportSendCompletionAverageMs: Double? { hostSendCompletionAverageMs }
    public var hostTransportPacketPacerAverageSleepMs: Double? { hostPacketPacerAverageSleepMs }
    public var hostTransportPacketPacerTotalSleepMs: Int? { hostPacketPacerTotalSleepMs }
    public var hostTransportPacketPacerMaxSleepMs: Int? { hostPacketPacerMaxSleepMs }
    public var hostTransportPacketPacerFrameMaxSleepMs: Int? { hostPacketPacerFrameMaxSleepMs }
    public var hostTransportStalePacketDrops: UInt64? { hostStalePacketDrops }
    public var hostTransportGenerationAbortDrops: UInt64? { hostGenerationAbortDrops }
    public var hostTransportNonKeyframeHoldDrops: UInt64? { hostNonKeyframeHoldDrops }
    @available(*, deprecated, renamed: "layerEnqueueFPS")
    public var submittedFPS: Double {
        get { layerEnqueueFPS }
        set { layerEnqueueFPS = newValue }
    }
    @available(*, deprecated, renamed: "uniqueLayerEnqueueFPS")
    public var uniqueSubmittedFPS: Double {
        get { uniqueLayerEnqueueFPS }
        set { uniqueLayerEnqueueFPS = newValue }
    }
    @available(*, deprecated, renamed: "layerEnqueueFPS")
    public var clientLayerAcceptedFPS: Double {
        get { layerEnqueueFPS }
        set { layerEnqueueFPS = newValue }
    }
    @available(*, deprecated, renamed: "uniqueLayerEnqueueFPS")
    public var clientPresentedFPS: Double {
        get { uniqueLayerEnqueueFPS }
        set { uniqueLayerEnqueueFPS = newValue }
    }

    public init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        clientDecodedWorstGapMs: Double = 0,
        clientDecodedFrameIntervalP95Ms: Double = 0,
        clientDecodedFrameIntervalP99Ms: Double = 0,
        clientReceivedWorstGapMs: Double = 0,
        clientReceivedFrameIntervalP95Ms: Double = 0,
        clientReceivedFrameIntervalP99Ms: Double = 0,
        clientLoomStreamDeliveryFPS: Double = 0,
        clientLoomStreamDeliveryGapMaxMs: Double = 0,
        clientRawMediaPacketIngressFPS: Double = 0,
        clientIncomingMediaBatchFPS: Double = 0,
        clientIncomingMediaBatchIntervalP95Ms: Double = 0,
        clientIncomingMediaBatchIntervalP99Ms: Double = 0,
        clientIncomingMediaBatchIntervalMaxMs: Double = 0,
        clientIncomingMediaBatchMaxSize: Int = 0,
        clientIncomingMediaBatchAverageSize: Double = 0,
        clientVideoIngressQueuedBatchCount: Int = 0,
        clientVideoIngressQueuedPacketCount: Int = 0,
        clientVideoIngressQueueAgeMaxMs: Double = 0,
        clientVideoIngressStalePacketDropCount: UInt64 = 0,
        clientVideoIngressProcessedPacketCount: UInt64 = 0,
        clientVideoIngressProcessorWakeDelayMaxMs: Double = 0,
        clientAcceptedMediaMaxPacketSize: Int? = nil,
        clientMediaPayloadEncryptionEnabled: Bool? = nil,
        clientRenderStoreEnqueueFPS: Double = 0,
        clientDisplayLinkCallbackFPS: Double = 0,
        clientDisplayTickWorkerFPS: Double = 0,
        clientDisplayTickMainRelayFPS: Double = 0,
        clientDisplayTickFPS: Double = 0,
        clientPresentationPassFPS: Double = 0,
        clientPresentationEligibleFPS: Double = 0,
        clientSubmitAttemptFPS: Double = 0,
        layerEnqueueFPS: Double = 0,
        uniqueLayerEnqueueFPS: Double = 0,
        clientVisibleFrameFPS: Double = 0,
        clientVisibleFrameCadenceKnown: Bool = false,
        clientVisiblePresentationStallCount: UInt64 = 0,
        clientVisibleWorstPresentationGapMs: Double = 0,
        clientVisibleFrameIntervalP95Ms: Double = 0,
        clientVisibleFrameIntervalP99Ms: Double = 0,
        clientVisibleFrameIntervalMaxMs: Double = 0,
        clientRepeatedSourceFrameCount: UInt64 = 0,
        clientFramesSubmittedPerPassAverage: Double = 0,
        clientFramesSubmittedPerPassMax: UInt64 = 0,
        pendingFrameCount: Int = 0,
        clientUnsubmittedPendingFrameCount: Int = 0,
        clientRetainedSubmittedFrameCount: Int = 0,
        clientPendingFrameAgeMs: Double = 0,
        clientOldestUnsubmittedAgeMs: Double = 0,
        clientNewestUnsubmittedAgeMs: Double = 0,
        clientOverwrittenPendingFrames: UInt64 = 0,
        clientRenderStoreOverwriteFPS: Double = 0,
        clientLowestLatencyFreshBacklogDrops: UInt64 = 0,
        clientLateFrameDrops: UInt64 = 0,
        clientDisplayLayerNotReadyCount: UInt64 = 0,
        clientSampleBufferRendererNotReadyCount: UInt64 = 0,
        clientDisplayImmediatelySubmittedCount: UInt64 = 0,
        clientRendererReadyDrainPassCount: UInt64 = 0,
        clientRendererReadyDrainSubmittedCount: UInt64 = 0,
        clientRendererReadyRearmCount: UInt64 = 0,
        clientRepeatedFrameCount: UInt64 = 0,
        clientDisplayTickNoFrameCount: UInt64 = 0,
        clientTickNoEligibleFrameCount: UInt64 = 0,
        clientFrameArrivedAfterNoFrameTickCount: UInt64 = 0,
        clientFrameArrivalFallbackCount: UInt64 = 0,
        clientFrameArrivalFallbackScheduledCount: UInt64 = 0,
        clientFrameArrivalFallbackSubmittedCount: UInt64 = 0,
        clientNoFrameTickToFrameArrivalMaxMs: Double = 0,
        clientMissedVSyncCount: UInt64 = 0,
        clientSmoothestOneFrameHoldCount: UInt64 = 0,
        clientDisplayCadenceBelowSourceCount: UInt64 = 0,
        clientDisplayTickIntervalP95Ms: Double = 0,
        clientDisplayTickIntervalP99Ms: Double = 0,
        clientPlayoutDelayFrames: Int = 0,
        clientPresentationStallCount: UInt64 = 0,
        clientWorstPresentationGapMs: Double = 0,
        clientFrameIntervalP95Ms: Double = 0,
        clientFrameIntervalP99Ms: Double = 0,
        clientFrameIntervalMaxMs: Double = 0,
        clientDisplayTickIntervalMaxMs: Double = 0,
        clientDisplayTickMainDelayMaxMs: Double = 0,
        clientRenderWorkerSubmitDelayMaxMs: Double = 0,
        decodeHealthy: Bool = true,
        clientDroppedFrames: UInt64 = 0,
        clientDecodeBacklogFrames: Int = 0,
        clientDecodeSubmissionInFlightCount: Int = 0,
        clientDecodeSubmissionLimit: Int = 0,
        clientReassemblerPendingFrameCount: Int = 0,
        clientReassemblerPendingKeyframeCount: Int = 0,
        clientReassemblerPendingBytes: Int = 0,
        clientFrameBufferPoolRetainedBytes: Int = 0,
        clientReassemblerBudgetEvictions: UInt64 = 0,
        hostEncodedFPS: Double = 0,
        hostIdleFPS: Double = 0,
        hostDroppedFrames: UInt64 = 0,
        hostActiveQuality: Double = 0,
        hostTargetFrameRate: Int = 0,
        hostEnteredBitrate: Int? = nil,
        hostCurrentBitrate: Int? = nil,
        hostRequestedTargetBitrate: Int? = nil,
        hostBitrateAdaptationCeiling: Int? = nil,
        hostStartupBitrate: Int? = nil,
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
        self.clientDecodedWorstGapMs = clientDecodedWorstGapMs
        self.clientDecodedFrameIntervalP95Ms = clientDecodedFrameIntervalP95Ms
        self.clientDecodedFrameIntervalP99Ms = clientDecodedFrameIntervalP99Ms
        self.clientReceivedWorstGapMs = clientReceivedWorstGapMs
        self.clientReceivedFrameIntervalP95Ms = clientReceivedFrameIntervalP95Ms
        self.clientReceivedFrameIntervalP99Ms = clientReceivedFrameIntervalP99Ms
        self.clientLoomStreamDeliveryFPS = clientLoomStreamDeliveryFPS
        self.clientLoomStreamDeliveryGapMaxMs = clientLoomStreamDeliveryGapMaxMs
        self.clientRawMediaPacketIngressFPS = clientRawMediaPacketIngressFPS
        self.clientIncomingMediaBatchFPS = clientIncomingMediaBatchFPS
        self.clientIncomingMediaBatchIntervalP95Ms = clientIncomingMediaBatchIntervalP95Ms
        self.clientIncomingMediaBatchIntervalP99Ms = clientIncomingMediaBatchIntervalP99Ms
        self.clientIncomingMediaBatchIntervalMaxMs = clientIncomingMediaBatchIntervalMaxMs
        self.clientIncomingMediaBatchMaxSize = clientIncomingMediaBatchMaxSize
        self.clientIncomingMediaBatchAverageSize = clientIncomingMediaBatchAverageSize
        self.clientVideoIngressQueuedBatchCount = clientVideoIngressQueuedBatchCount
        self.clientVideoIngressQueuedPacketCount = clientVideoIngressQueuedPacketCount
        self.clientVideoIngressQueueAgeMaxMs = clientVideoIngressQueueAgeMaxMs
        self.clientVideoIngressStalePacketDropCount = clientVideoIngressStalePacketDropCount
        self.clientVideoIngressProcessedPacketCount = clientVideoIngressProcessedPacketCount
        self.clientVideoIngressProcessorWakeDelayMaxMs = clientVideoIngressProcessorWakeDelayMaxMs
        self.clientAcceptedMediaMaxPacketSize = clientAcceptedMediaMaxPacketSize
        self.clientMediaPayloadEncryptionEnabled = clientMediaPayloadEncryptionEnabled
        self.clientRenderStoreEnqueueFPS = clientRenderStoreEnqueueFPS
        self.clientDisplayLinkCallbackFPS = clientDisplayLinkCallbackFPS
        self.clientDisplayTickWorkerFPS = clientDisplayTickWorkerFPS
        self.clientDisplayTickMainRelayFPS = clientDisplayTickMainRelayFPS
        self.clientDisplayTickFPS = clientDisplayTickFPS
        self.clientPresentationPassFPS = clientPresentationPassFPS
        self.clientPresentationEligibleFPS = clientPresentationEligibleFPS
        self.clientSubmitAttemptFPS = clientSubmitAttemptFPS
        self.layerEnqueueFPS = layerEnqueueFPS
        self.uniqueLayerEnqueueFPS = uniqueLayerEnqueueFPS
        self.clientVisibleFrameFPS = max(0, clientVisibleFrameFPS)
        self.clientVisibleFrameCadenceKnown = clientVisibleFrameCadenceKnown
        self.clientVisiblePresentationStallCount = clientVisiblePresentationStallCount
        self.clientVisibleWorstPresentationGapMs = max(0, clientVisibleWorstPresentationGapMs)
        self.clientVisibleFrameIntervalP95Ms = max(0, clientVisibleFrameIntervalP95Ms)
        self.clientVisibleFrameIntervalP99Ms = max(0, clientVisibleFrameIntervalP99Ms)
        self.clientVisibleFrameIntervalMaxMs = max(0, clientVisibleFrameIntervalMaxMs)
        self.clientRepeatedSourceFrameCount = clientRepeatedSourceFrameCount
        self.clientFramesSubmittedPerPassAverage = clientFramesSubmittedPerPassAverage
        self.clientFramesSubmittedPerPassMax = clientFramesSubmittedPerPassMax
        self.pendingFrameCount = pendingFrameCount
        self.clientUnsubmittedPendingFrameCount = clientUnsubmittedPendingFrameCount
        self.clientRetainedSubmittedFrameCount = clientRetainedSubmittedFrameCount
        self.clientPendingFrameAgeMs = clientPendingFrameAgeMs
        self.clientOldestUnsubmittedAgeMs = clientOldestUnsubmittedAgeMs
        self.clientNewestUnsubmittedAgeMs = clientNewestUnsubmittedAgeMs
        self.clientOverwrittenPendingFrames = clientOverwrittenPendingFrames
        self.clientRenderStoreOverwriteFPS = clientRenderStoreOverwriteFPS
        self.clientLowestLatencyFreshBacklogDrops = clientLowestLatencyFreshBacklogDrops
        self.clientLateFrameDrops = clientLateFrameDrops
        self.clientCoalescedBeforeSubmitCount = 0
        self.clientDuplicateRemoteTimestampCount = 0
        self.clientCorrectedStreamTimestampCount = 0
        self.clientDisplayLayerNotReadyCount = clientDisplayLayerNotReadyCount
        self.clientSampleBufferRendererNotReadyCount = clientSampleBufferRendererNotReadyCount
        self.clientDisplayImmediatelySubmittedCount = clientDisplayImmediatelySubmittedCount
        self.clientRendererReadyDrainPassCount = clientRendererReadyDrainPassCount
        self.clientRendererReadyDrainSubmittedCount = clientRendererReadyDrainSubmittedCount
        self.clientRendererReadyRearmCount = clientRendererReadyRearmCount
        self.clientRepeatedFrameCount = clientRepeatedFrameCount
        self.clientDisplayTickNoFrameCount = clientDisplayTickNoFrameCount
        self.clientTickNoEligibleFrameCount = clientTickNoEligibleFrameCount
        self.clientFrameArrivedAfterNoFrameTickCount = clientFrameArrivedAfterNoFrameTickCount
        self.clientFrameArrivalFallbackCount = clientFrameArrivalFallbackCount
        self.clientFrameArrivalFallbackScheduledCount = clientFrameArrivalFallbackScheduledCount
        self.clientFrameArrivalFallbackSubmittedCount = clientFrameArrivalFallbackSubmittedCount
        self.clientNoFrameTickToFrameArrivalMaxMs = clientNoFrameTickToFrameArrivalMaxMs
        self.clientMissedVSyncCount = clientMissedVSyncCount
        self.clientSmoothestOneFrameHoldCount = clientSmoothestOneFrameHoldCount
        self.clientDisplayCadenceBelowSourceCount = clientDisplayCadenceBelowSourceCount
        self.clientDisplayTickIntervalP95Ms = clientDisplayTickIntervalP95Ms
        self.clientDisplayTickIntervalP99Ms = clientDisplayTickIntervalP99Ms
        self.clientPlayoutDelayFrames = clientPlayoutDelayFrames
        self.clientPresentationStallCount = clientPresentationStallCount
        self.clientWorstPresentationGapMs = clientWorstPresentationGapMs
        self.clientFrameIntervalP95Ms = clientFrameIntervalP95Ms
        self.clientFrameIntervalP99Ms = clientFrameIntervalP99Ms
        self.clientFrameIntervalMaxMs = clientFrameIntervalMaxMs
        self.clientDisplayTickIntervalMaxMs = clientDisplayTickIntervalMaxMs
        self.clientDisplayTickMainDelayMaxMs = clientDisplayTickMainDelayMaxMs
        self.clientRenderWorkerSubmitDelayMaxMs = clientRenderWorkerSubmitDelayMaxMs
        self.clientAudioStaleVideoGateCount = 0
        self.clientAudioStaleVideoSoftHoldCount = 0
        self.clientAudioStaleVideoConfirmedGateCount = 0
        self.clientAudioStaleVideoMaxSnapshotAgeMs = 0
        self.clientRenderStoreClearCount = 0
        self.clientRenderGenerationBumpCount = 0
        self.clientRenderMemoryTrimClearCount = 0
        self.clientPresenterTimingResetCount = 0
        self.clientDisplayLayerLivenessResetCount = 0
        self.clientPresentationRecoveryRequestCount = 0
        self.clientPresentationRecoveryHandlerDispatchCount = 0
        self.clientLastRenderGenerationBumpReason = nil
        self.clientLastPresentationRecoveryOutcome = nil
        self.decodeHealthy = decodeHealthy
        self.clientDroppedFrames = clientDroppedFrames
        self.clientDecodeBacklogFrames = clientDecodeBacklogFrames
        self.clientDecodeSubmissionInFlightCount = clientDecodeSubmissionInFlightCount
        self.clientDecodeSubmissionLimit = clientDecodeSubmissionLimit
        self.clientReassemblerPendingFrameCount = clientReassemblerPendingFrameCount
        self.clientReassemblerPendingKeyframeCount = clientReassemblerPendingKeyframeCount
        self.clientReassemblerPendingBytes = clientReassemblerPendingBytes
        self.clientFrameBufferPoolRetainedBytes = clientFrameBufferPoolRetainedBytes
        self.clientReassemblerBudgetEvictions = clientReassemblerBudgetEvictions
        self.hostEncodedFPS = hostEncodedFPS
        self.hostIdleFPS = hostIdleFPS
        self.hostDroppedFrames = hostDroppedFrames
        self.hostActiveQuality = hostActiveQuality
        self.hostTargetFrameRate = hostTargetFrameRate
        self.hostEnteredBitrate = hostEnteredBitrate
        self.hostCurrentBitrate = hostCurrentBitrate
        self.hostRequestedTargetBitrate = hostRequestedTargetBitrate
        self.hostBitrateAdaptationCeiling = hostBitrateAdaptationCeiling
        self.hostStartupBitrate = hostStartupBitrate
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
        self.hasHostMetrics = hasHostMetrics
    }

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
        hostCaptureUsesDisplayRefreshCadence = cadence?.usesDisplayRefreshCadence
        hostCaptureUsesNativeRefreshMinimumFrameInterval = cadence?.usesNativeRefreshMinimumFrameInterval
        hostCaptureMinimumFrameIntervalRate = cadence?.minimumFrameIntervalRate
        hostCaptureDisplayRefreshRate = cadence?.displayRefreshRate
        hostVirtualDisplayID = cadence?.virtualDisplayID
        hostVirtualDisplayRefreshRate = cadence?.virtualDisplayRefreshRate
        hostVirtualDisplayScaleFactor = cadence?.virtualDisplayScaleFactor
        hostCaptureStatusCompleteCount = cadence?.completeFrameStatusCount
        hostCaptureStatusIdleCount = cadence?.idleFrameStatusCount
        hostCaptureStatusBlankCount = cadence?.blankFrameStatusCount
        hostCaptureStatusSuspendedCount = cadence?.suspendedFrameStatusCount
        hostCaptureStatusStartedCount = cadence?.startedFrameStatusCount
        hostCaptureStatusStoppedCount = cadence?.stoppedFrameStatusCount
        hostCaptureStatusUnknownCount = cadence?.unknownFrameStatusCount
        hostCaptureCadenceDropCount = cadence?.cadenceDropCount
        hostCaptureCadenceSampleOverwriteCount = cadence?.sampleOverwriteCount
    }
}

public final class MirageClientMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var metricsByStream: [StreamID: MirageClientMetricsSnapshot] = [:]

    public init() {}

    public func updateClientMetrics(
        streamID: StreamID,
        decodedFPS: Double,
        receivedFPS: Double,
        decodedWorstGapMs: Double = 0,
        decodedFrameIntervalP95Ms: Double = 0,
        decodedFrameIntervalP99Ms: Double = 0,
        receivedWorstGapMs: Double = 0,
        receivedFrameIntervalP95Ms: Double = 0,
        receivedFrameIntervalP99Ms: Double = 0,
        droppedFrames: UInt64,
        renderStoreEnqueueFPS: Double = 0,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        frameBufferPoolRetainedBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0,
        displayLinkCallbackFPS: Double = 0,
        displayTickWorkerFPS: Double = 0,
        displayTickMainRelayFPS: Double = 0,
        displayTickFPS: Double = 0,
        presentationPassFPS: Double = 0,
        presentationEligibleFPS: Double = 0,
        submitAttemptFPS: Double = 0,
        layerEnqueueFPS: Double,
        uniqueLayerEnqueueFPS: Double,
        visibleFrameFPS: Double = 0,
        visibleFrameCadenceKnown: Bool = false,
        visiblePresentationStallCount: UInt64 = 0,
        visibleWorstPresentationGapMs: Double = 0,
        visibleFrameIntervalP95Ms: Double = 0,
        visibleFrameIntervalP99Ms: Double = 0,
        visibleFrameIntervalMaxMs: Double = 0,
        repeatedSourceFrameCount: UInt64 = 0,
        framesSubmittedPerPassAverage: Double = 0,
        framesSubmittedPerPassMax: UInt64 = 0,
        pendingFrameCount: Int,
        unsubmittedPendingFrameCount: Int = 0,
        retainedSubmittedFrameCount: Int = 0,
        pendingFrameAgeMs: Double,
        oldestUnsubmittedAgeMs: Double = 0,
        newestUnsubmittedAgeMs: Double = 0,
        overwrittenPendingFrames: UInt64,
        renderStoreOverwriteFPS: Double = 0,
        lowestLatencyFreshBacklogDrops: UInt64 = 0,
        lateFrameDrops: UInt64 = 0,
        displayLayerNotReadyCount: UInt64,
        sampleBufferRendererNotReadyCount: UInt64 = 0,
        displayImmediatelySubmittedCount: UInt64 = 0,
        rendererReadyDrainPassCount: UInt64 = 0,
        rendererReadyDrainSubmittedCount: UInt64 = 0,
        rendererReadyRearmCount: UInt64 = 0,
        repeatedFrameCount: UInt64 = 0,
        displayTickNoFrameCount: UInt64 = 0,
        tickNoEligibleFrameCount: UInt64 = 0,
        frameArrivedAfterNoFrameTickCount: UInt64 = 0,
        frameArrivalFallbackCount: UInt64 = 0,
        frameArrivalFallbackScheduledCount: UInt64 = 0,
        frameArrivalFallbackSubmittedCount: UInt64 = 0,
        noFrameTickToFrameArrivalMaxMs: Double = 0,
        missedVSyncCount: UInt64 = 0,
        smoothestOneFrameHoldCount: UInt64 = 0,
        displayCadenceBelowSourceCount: UInt64 = 0,
        displayTickIntervalP95Ms: Double = 0,
        displayTickIntervalP99Ms: Double = 0,
        playoutDelayFrames: Int = 0,
        presentationStallCount: UInt64 = 0,
        worstPresentationGapMs: Double = 0,
        frameIntervalP95Ms: Double = 0,
        frameIntervalP99Ms: Double = 0,
        frameIntervalMaxMs: Double = 0,
        displayTickIntervalMaxMs: Double = 0,
        displayTickMainDelayMaxMs: Double = 0,
        renderWorkerSubmitDelayMaxMs: Double = 0,
        decodeBacklogFrames: Int = 0,
        decodeSubmissionInFlightCount: Int = 0,
        decodeSubmissionLimit: Int = 0,
        decodeHealthy: Bool
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.decodedFPS = decodedFPS
        snapshot.receivedFPS = receivedFPS
        snapshot.clientDecodedWorstGapMs = max(0, decodedWorstGapMs)
        snapshot.clientDecodedFrameIntervalP95Ms = max(0, decodedFrameIntervalP95Ms)
        snapshot.clientDecodedFrameIntervalP99Ms = max(0, decodedFrameIntervalP99Ms)
        snapshot.clientReceivedWorstGapMs = max(0, receivedWorstGapMs)
        snapshot.clientReceivedFrameIntervalP95Ms = max(0, receivedFrameIntervalP95Ms)
        snapshot.clientReceivedFrameIntervalP99Ms = max(0, receivedFrameIntervalP99Ms)
        snapshot.clientRenderStoreEnqueueFPS = max(0, renderStoreEnqueueFPS)
        snapshot.clientDisplayLinkCallbackFPS = max(0, displayLinkCallbackFPS)
        snapshot.clientDisplayTickWorkerFPS = max(0, displayTickWorkerFPS)
        snapshot.clientDisplayTickMainRelayFPS = max(0, displayTickMainRelayFPS)
        snapshot.clientDisplayTickFPS = max(0, displayTickFPS)
        snapshot.clientPresentationPassFPS = max(0, presentationPassFPS)
        snapshot.clientPresentationEligibleFPS = max(0, presentationEligibleFPS)
        snapshot.clientSubmitAttemptFPS = max(0, submitAttemptFPS)
        snapshot.layerEnqueueFPS = max(0, layerEnqueueFPS)
        snapshot.uniqueLayerEnqueueFPS = max(0, uniqueLayerEnqueueFPS)
        snapshot.clientVisibleFrameFPS = max(0, visibleFrameFPS)
        snapshot.clientVisibleFrameCadenceKnown = visibleFrameCadenceKnown
        snapshot.clientVisiblePresentationStallCount = visiblePresentationStallCount
        snapshot.clientVisibleWorstPresentationGapMs = max(0, visibleWorstPresentationGapMs)
        snapshot.clientVisibleFrameIntervalP95Ms = max(0, visibleFrameIntervalP95Ms)
        snapshot.clientVisibleFrameIntervalP99Ms = max(0, visibleFrameIntervalP99Ms)
        snapshot.clientVisibleFrameIntervalMaxMs = max(0, visibleFrameIntervalMaxMs)
        snapshot.clientRepeatedSourceFrameCount = repeatedSourceFrameCount
        snapshot.clientFramesSubmittedPerPassAverage = max(0, framesSubmittedPerPassAverage)
        snapshot.clientFramesSubmittedPerPassMax = framesSubmittedPerPassMax
        snapshot.pendingFrameCount = max(0, pendingFrameCount)
        snapshot.clientUnsubmittedPendingFrameCount = max(0, unsubmittedPendingFrameCount)
        snapshot.clientRetainedSubmittedFrameCount = max(0, retainedSubmittedFrameCount)
        snapshot.clientPendingFrameAgeMs = max(0, pendingFrameAgeMs)
        snapshot.clientOldestUnsubmittedAgeMs = max(0, oldestUnsubmittedAgeMs)
        snapshot.clientNewestUnsubmittedAgeMs = max(0, newestUnsubmittedAgeMs)
        snapshot.clientOverwrittenPendingFrames = overwrittenPendingFrames
        snapshot.clientRenderStoreOverwriteFPS = max(0, renderStoreOverwriteFPS)
        snapshot.clientLowestLatencyFreshBacklogDrops = lowestLatencyFreshBacklogDrops
        snapshot.clientLateFrameDrops = lateFrameDrops
        snapshot.clientDisplayLayerNotReadyCount = displayLayerNotReadyCount
        snapshot.clientSampleBufferRendererNotReadyCount = sampleBufferRendererNotReadyCount
        snapshot.clientDisplayImmediatelySubmittedCount = displayImmediatelySubmittedCount
        snapshot.clientRendererReadyDrainPassCount = rendererReadyDrainPassCount
        snapshot.clientRendererReadyDrainSubmittedCount = rendererReadyDrainSubmittedCount
        snapshot.clientRendererReadyRearmCount = rendererReadyRearmCount
        snapshot.clientRepeatedFrameCount = repeatedFrameCount
        snapshot.clientDisplayTickNoFrameCount = displayTickNoFrameCount
        snapshot.clientTickNoEligibleFrameCount = tickNoEligibleFrameCount
        snapshot.clientFrameArrivedAfterNoFrameTickCount = frameArrivedAfterNoFrameTickCount
        snapshot.clientFrameArrivalFallbackCount = frameArrivalFallbackCount
        snapshot.clientFrameArrivalFallbackScheduledCount = frameArrivalFallbackScheduledCount
        snapshot.clientFrameArrivalFallbackSubmittedCount = frameArrivalFallbackSubmittedCount
        snapshot.clientNoFrameTickToFrameArrivalMaxMs = max(0, noFrameTickToFrameArrivalMaxMs)
        snapshot.clientMissedVSyncCount = missedVSyncCount
        snapshot.clientSmoothestOneFrameHoldCount = smoothestOneFrameHoldCount
        snapshot.clientDisplayCadenceBelowSourceCount = displayCadenceBelowSourceCount
        snapshot.clientDisplayTickIntervalP95Ms = max(0, displayTickIntervalP95Ms)
        snapshot.clientDisplayTickIntervalP99Ms = max(0, displayTickIntervalP99Ms)
        snapshot.clientPlayoutDelayFrames = max(0, playoutDelayFrames)
        snapshot.clientPresentationStallCount = presentationStallCount
        snapshot.clientWorstPresentationGapMs = max(0, worstPresentationGapMs)
        snapshot.clientFrameIntervalP95Ms = max(0, frameIntervalP95Ms)
        snapshot.clientFrameIntervalP99Ms = max(0, frameIntervalP99Ms)
        snapshot.clientFrameIntervalMaxMs = max(0, frameIntervalMaxMs)
        snapshot.clientDisplayTickIntervalMaxMs = max(0, displayTickIntervalMaxMs)
        snapshot.clientDisplayTickMainDelayMaxMs = max(0, displayTickMainDelayMaxMs)
        snapshot.clientRenderWorkerSubmitDelayMaxMs = max(0, renderWorkerSubmitDelayMaxMs)
        snapshot.decodeHealthy = decodeHealthy
        snapshot.clientDroppedFrames = droppedFrames
        snapshot.clientDecodeBacklogFrames = max(0, decodeBacklogFrames)
        snapshot.clientDecodeSubmissionInFlightCount = max(0, decodeSubmissionInFlightCount)
        snapshot.clientDecodeSubmissionLimit = max(0, decodeSubmissionLimit)
        snapshot.clientReassemblerPendingFrameCount = max(0, reassemblerPendingFrameCount)
        snapshot.clientReassemblerPendingKeyframeCount = max(0, reassemblerPendingKeyframeCount)
        snapshot.clientReassemblerPendingBytes = max(0, reassemblerPendingBytes)
        snapshot.clientFrameBufferPoolRetainedBytes = max(0, frameBufferPoolRetainedBytes)
        snapshot.clientReassemblerBudgetEvictions = reassemblerBudgetEvictions
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func updateHostMetrics(
        streamID: StreamID,
        encodedFPS: Double,
        idleEncodedFPS: Double,
        droppedFrames: UInt64,
        activeQuality: Double,
        targetFrameRate: Int,
        enteredBitrate: Int? = nil,
        currentBitrate: Int? = nil,
        requestedTargetBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        startupBitrate: Int? = nil,
        captureAdmissionDrops: UInt64? = nil,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double?,
        captureIngressFPS: Double? = nil,
        captureFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        usingHardwareEncoder: Bool?,
        encoderGPURegistryID: UInt64?,
        encodedWidth: Int?,
        encodedHeight: Int?,
        capturePixelFormat: String?,
        captureColorPrimaries: String?,
        encoderPixelFormat: String?,
        encoderChromaSampling: String?,
        encoderProfile: String?,
        encoderColorPrimaries: String?,
        encoderTransferFunction: String?,
        encoderYCbCrMatrix: String?,
        displayP3CoverageStatus: MirageDisplayP3CoverageStatus?,
        tenBitDisplayP3Validated: Bool?,
        ultra444Validated: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostEncodedFPS = encodedFPS
        snapshot.hostIdleFPS = idleEncodedFPS
        snapshot.hostDroppedFrames = droppedFrames
        snapshot.hostActiveQuality = activeQuality
        snapshot.hostTargetFrameRate = targetFrameRate
        snapshot.hostEnteredBitrate = enteredBitrate
        snapshot.hostCurrentBitrate = currentBitrate
        snapshot.hostRequestedTargetBitrate = requestedTargetBitrate
        snapshot.hostBitrateAdaptationCeiling = bitrateAdaptationCeiling
        snapshot.hostStartupBitrate = startupBitrate
        snapshot.hostCaptureAdmissionDrops = captureAdmissionDrops
        snapshot.hostFrameBudgetMs = frameBudgetMs
        snapshot.hostAverageEncodeMs = averageEncodeMs
        snapshot.hostCaptureIngressFPS = captureIngressFPS
        snapshot.hostCaptureFPS = captureFPS
        snapshot.hostEncodeAttemptFPS = encodeAttemptFPS
        snapshot.hostUsingHardwareEncoder = usingHardwareEncoder
        snapshot.hostEncoderGPURegistryID = encoderGPURegistryID
        snapshot.hostEncodedWidth = encodedWidth
        snapshot.hostEncodedHeight = encodedHeight
        snapshot.hostCapturePixelFormat = capturePixelFormat
        snapshot.hostCaptureColorPrimaries = captureColorPrimaries
        snapshot.hostEncoderPixelFormat = encoderPixelFormat
        snapshot.hostEncoderChromaSampling = encoderChromaSampling
        snapshot.hostEncoderProfile = encoderProfile
        snapshot.hostEncoderColorPrimaries = encoderColorPrimaries
        snapshot.hostEncoderTransferFunction = encoderTransferFunction
        snapshot.hostEncoderYCbCrMatrix = encoderYCbCrMatrix
        snapshot.hostDisplayP3CoverageStatus = displayP3CoverageStatus
        snapshot.hostTenBitDisplayP3Validated = tenBitDisplayP3Validated
        snapshot.hostUltra444Validated = ultra444Validated
        snapshot.hasHostMetrics = true
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    func updateHostPipelineMetrics(
        streamID: StreamID,
        captureIngressAverageMs: Double?,
        captureIngressMaxMs: Double?,
        preEncodeWaitAverageMs: Double?,
        preEncodeWaitMaxMs: Double?,
        captureCallbackAverageMs: Double?,
        captureCallbackMaxMs: Double?,
        captureCadence: StreamCaptureCadenceMetrics?,
        sendQueueBytes: Int?,
        sendStartDelayAverageMs: Double?,
        sendStartDelayMaxMs: Double?,
        sendCompletionAverageMs: Double?,
        sendCompletionMaxMs: Double?,
        nonKeyframeSendStartDelayAverageMs: Double?,
        nonKeyframeSendStartDelayMaxMs: Double?,
        nonKeyframeSendCompletionAverageMs: Double?,
        nonKeyframeSendCompletionMaxMs: Double?,
        packetPacerAverageSleepMs: Double?,
        packetPacerTotalSleepMs: Int?,
        packetPacerMaxSleepMs: Int?,
        packetPacerFrameMaxSleepMs: Int?,
        stalePacketDrops: UInt64?,
        senderLocalDeadlineDrops: UInt64?,
        generationAbortDrops: UInt64?,
        nonKeyframeHoldDrops: UInt64?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostCaptureIngressAverageMs = captureIngressAverageMs
        snapshot.hostCaptureIngressMaxMs = captureIngressMaxMs
        snapshot.hostPreEncodeWaitAverageMs = preEncodeWaitAverageMs
        snapshot.hostPreEncodeWaitMaxMs = preEncodeWaitMaxMs
        snapshot.hostCaptureCallbackAverageMs = captureCallbackAverageMs
        snapshot.hostCaptureCallbackMaxMs = captureCallbackMaxMs
        snapshot.applyHostCaptureCadence(captureCadence)
        snapshot.hostSendQueueBytes = sendQueueBytes
        snapshot.hostSendStartDelayAverageMs = sendStartDelayAverageMs
        snapshot.hostSendStartDelayMaxMs = sendStartDelayMaxMs
        snapshot.hostSendCompletionAverageMs = sendCompletionAverageMs
        snapshot.hostSendCompletionMaxMs = sendCompletionMaxMs
        snapshot.hostNonKeyframeSendStartDelayAverageMs = nonKeyframeSendStartDelayAverageMs
        snapshot.hostNonKeyframeSendStartDelayMaxMs = nonKeyframeSendStartDelayMaxMs
        snapshot.hostNonKeyframeSendCompletionAverageMs = nonKeyframeSendCompletionAverageMs
        snapshot.hostNonKeyframeSendCompletionMaxMs = nonKeyframeSendCompletionMaxMs
        snapshot.hostPacketPacerAverageSleepMs = packetPacerAverageSleepMs
        snapshot.hostPacketPacerTotalSleepMs = packetPacerTotalSleepMs
        snapshot.hostPacketPacerMaxSleepMs = packetPacerMaxSleepMs
        snapshot.hostPacketPacerFrameMaxSleepMs = packetPacerFrameMaxSleepMs
        snapshot.hostStalePacketDrops = stalePacketDrops
        snapshot.hostSenderLocalDeadlineDrops = senderLocalDeadlineDrops
        snapshot.hostGenerationAbortDrops = generationAbortDrops
        snapshot.hostNonKeyframeHoldDrops = nonKeyframeHoldDrops
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func updateClientDecoderTelemetry(
        streamID: StreamID,
        outputPixelFormat: String?,
        usingHardwareDecoder: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientDecoderOutputPixelFormat = outputPixelFormat
        snapshot.clientUsingHardwareDecoder = usingHardwareDecoder
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    package func updateClientVideoIngressMetrics(
        streamID: StreamID,
        loomStreamDeliveryFPS: Double,
        loomStreamDeliveryGapMaxMs: Double,
        rawPacketIngressFPS: Double,
        incomingBatchFPS: Double,
        incomingBatchIntervalP95Ms: Double,
        incomingBatchIntervalP99Ms: Double,
        incomingBatchIntervalMaxMs: Double,
        incomingBatchMaxSize: Int,
        incomingBatchAverageSize: Double,
        queuedBatchCount: Int,
        queuedPacketCount: Int,
        queueAgeMaxMs: Double,
        stalePacketDropCount: UInt64,
        processedPacketCount: UInt64,
        processorWakeDelayMaxMs: Double,
        acceptedMediaMaxPacketSize: Int?,
        mediaPayloadEncryptionEnabled: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientLoomStreamDeliveryFPS = max(0, loomStreamDeliveryFPS)
        snapshot.clientLoomStreamDeliveryGapMaxMs = max(0, loomStreamDeliveryGapMaxMs)
        snapshot.clientRawMediaPacketIngressFPS = max(0, rawPacketIngressFPS)
        snapshot.clientIncomingMediaBatchFPS = max(0, incomingBatchFPS)
        snapshot.clientIncomingMediaBatchIntervalP95Ms = max(0, incomingBatchIntervalP95Ms)
        snapshot.clientIncomingMediaBatchIntervalP99Ms = max(0, incomingBatchIntervalP99Ms)
        snapshot.clientIncomingMediaBatchIntervalMaxMs = max(0, incomingBatchIntervalMaxMs)
        snapshot.clientIncomingMediaBatchMaxSize = max(0, incomingBatchMaxSize)
        snapshot.clientIncomingMediaBatchAverageSize = max(0, incomingBatchAverageSize)
        snapshot.clientVideoIngressQueuedBatchCount = max(0, queuedBatchCount)
        snapshot.clientVideoIngressQueuedPacketCount = max(0, queuedPacketCount)
        snapshot.clientVideoIngressQueueAgeMaxMs = max(0, queueAgeMaxMs)
        snapshot.clientVideoIngressStalePacketDropCount = stalePacketDropCount
        snapshot.clientVideoIngressProcessedPacketCount = processedPacketCount
        snapshot.clientVideoIngressProcessorWakeDelayMaxMs = max(0, processorWakeDelayMaxMs)
        snapshot.clientAcceptedMediaMaxPacketSize = acceptedMediaMaxPacketSize
        snapshot.clientMediaPayloadEncryptionEnabled = mediaPayloadEncryptionEnabled
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    package func updateClientTimingDiagnostics(
        streamID: StreamID,
        coalescedBeforeSubmitCount: UInt64,
        duplicateRemoteTimestampCount: UInt64,
        correctedStreamTimestampCount: UInt64
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientCoalescedBeforeSubmitCount = coalescedBeforeSubmitCount
        snapshot.clientDuplicateRemoteTimestampCount = duplicateRemoteTimestampCount
        snapshot.clientCorrectedStreamTimestampCount = correctedStreamTimestampCount
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    package func updateClientAudioSyncDiagnostics(
        streamID: StreamID,
        staleVideoGateCount: UInt64,
        staleVideoSoftHoldCount: UInt64,
        staleVideoConfirmedGateCount: UInt64,
        staleVideoMaxSnapshotAgeMs: Double
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientAudioStaleVideoGateCount = staleVideoGateCount
        snapshot.clientAudioStaleVideoSoftHoldCount = staleVideoSoftHoldCount
        snapshot.clientAudioStaleVideoConfirmedGateCount = staleVideoConfirmedGateCount
        snapshot.clientAudioStaleVideoMaxSnapshotAgeMs = max(0, staleVideoMaxSnapshotAgeMs)
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    package func updateClientPresentationDiagnostics(
        streamID: StreamID,
        renderStoreClearCount: UInt64,
        renderGenerationBumpCount: UInt64,
        renderMemoryTrimClearCount: UInt64,
        presenterTimingResetCount: UInt64,
        displayLayerLivenessResetCount: UInt64,
        presentationRecoveryRequestCount: UInt64,
        presentationRecoveryHandlerDispatchCount: UInt64,
        lastRenderGenerationBumpReason: String?,
        lastPresentationRecoveryOutcome: String?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientRenderStoreClearCount = renderStoreClearCount
        snapshot.clientRenderGenerationBumpCount = renderGenerationBumpCount
        snapshot.clientRenderMemoryTrimClearCount = renderMemoryTrimClearCount
        snapshot.clientPresenterTimingResetCount = presenterTimingResetCount
        snapshot.clientDisplayLayerLivenessResetCount = displayLayerLivenessResetCount
        snapshot.clientPresentationRecoveryRequestCount = presentationRecoveryRequestCount
        snapshot.clientPresentationRecoveryHandlerDispatchCount = presentationRecoveryHandlerDispatchCount
        snapshot.clientLastRenderGenerationBumpReason = lastRenderGenerationBumpReason
        snapshot.clientLastPresentationRecoveryOutcome = lastPresentationRecoveryOutcome
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func snapshot(for streamID: StreamID) -> MirageClientMetricsSnapshot? {
        lock.lock()
        let result = metricsByStream[streamID]
        lock.unlock()
        return result
    }

    public func clear(streamID: StreamID) {
        lock.lock()
        metricsByStream.removeValue(forKey: streamID)
        lock.unlock()
    }

    public func clearAll() {
        lock.lock()
        metricsByStream.removeAll()
        lock.unlock()
    }
}
