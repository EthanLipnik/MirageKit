//
//  ClientStreamingAnomalyDiagnostic.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

import Foundation
import MirageKit

struct ClientStreamingAnomalySample {
    let streamID: StreamID
    let trigger: String
    let decodedFPS: Double
    let receivedFPS: Double
    let receivedWorstGapMs: Double
    let receivedFrameIntervalP95Ms: Double
    let receivedFrameIntervalP99Ms: Double
    let displayTickFPS: Double
    let submitAttemptFPS: Double
    let layerAcceptedFPS: Double
    let visibleFrameFPS: Double
    let submittedFPS: Double
    let uniqueSubmittedFPS: Double
    let pendingFrameCount: Int
    let pendingFrameAgeMs: Double
    let pendingFrameAgeP95Ms: Double
    let pendingFrameAgeMaxMs: Double
    let pendingFrameDepthMax: Int
    let smoothestDisplayDebtMs: Double
    let smoothestDisplayDebtCapMs: Double
    let overwrittenPendingFrames: UInt64
    let smoothestQueueDrops: UInt64
    let smoothestDepthDrops: UInt64
    let smoothestAgeDrops: UInt64
    let smoothestDropsUnder100ms: UInt64
    let smoothestDroppedFrameAgeMaxMs: Double
    let smoothestDisplayDebtDrops: UInt64
    let smoothestFifoResetCount: UInt64
    let lateFrameDrops: UInt64
    let coalescedBeforeSubmitCount: UInt64
    let duplicateRemoteTimestampCount: UInt64
    let correctedStreamTimestampCount: UInt64
    let displayLayerNotReadyCount: UInt64
    let repeatedFrameCount: UInt64
    let missedVSyncCount: UInt64
    let displayTickIntervalP95Ms: Double
    let displayTickIntervalP99Ms: Double
    let playoutDelayFrames: Int
    let presentationStallCount: UInt64
    let worstPresentationGapMs: Double
    let frameIntervalP95Ms: Double
    let frameIntervalP99Ms: Double
    let decodeHealthy: Bool
    let decodeSubmissionLimit: Int
    let presentationTier: StreamPresentationTier
    let reassemblerPendingFrameCount: Int
    let reassemblerPendingKeyframeCount: Int
    let reassemblerPendingBytes: Int
    let frameBufferPoolRetainedBytes: Int
    let reassemblerBudgetEvictions: UInt64
    let reassemblerIncompleteFrameTimeouts: UInt64
    let reassemblerIncompleteFrameNoProgressTimeouts: UInt64
    let reassemblerIncompleteFrameLifetimeTimeouts: UInt64
    let reassemblerMissingFragmentTimeouts: UInt64
    let reassemblerForwardGapTimeouts: UInt64
    let decoderOutputPixelFormat: String?
    let usingHardwareDecoder: Bool?
    let targetFrameRate: Int
    let sourceTargetFrameRate: Int
    let displayTargetFrameRate: Int
    let hostMetrics: StreamMetricsMessage?
    let videoIngressMetrics: ClientVideoIngressMetricsSnapshot?

    init(
        streamID: StreamID,
        trigger: String,
        decodedFPS: Double,
        receivedFPS: Double,
        receivedWorstGapMs: Double = 0,
        receivedFrameIntervalP95Ms: Double = 0,
        receivedFrameIntervalP99Ms: Double = 0,
        displayTickFPS: Double = 0,
        submitAttemptFPS: Double = 0,
        layerAcceptedFPS: Double = 0,
        presentedFPS: Double = 0,
        layerEnqueueFPS: Double? = nil,
        uniqueLayerEnqueueFPS: Double? = nil,
        visibleFrameFPS: Double? = nil,
        visibleFrameCadenceKnown: Bool = true,
        submittedFPS: Double? = nil,
        uniqueSubmittedFPS: Double? = nil,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        pendingFrameAgeP95Ms: Double = 0,
        pendingFrameAgeMaxMs: Double = 0,
        pendingFrameDepthMax: Int = 0,
        smoothestDisplayDebtMs: Double = 0,
        smoothestDisplayDebtCapMs: Double = 0,
        overwrittenPendingFrames: UInt64,
        smoothestQueueDrops: UInt64 = 0,
        smoothestDepthDrops: UInt64 = 0,
        smoothestAgeDrops: UInt64 = 0,
        smoothestDropsUnder100ms: UInt64 = 0,
        smoothestDroppedFrameAgeMaxMs: Double = 0,
        smoothestDisplayDebtDrops: UInt64 = 0,
        smoothestFifoResetCount: UInt64 = 0,
        lateFrameDrops: UInt64 = 0,
        coalescedBeforeSubmitCount: UInt64 = 0,
        duplicateRemoteTimestampCount: UInt64 = 0,
        correctedStreamTimestampCount: UInt64 = 0,
        displayLayerNotReadyCount: UInt64,
        repeatedFrameCount: UInt64 = 0,
        missedVSyncCount: UInt64 = 0,
        displayTickIntervalP95Ms: Double = 0,
        displayTickIntervalP99Ms: Double = 0,
        playoutDelayFrames: Int = 0,
        presentationStallCount: UInt64 = 0,
        worstPresentationGapMs: Double = 0,
        frameIntervalP95Ms: Double = 0,
        frameIntervalP99Ms: Double = 0,
        decodeHealthy: Bool,
        decodeSubmissionLimit: Int,
        presentationTier: StreamPresentationTier,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        frameBufferPoolRetainedBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0,
        reassemblerIncompleteFrameTimeouts: UInt64 = 0,
        reassemblerIncompleteFrameNoProgressTimeouts: UInt64 = 0,
        reassemblerIncompleteFrameLifetimeTimeouts: UInt64 = 0,
        reassemblerMissingFragmentTimeouts: UInt64 = 0,
        reassemblerForwardGapTimeouts: UInt64 = 0,
        decoderOutputPixelFormat: String?,
        usingHardwareDecoder: Bool?,
        targetFrameRate: Int,
        sourceTargetFrameRate: Int? = nil,
        displayTargetFrameRate: Int? = nil,
        hostMetrics: StreamMetricsMessage?,
        videoIngressMetrics: ClientVideoIngressMetricsSnapshot? = nil
    ) {
        self.streamID = streamID
        self.trigger = trigger
        self.decodedFPS = decodedFPS
        self.receivedFPS = receivedFPS
        self.receivedWorstGapMs = receivedWorstGapMs
        self.receivedFrameIntervalP95Ms = receivedFrameIntervalP95Ms
        self.receivedFrameIntervalP99Ms = receivedFrameIntervalP99Ms
        self.displayTickFPS = displayTickFPS
        self.submitAttemptFPS = submitAttemptFPS
        self.layerAcceptedFPS = layerAcceptedFPS
        self.visibleFrameFPS = visibleFrameFPS ?? presentedFPS
        _ = visibleFrameCadenceKnown
        self.submittedFPS = submittedFPS ?? layerEnqueueFPS ?? submitAttemptFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS ?? uniqueLayerEnqueueFPS ?? submittedFPS ?? layerEnqueueFPS ?? submitAttemptFPS
        self.pendingFrameCount = pendingFrameCount
        self.pendingFrameAgeMs = pendingFrameAgeMs
        self.pendingFrameAgeP95Ms = pendingFrameAgeP95Ms
        self.pendingFrameAgeMaxMs = pendingFrameAgeMaxMs
        self.pendingFrameDepthMax = pendingFrameDepthMax
        self.smoothestDisplayDebtMs = smoothestDisplayDebtMs
        self.smoothestDisplayDebtCapMs = smoothestDisplayDebtCapMs
        self.overwrittenPendingFrames = overwrittenPendingFrames
        self.smoothestQueueDrops = smoothestQueueDrops
        self.smoothestDepthDrops = smoothestDepthDrops
        self.smoothestAgeDrops = smoothestAgeDrops
        self.smoothestDropsUnder100ms = smoothestDropsUnder100ms
        self.smoothestDroppedFrameAgeMaxMs = smoothestDroppedFrameAgeMaxMs
        self.smoothestDisplayDebtDrops = smoothestDisplayDebtDrops
        self.smoothestFifoResetCount = smoothestFifoResetCount
        self.lateFrameDrops = lateFrameDrops
        self.coalescedBeforeSubmitCount = coalescedBeforeSubmitCount
        self.duplicateRemoteTimestampCount = duplicateRemoteTimestampCount
        self.correctedStreamTimestampCount = correctedStreamTimestampCount
        self.displayLayerNotReadyCount = displayLayerNotReadyCount
        self.repeatedFrameCount = repeatedFrameCount
        self.missedVSyncCount = missedVSyncCount
        self.displayTickIntervalP95Ms = displayTickIntervalP95Ms
        self.displayTickIntervalP99Ms = displayTickIntervalP99Ms
        self.playoutDelayFrames = playoutDelayFrames
        self.presentationStallCount = presentationStallCount
        self.worstPresentationGapMs = worstPresentationGapMs
        self.frameIntervalP95Ms = frameIntervalP95Ms
        self.frameIntervalP99Ms = frameIntervalP99Ms
        self.decodeHealthy = decodeHealthy
        self.decodeSubmissionLimit = decodeSubmissionLimit
        self.presentationTier = presentationTier
        self.reassemblerPendingFrameCount = reassemblerPendingFrameCount
        self.reassemblerPendingKeyframeCount = reassemblerPendingKeyframeCount
        self.reassemblerPendingBytes = reassemblerPendingBytes
        self.frameBufferPoolRetainedBytes = frameBufferPoolRetainedBytes
        self.reassemblerBudgetEvictions = reassemblerBudgetEvictions
        self.reassemblerIncompleteFrameTimeouts = reassemblerIncompleteFrameTimeouts
        self.reassemblerIncompleteFrameNoProgressTimeouts = reassemblerIncompleteFrameNoProgressTimeouts
        self.reassemblerIncompleteFrameLifetimeTimeouts = reassemblerIncompleteFrameLifetimeTimeouts
        self.reassemblerMissingFragmentTimeouts = reassemblerMissingFragmentTimeouts
        self.reassemblerForwardGapTimeouts = reassemblerForwardGapTimeouts
        self.decoderOutputPixelFormat = decoderOutputPixelFormat
        self.usingHardwareDecoder = usingHardwareDecoder
        self.targetFrameRate = targetFrameRate
        self.sourceTargetFrameRate = sourceTargetFrameRate ?? targetFrameRate
        self.displayTargetFrameRate = displayTargetFrameRate ?? targetFrameRate
        self.hostMetrics = hostMetrics
        self.videoIngressMetrics = videoIngressMetrics
    }

}

struct ClientStreamingAnomalyDiagnostic: Equatable {
    let bottleneckKind: MirageStreamBottleneckKind
    let label: String
    let message: String

    var signature: String {
        "\(bottleneckKind.rawValue)|\(label)"
    }
}

func clientStreamingAnomalyDiagnostic(
    sample: ClientStreamingAnomalySample
) -> ClientStreamingAnomalyDiagnostic {
    let hostCadencePressure: HostCadencePressureDiagnostic? = if let hostMetrics = sample.hostMetrics {
        hostCadencePressureDiagnostic(sample: HostCadencePressureDiagnosticSample(metrics: hostMetrics))
    } else {
        nil
    }
    let bottleneckKind = resolvedAnomalyBottleneckKind(
        sample: sample,
        hostCadencePressure: hostCadencePressure
    )
    let label = anomalyLabel(
        bottleneckKind: bottleneckKind,
        hostCadencePressure: hostCadencePressure
    )
    let hostTransportDrops = sample.hostMetrics?.transportPressureDropCount ?? 0
    let hostQueuedUnreliableDrops = sample.hostMetrics?.queuedUnreliableDropCount ?? 0
    let hostSenderDrops = hostTransportDrops +
        (sample.hostMetrics?.generationAbortDrops ?? 0) +
        (sample.hostMetrics?.nonKeyframeHoldDrops ?? 0)
    let hostQueueText = sample.hostMetrics?.sendQueueBytes.map { "\((Double($0) / 1024.0).rounded())KB" } ?? "--"
    let hostCaptureText = formattedFPS(sample.hostMetrics?.captureFPS)
    let hostEncodedText = formattedFPS(sample.hostMetrics?.encodedFPS)
    let hostEncodeAttemptText = formattedFPS(sample.hostMetrics?.encodeAttemptFPS)
    let hostCaptureGapP99Text = formattedMs(sample.hostMetrics?.captureCadence?.deliveredFrameGapP99Ms)
    let hostCaptureWorstGapText = formattedMs(sample.hostMetrics?.captureCadence?.deliveredFrameGapWorstMs)
    let hostCaptureDriftText = (sample.hostMetrics?.captureCadence?.displayTimeDriftCount).map(String.init) ?? "--"
    let virtualTimingText = (sample.hostMetrics?.captureCadence?.virtualDisplayTimingSuspect).map { $0 ? "true" : "false" } ?? "--"
    let captureAdmissionDropsText = sample.hostMetrics?.captureAdmissionDrops.map(String.init) ?? "--"
    let awdlQualityReductionText = sample.hostMetrics?.awdlQualityReductionAllowed.map { $0 ? "true" : "false" } ?? "--"
    let videoIngress = sample.videoIngressMetrics
    let decoderFormat = sample.decoderOutputPixelFormat ?? "unknown"
    let hardwareDecoderText = sample.usingHardwareDecoder.map { $0 ? "true" : "false" } ?? "unknown"
    let message =
        "Streaming anomaly (\(sample.trigger)): " +
        "stream=\(sample.streamID) classification=\(label) " +
        "decoded=\(formattedFPS(sample.decodedFPS))fps received=\(formattedFPS(sample.receivedFPS))fps " +
        "receivedWorstGap=\(formattedMs(sample.receivedWorstGapMs))ms " +
        "receivedP95=\(formattedMs(sample.receivedFrameIntervalP95Ms))ms receivedP99=\(formattedMs(sample.receivedFrameIntervalP99Ms))ms " +
        "displayTick=\(formattedFPS(sample.displayTickFPS))fps tickP95=\(formattedMs(sample.displayTickIntervalP95Ms))ms " +
        "tickP99=\(formattedMs(sample.displayTickIntervalP99Ms))ms missedVSync=\(sample.missedVSyncCount) " +
        "submitAttempt=\(formattedFPS(sample.submitAttemptFPS))fps layerAccepted=\(formattedFPS(sample.layerAcceptedFPS))fps " +
        "layerEnqueueFPS=\(formattedFPS(sample.submittedFPS))fps " +
        "uniqueLayerEnqueueFPS=\(formattedFPS(sample.uniqueSubmittedFPS))fps " +
        "visibleFrameFPS=\(formattedFPS(sample.visibleFrameFPS))fps " +
        "submitted=\(formattedFPS(sample.submittedFPS))fps uniqueSubmitted=\(formattedFPS(sample.uniqueSubmittedFPS))fps " +
        "pending=\(sample.pendingFrameCount) pendingAge=\(formattedMs(sample.pendingFrameAgeMs))ms " +
        "pendingAgeP95=\(formattedMs(sample.pendingFrameAgeP95Ms))ms " +
        "pendingAgeMax=\(formattedMs(sample.pendingFrameAgeMaxMs))ms pendingDepthMax=\(sample.pendingFrameDepthMax) " +
        "smoothestDebt=\(formattedMs(sample.smoothestDisplayDebtMs))ms " +
        "smoothestDebtCap=\(formattedMs(sample.smoothestDisplayDebtCapMs))ms " +
        "reassemblerPending=\(sample.reassemblerPendingFrameCount) keyframes=\(sample.reassemblerPendingKeyframeCount) " +
        "reassemblerBytes=\(sample.reassemblerPendingBytes) pooledBytes=\(sample.frameBufferPoolRetainedBytes) " +
        "budgetEvictions=\(sample.reassemblerBudgetEvictions) " +
        "fragmentLossFrames=\(sample.reassemblerIncompleteFrameTimeouts) " +
        "fragmentNoProgress=\(sample.reassemblerIncompleteFrameNoProgressTimeouts) " +
        "fragmentLifetime=\(sample.reassemblerIncompleteFrameLifetimeTimeouts) " +
        "fragmentLossMissing=\(sample.reassemblerMissingFragmentTimeouts) " +
        "forwardGapTimeouts=\(sample.reassemblerForwardGapTimeouts) " +
        "overwritten=\(sample.overwrittenPendingFrames) smoothestDrops=\(sample.smoothestQueueDrops) " +
        "smoothestDepthDrops=\(sample.smoothestDepthDrops) smoothestAgeDrops=\(sample.smoothestAgeDrops) " +
        "smoothestDebtDrops=\(sample.smoothestDisplayDebtDrops) smoothestFifoResets=\(sample.smoothestFifoResetCount) " +
        "smoothestUnder100=\(sample.smoothestDropsUnder100ms) " +
        "smoothestDropAgeMax=\(formattedMs(sample.smoothestDroppedFrameAgeMaxMs))ms " +
        "lateDrops=\(sample.lateFrameDrops) " +
        "coalesced=\(sample.coalescedBeforeSubmitCount) duplicateCapturePTS=\(sample.duplicateRemoteTimestampCount) " +
        "correctedStreamPTS=\(sample.correctedStreamTimestampCount) " +
        "repeated=\(sample.repeatedFrameCount) playoutDelay=\(sample.playoutDelayFrames) " +
        "layerBackpressure=\(sample.displayLayerNotReadyCount) " +
        "clientPacketArrivalP95=\(formattedMs(videoIngress?.incomingBatchIntervalP95Ms))ms " +
        "clientPacketArrivalP99=\(formattedMs(videoIngress?.incomingBatchIntervalP99Ms))ms " +
        "clientPacketArrivalMax=\(formattedMs(videoIngress?.incomingBatchIntervalMaxMs))ms " +
        "ingressQueueAgeMax=\(formattedMs(videoIngress?.queueAgeMaxMs))ms " +
        "ingressWakeDelayMax=\(formattedMs(videoIngress?.processorWakeDelayMaxMs))ms " +
        "ingressRawPPS=\(formattedFPS(videoIngress?.rawPacketIngressPPS)) " +
        "ingressProcessed=\(videoIngress?.processedPacketCount ?? 0) " +
        "ingressStaleDrops=\(videoIngress?.stalePacketDropCount ?? 0) " +
        "ingressOverloadDrops=\(videoIngress?.overloadPacketDropCount ?? 0) " +
        "decodeHealthy=\(sample.decodeHealthy) limit=\(sample.decodeSubmissionLimit) " +
        "tier=\(sample.presentationTier.rawValue) sourceTarget=\(sample.sourceTargetFrameRate) " +
        "displayTarget=\(sample.displayTargetFrameRate) target=\(sample.targetFrameRate) " +
        "decoderFormat=\(decoderFormat) hardwareDecoder=\(hardwareDecoderText) " +
        "hostEncoded=\(hostEncodedText)fps hostCapture=\(hostCaptureText)fps " +
        "hostEncodeAttempt=\(hostEncodeAttemptText)fps captureAdmissionDrops=\(captureAdmissionDropsText) " +
        "hostCaptureGapP99=\(hostCaptureGapP99Text)ms hostCaptureWorstGap=\(hostCaptureWorstGapText)ms " +
        "hostDisplayDrift=\(hostCaptureDriftText) virtualTimingSuspect=\(virtualTimingText) " +
        "hostAwdlState=\(sample.hostMetrics?.awdlPolicyState ?? "--") " +
        "hostAwdlTrigger=\(sample.hostMetrics?.awdlPolicyTrigger ?? "--") " +
        "hostAwdlLever=\(sample.hostMetrics?.awdlSelectedLever ?? "--") " +
        "hostAwdlPlayout=\(formattedMs(sample.hostMetrics?.awdlPlayoutDelayMs))ms " +
        "hostAwdlScale=\(formattedScale(sample.hostMetrics?.awdlResolutionScale)) " +
        "hostAwdlQualityCuts=\(awdlQualityReductionText) " +
        "hostAwdlPacing=\(formattedMbps(sample.hostMetrics?.awdlHostPacingBudgetBps))Mbps " +
        // Idle-vs-wedge distinguishers: high raw-callback + high idle frames with low
        // renderable cadence = benign static content (SCK delivering no-change frames);
        // low raw-callback = SCK starved / wedged virtual display (a real cadence bug).
        "hostRawCallbackFPS=\(formattedFPS(sample.hostMetrics?.captureCadence?.rawScreenCallbackFPS)) " +
        "hostObservedSCKFPS=\(formattedFPS(sample.hostMetrics?.captureCadence?.observedSCKFPS)) " +
        "hostIdleFrames=\(sample.hostMetrics?.captureCadence?.idleFrameCount.map(String.init) ?? "--") " +
        "sendQueue=\(hostQueueText) sendStart=\(formattedMs(sample.hostMetrics?.sendStartDelayAverageMs))ms " +
        "sendDone=\(formattedMs(sample.hostMetrics?.sendCompletionAverageMs))ms " +
        "sendStartMax=\(formattedMs(sample.hostMetrics?.sendStartDelayMaxMs))ms " +
        "sendDoneMax=\(formattedMs(sample.hostMetrics?.sendCompletionMaxMs))ms " +
        "nonKeySendStartMax=\(formattedMs(sample.hostMetrics?.nonKeyframeSendStartDelayMaxMs))ms " +
        "nonKeySendDoneMax=\(formattedMs(sample.hostMetrics?.nonKeyframeSendCompletionMaxMs))ms " +
        "pacer=\(formattedMs(sample.hostMetrics?.packetPacerAverageSleepMs))ms " +
        "pacerTotal=\(sample.hostMetrics?.packetPacerTotalSleepMs.map(String.init) ?? "--")ms " +
        "pacerFrameMax=\(sample.hostMetrics?.packetPacerFrameMaxSleepMs.map(String.init) ?? "--")ms " +
        "transportDrops=\(hostTransportDrops) hostSenderDrops=\(hostSenderDrops) " +
        "senderLocalDeadlineDrops=\(sample.hostMetrics?.senderLocalDeadlineDrops.map(String.init) ?? "--") " +
        "loomQueuedDrops=\(hostQueuedUnreliableDrops) " +
        "loomDeadlineDrops=\(sample.hostMetrics?.queuedUnreliableDeadlineExpiredDrops.map(String.init) ?? "--") " +
        "loomQueueDrops=\(sample.hostMetrics?.queuedUnreliableQueueLimitDrops.map(String.init) ?? "--") " +
        "loomSupersededDrops=\(sample.hostMetrics?.queuedUnreliableSupersededDrops.map(String.init) ?? "--") " +
        "loomUnsupportedTransportDrops=" +
        "\(sample.hostMetrics?.queuedUnreliableUnsupportedTransportDrops.map(String.init) ?? "--") " +
        "loomClosedDrops=\(sample.hostMetrics?.queuedUnreliableClosedDrops.map(String.init) ?? "--") " +
        "presentationStalls=\(sample.presentationStallCount) " +
        "worstPresentationGap=\(formattedMs(sample.worstPresentationGapMs))ms " +
        "frameP95=\(formattedMs(sample.frameIntervalP95Ms))ms frameP99=\(formattedMs(sample.frameIntervalP99Ms))ms"

    return ClientStreamingAnomalyDiagnostic(
        bottleneckKind: bottleneckKind,
        label: label,
        message: message
    )
}

private func resolvedAnomalyBottleneckKind(
    sample: ClientStreamingAnomalySample,
    hostCadencePressure: HostCadencePressureDiagnostic?
) -> MirageStreamBottleneckKind {
    if let hostCadencePressure {
        switch hostCadencePressure.kind {
        case .captureAdmissionPressure,
             .captureCadenceDeficit,
             .encodeAttemptDeficit:
            return .hostCadenceLimited
        case .encodeOverBudget:
            return .encodeBound
        }
    }

    let targetFPS = Double(max(1, sample.targetFrameRate))
    if let hostMetrics = sample.hostMetrics {
        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: max(0, hostMetrics.sendQueueBytes ?? 0),
                queueStressBytes: 800_000,
                packetPacerAverageSleepMs: max(0, hostMetrics.packetPacerAverageSleepMs ?? 0),
                packetPacerStressThresholdMs: 0.75,
                sendStartDelayAverageMs: max(0, hostMetrics.sendStartDelayAverageMs ?? 0),
                sendStartDelayStressThresholdMs: 2.0,
                sendCompletionAverageMs: max(0, hostMetrics.sendCompletionAverageMs ?? 0),
                sendCompletionStressThresholdMs: 12.0,
                transportDropCount: hostMetrics.transportPressureDropCount
            )
        )
        if transportAssessment.primaryStress && !transportAssessment.isPacerOnlyStress {
            return .networkBound
        }
    }

    let decodeGapGrace = max(5.0, targetFPS * 0.10)
    let presentationGapGrace = max(4.0, targetFPS * 0.10)
    let pendingAgeThresholdMs = max(20.0, (1000.0 / targetFPS) * 1.5)
    let decodeGap = max(0, sample.receivedFPS - sample.decodedFPS)
    let sourceOrRecoveryCadenceLimited =
        max(sample.receivedFPS, sample.decodedFPS) > 0 &&
        max(sample.receivedFPS, sample.decodedFPS) < targetFPS * 0.85 &&
        abs(sample.receivedFPS - sample.decodedFPS) <= decodeGapGrace
    if sourceOrRecoveryCadenceLimited {
        return hostCadencePressure == nil ? .unknown : .hostCadenceLimited
    }
    if sample.receivedFPS > 0, decodeGap >= decodeGapGrace {
        return .decodeBound
    }

    let decodeKeepsUp = sample.decodeHealthy &&
        sample.decodedFPS >= targetFPS * 0.75 &&
        (sample.receivedFPS <= 0 || sample.decodedFPS + decodeGapGrace >= sample.receivedFPS)
    let presentationHealthyEnoughToAvoidBlame =
        sample.decodedFPS >= targetFPS - 1.0 &&
        sample.displayTickFPS >= targetFPS - 1.0 &&
        sample.displayLayerNotReadyCount == 0
    let submissionLaggingDecode =
        sample.submittedFPS + presentationGapGrace < sample.decodedFPS ||
        sample.uniqueSubmittedFPS + presentationGapGrace < sample.decodedFPS
    let layerAcceptanceLaggingDecode =
        sample.layerAcceptedFPS + presentationGapGrace < sample.decodedFPS ||
        sample.visibleFrameFPS + presentationGapGrace < sample.decodedFPS
    let rendererLoopStalled =
        sample.submittedFPS >= targetFPS * 0.75 &&
        sample.uniqueSubmittedFPS + presentationGapGrace < sample.submittedFPS &&
        sample.pendingFrameCount > 0
    let presentationBackpressure = sample.overwrittenPendingFrames > 0 ||
        sample.lateFrameDrops > 0 ||
        sample.displayLayerNotReadyCount > 0 ||
        sample.pendingFrameAgeMs >= pendingAgeThresholdMs
    let targetFrameIntervalMs = 1000.0 / targetFPS
    let severeUnevenPresentationCadence =
        sample.worstPresentationGapMs >= max(180.0, targetFrameIntervalMs * 8.0) ||
        sample.frameIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0) ||
        sample.displayTickIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0)
    if decodeKeepsUp,
       layerAcceptanceLaggingDecode,
       sample.presentationTier == .activeLive {
        return .presentationBound
    }
    if !presentationHealthyEnoughToAvoidBlame &&
        (rendererLoopStalled ||
        decodeKeepsUp &&
        (submissionLaggingDecode && presentationBackpressure ||
            severeUnevenPresentationCadence && sample.submittedFPS >= targetFPS * 0.90)) {
        return .presentationBound
    }

    return .unknown
}

private func anomalyLabel(
    bottleneckKind: MirageStreamBottleneckKind,
    hostCadencePressure: HostCadencePressureDiagnostic?
) -> String {
    switch bottleneckKind {
    case .captureBound,
         .encodeBound,
         .hostCadenceLimited:
        if let hostCadencePressure {
            return "host-side \(hostCadencePressure.kind.logLabel)"
        }
        return "source-bound"
    case .decodeBound:
        return "decode-bound"
    case .presentationBound:
        return "presentation-bound"
    case .networkBound:
        return "network-bound"
    case .mixed:
        return "mixed"
    case .unknown:
        if let hostCadencePressure {
            return "host-side \(hostCadencePressure.kind.logLabel)"
        }
        return "unknown"
    }
}

private func formattedFPS(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(1)))
}

private func formattedMs(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(1)))
}

private func formattedScale(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(3)))
}

private func formattedMbps(_ bitrate: Int?) -> String {
    guard let bitrate else { return "--" }
    return (Double(bitrate) / 1_000_000.0).formatted(.number.precision(.fractionLength(1)))
}
