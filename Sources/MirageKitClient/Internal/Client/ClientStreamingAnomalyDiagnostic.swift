//
//  ClientStreamingAnomalyDiagnostic.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

import Foundation
import MirageKit

struct ClientStreamingAnomalySample: Sendable {
    let streamID: StreamID
    let trigger: String
    let decodedFPS: Double
    let receivedFPS: Double
    let receivedWorstGapMs: Double
    let receivedFrameIntervalP95Ms: Double
    let receivedFrameIntervalP99Ms: Double
    let submittedFPS: Double
    let uniqueSubmittedFPS: Double
    let pendingFrameCount: Int
    let pendingFrameAgeMs: Double
    let overwrittenPendingFrames: UInt64
    let displayLayerNotReadyCount: UInt64
    let presentationStallCount: UInt64
    let worstPresentationGapMs: Double
    let frameIntervalP95Ms: Double
    let frameIntervalP99Ms: Double
    let decodeHealthy: Bool
    let decodeSubmissionLimit: Int
    let presentationTier: StreamPresentationTier
    let decoderOutputPixelFormat: String?
    let usingHardwareDecoder: Bool?
    let targetFrameRate: Int
    let hostMetrics: StreamMetricsMessage?

    init(
        streamID: StreamID,
        trigger: String,
        decodedFPS: Double,
        receivedFPS: Double,
        receivedWorstGapMs: Double = 0,
        receivedFrameIntervalP95Ms: Double = 0,
        receivedFrameIntervalP99Ms: Double = 0,
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        overwrittenPendingFrames: UInt64,
        displayLayerNotReadyCount: UInt64,
        presentationStallCount: UInt64 = 0,
        worstPresentationGapMs: Double = 0,
        frameIntervalP95Ms: Double = 0,
        frameIntervalP99Ms: Double = 0,
        decodeHealthy: Bool,
        decodeSubmissionLimit: Int,
        presentationTier: StreamPresentationTier,
        decoderOutputPixelFormat: String?,
        usingHardwareDecoder: Bool?,
        targetFrameRate: Int,
        hostMetrics: StreamMetricsMessage?
    ) {
        self.streamID = streamID
        self.trigger = trigger
        self.decodedFPS = decodedFPS
        self.receivedFPS = receivedFPS
        self.receivedWorstGapMs = receivedWorstGapMs
        self.receivedFrameIntervalP95Ms = receivedFrameIntervalP95Ms
        self.receivedFrameIntervalP99Ms = receivedFrameIntervalP99Ms
        self.submittedFPS = submittedFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS
        self.pendingFrameCount = pendingFrameCount
        self.pendingFrameAgeMs = pendingFrameAgeMs
        self.overwrittenPendingFrames = overwrittenPendingFrames
        self.displayLayerNotReadyCount = displayLayerNotReadyCount
        self.presentationStallCount = presentationStallCount
        self.worstPresentationGapMs = worstPresentationGapMs
        self.frameIntervalP95Ms = frameIntervalP95Ms
        self.frameIntervalP99Ms = frameIntervalP99Ms
        self.decodeHealthy = decodeHealthy
        self.decodeSubmissionLimit = decodeSubmissionLimit
        self.presentationTier = presentationTier
        self.decoderOutputPixelFormat = decoderOutputPixelFormat
        self.usingHardwareDecoder = usingHardwareDecoder
        self.targetFrameRate = targetFrameRate
        self.hostMetrics = hostMetrics
    }

    fileprivate func metricsSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            clientReceivedWorstGapMs: receivedWorstGapMs,
            clientReceivedFrameIntervalP95Ms: receivedFrameIntervalP95Ms,
            clientReceivedFrameIntervalP99Ms: receivedFrameIntervalP99Ms,
            submittedFPS: submittedFPS,
            uniqueSubmittedFPS: uniqueSubmittedFPS,
            pendingFrameCount: pendingFrameCount,
            clientPendingFrameAgeMs: pendingFrameAgeMs,
            clientOverwrittenPendingFrames: overwrittenPendingFrames,
            clientDisplayLayerNotReadyCount: displayLayerNotReadyCount,
            clientPresentationStallCount: presentationStallCount,
            clientWorstPresentationGapMs: worstPresentationGapMs,
            clientFrameIntervalP95Ms: frameIntervalP95Ms,
            clientFrameIntervalP99Ms: frameIntervalP99Ms,
            decodeHealthy: decodeHealthy,
            hostEncodedFPS: hostMetrics?.encodedFPS ?? 0,
            hostIdleFPS: hostMetrics?.idleEncodedFPS ?? 0,
            hostDroppedFrames: hostMetrics?.droppedFrames ?? 0,
            hostActiveQuality: hostMetrics.map { Double($0.activeQuality) } ?? 0,
            hostTargetFrameRate: hostMetrics?.targetFrameRate ?? targetFrameRate,
            hostEnteredBitrate: hostMetrics?.enteredBitrate,
            hostCurrentBitrate: hostMetrics?.currentBitrate,
            hostRequestedTargetBitrate: hostMetrics?.requestedTargetBitrate,
            hostBitrateAdaptationCeiling: hostMetrics?.bitrateAdaptationCeiling,
            hostStartupBitrate: hostMetrics?.startupBitrate,
            hostCaptureAdmissionDrops: hostMetrics?.captureAdmissionDrops,
            hostFrameBudgetMs: hostMetrics?.frameBudgetMs,
            hostAverageEncodeMs: hostMetrics?.averageEncodeMs,
            hostCaptureIngressFPS: hostMetrics?.captureIngressFPS,
            hostCaptureFPS: hostMetrics?.captureFPS,
            hostEncodeAttemptFPS: hostMetrics?.encodeAttemptFPS,
            hostUsingHardwareEncoder: hostMetrics?.usingHardwareEncoder,
            hostEncoderGPURegistryID: hostMetrics?.encoderGPURegistryID,
            hostEncodedWidth: hostMetrics?.encodedWidth,
            hostEncodedHeight: hostMetrics?.encodedHeight,
            hostCapturePixelFormat: hostMetrics?.capturePixelFormat,
            hostCaptureColorPrimaries: hostMetrics?.captureColorPrimaries,
            hostEncoderPixelFormat: hostMetrics?.encoderPixelFormat,
            hostEncoderChromaSampling: hostMetrics?.encoderChromaSampling,
            hostEncoderProfile: hostMetrics?.encoderProfile,
            hostEncoderColorPrimaries: hostMetrics?.encoderColorPrimaries,
            hostEncoderTransferFunction: hostMetrics?.encoderTransferFunction,
            hostEncoderYCbCrMatrix: hostMetrics?.encoderYCbCrMatrix,
            hostDisplayP3CoverageStatus: hostMetrics?.displayP3CoverageStatus,
            hostTenBitDisplayP3Validated: hostMetrics?.tenBitDisplayP3Validated,
            hostUltra444Validated: hostMetrics?.ultra444Validated,
            clientDecoderOutputPixelFormat: decoderOutputPixelFormat,
            clientUsingHardwareDecoder: usingHardwareDecoder,
            hasHostMetrics: hostMetrics != nil
        )
        snapshot.hostCaptureIngressAverageMs = hostMetrics?.captureIngressAverageMs
        snapshot.hostCaptureIngressMaxMs = hostMetrics?.captureIngressMaxMs
        snapshot.hostPreEncodeWaitAverageMs = hostMetrics?.preEncodeWaitAverageMs
        snapshot.hostPreEncodeWaitMaxMs = hostMetrics?.preEncodeWaitMaxMs
        snapshot.hostCaptureCallbackAverageMs = hostMetrics?.captureCallbackAverageMs
        snapshot.hostCaptureCallbackMaxMs = hostMetrics?.captureCallbackMaxMs
        snapshot.hostSendQueueBytes = hostMetrics?.sendQueueBytes
        snapshot.hostSendStartDelayAverageMs = hostMetrics?.sendStartDelayAverageMs
        snapshot.hostSendStartDelayMaxMs = hostMetrics?.sendStartDelayMaxMs
        snapshot.hostSendCompletionAverageMs = hostMetrics?.sendCompletionAverageMs
        snapshot.hostSendCompletionMaxMs = hostMetrics?.sendCompletionMaxMs
        snapshot.hostPacketPacerAverageSleepMs = hostMetrics?.packetPacerAverageSleepMs
        snapshot.hostPacketPacerTotalSleepMs = hostMetrics?.packetPacerTotalSleepMs
        snapshot.hostPacketPacerMaxSleepMs = hostMetrics?.packetPacerMaxSleepMs
        snapshot.hostPacketPacerFrameMaxSleepMs = hostMetrics?.packetPacerFrameMaxSleepMs
        snapshot.hostStalePacketDrops = hostMetrics?.stalePacketDrops
        snapshot.hostGenerationAbortDrops = hostMetrics?.generationAbortDrops
        snapshot.hostNonKeyframeHoldDrops = hostMetrics?.nonKeyframeHoldDrops
        snapshot.applyHostCaptureCadence(hostMetrics?.captureCadence)
        return snapshot
    }
}

struct ClientStreamingAnomalyDiagnostic: Sendable, Equatable {
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
    let snapshot = sample.metricsSnapshot()
    let hostCadencePressure: HostCadencePressureDiagnostic? = if let hostMetrics = sample.hostMetrics {
        hostCadencePressureDiagnostic(sample: HostCadencePressureDiagnosticSample(metrics: hostMetrics))
    } else {
        nil
    }
    let bottleneckKind = resolvedAnomalyBottleneckKind(
        sample: sample,
        snapshot: snapshot,
        hostCadencePressure: hostCadencePressure
    )
    let label = anomalyLabel(
        bottleneckKind: bottleneckKind,
        hostCadencePressure: hostCadencePressure
    )
    let hostTransportDrops = resolvedTransportDropCount(metrics: sample.hostMetrics)
    let hostQueueText = sample.hostMetrics?.sendQueueBytes.map { "\((Double($0) / 1024.0).rounded())KB" } ?? "--"
    let hostCaptureText = formattedFPS(sample.hostMetrics?.captureFPS)
    let hostEncodedText = formattedFPS(sample.hostMetrics?.encodedFPS)
    let hostEncodeAttemptText = formattedFPS(sample.hostMetrics?.encodeAttemptFPS)
    let hostCaptureGapP99Text = formattedMs(sample.hostMetrics?.captureCadence?.deliveredFrameGapP99Ms)
    let hostCaptureWorstGapText = formattedMs(sample.hostMetrics?.captureCadence?.deliveredFrameGapWorstMs)
    let hostCaptureDriftText = (sample.hostMetrics?.captureCadence?.displayTimeDriftCount).map(String.init) ?? "--"
    let virtualTimingText = (sample.hostMetrics?.captureCadence?.virtualDisplayTimingSuspect).map { $0 ? "true" : "false" } ?? "--"
    let captureAdmissionDropsText = sample.hostMetrics?.captureAdmissionDrops.map(String.init) ?? "--"
    let decoderFormat = sample.decoderOutputPixelFormat ?? "unknown"
    let hardwareDecoderText = sample.usingHardwareDecoder.map { $0 ? "true" : "false" } ?? "unknown"
    let message =
        "Streaming anomaly (\(sample.trigger)): " +
        "stream=\(sample.streamID) classification=\(label) " +
        "decoded=\(formattedFPS(sample.decodedFPS))fps received=\(formattedFPS(sample.receivedFPS))fps " +
        "receivedWorstGap=\(formattedMs(sample.receivedWorstGapMs))ms " +
        "receivedP95=\(formattedMs(sample.receivedFrameIntervalP95Ms))ms receivedP99=\(formattedMs(sample.receivedFrameIntervalP99Ms))ms " +
        "submitted=\(formattedFPS(sample.submittedFPS))fps uniqueSubmitted=\(formattedFPS(sample.uniqueSubmittedFPS))fps " +
        "pending=\(sample.pendingFrameCount) pendingAge=\(formattedMs(sample.pendingFrameAgeMs))ms " +
        "overwritten=\(sample.overwrittenPendingFrames) layerBackpressure=\(sample.displayLayerNotReadyCount) " +
        "decodeHealthy=\(sample.decodeHealthy) limit=\(sample.decodeSubmissionLimit) " +
        "tier=\(sample.presentationTier.rawValue) target=\(sample.targetFrameRate) " +
        "decoderFormat=\(decoderFormat) hardwareDecoder=\(hardwareDecoderText) " +
        "hostEncoded=\(hostEncodedText)fps hostCapture=\(hostCaptureText)fps " +
        "hostEncodeAttempt=\(hostEncodeAttemptText)fps captureAdmissionDrops=\(captureAdmissionDropsText) " +
        "hostCaptureGapP99=\(hostCaptureGapP99Text)ms hostCaptureWorstGap=\(hostCaptureWorstGapText)ms " +
        "hostDisplayDrift=\(hostCaptureDriftText) virtualTimingSuspect=\(virtualTimingText) " +
        "sendQueue=\(hostQueueText) sendStart=\(formattedMs(sample.hostMetrics?.sendStartDelayAverageMs))ms " +
        "sendDone=\(formattedMs(sample.hostMetrics?.sendCompletionAverageMs))ms " +
        "sendStartMax=\(formattedMs(sample.hostMetrics?.sendStartDelayMaxMs))ms " +
        "sendDoneMax=\(formattedMs(sample.hostMetrics?.sendCompletionMaxMs))ms " +
        "pacer=\(formattedMs(sample.hostMetrics?.packetPacerAverageSleepMs))ms " +
        "pacerTotal=\(sample.hostMetrics?.packetPacerTotalSleepMs.map(String.init) ?? "--")ms " +
        "pacerFrameMax=\(sample.hostMetrics?.packetPacerFrameMaxSleepMs.map(String.init) ?? "--")ms " +
        "transportDrops=\(hostTransportDrops) " +
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
    snapshot: MirageClientMetricsSnapshot,
    hostCadencePressure: HostCadencePressureDiagnostic?
) -> MirageStreamBottleneckKind {
    let classified = MirageStreamBottleneckKind.classify(snapshot: snapshot)
    guard classified == .unknown else { return classified }

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
    let decodeGapGrace = max(5.0, targetFPS * 0.10)
    let presentationGapGrace = max(4.0, targetFPS * 0.10)
    let pendingAgeThresholdMs = max(20.0, (1_000.0 / targetFPS) * 1.5)
    let decodeGap = max(0, sample.receivedFPS - sample.decodedFPS)
    if sample.receivedFPS > 0, decodeGap >= decodeGapGrace {
        return .decodeBound
    }

    let decodeKeepsUp = sample.decodeHealthy &&
        sample.decodedFPS >= targetFPS * 0.75 &&
        (sample.receivedFPS <= 0 || sample.decodedFPS + decodeGapGrace >= sample.receivedFPS)
    let submissionLaggingDecode =
        sample.submittedFPS + presentationGapGrace < sample.decodedFPS ||
        sample.uniqueSubmittedFPS + presentationGapGrace < sample.decodedFPS
    let presentationBackpressure = sample.overwrittenPendingFrames > 0 ||
        sample.displayLayerNotReadyCount > 0 ||
        sample.pendingFrameAgeMs >= pendingAgeThresholdMs
    let targetFrameIntervalMs = 1_000.0 / targetFPS
    let severeUnevenPresentationCadence =
        sample.worstPresentationGapMs >= max(180.0, targetFrameIntervalMs * 8.0) ||
        sample.frameIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0)
    if decodeKeepsUp && (
        submissionLaggingDecode && presentationBackpressure ||
            severeUnevenPresentationCadence && sample.submittedFPS >= targetFPS * 0.90
    ) {
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

private func resolvedTransportDropCount(metrics: StreamMetricsMessage?) -> UInt64 {
    (metrics?.stalePacketDrops ?? 0) +
        (metrics?.generationAbortDrops ?? 0) +
        (metrics?.nonKeyframeHoldDrops ?? 0)
}

private func formattedFPS(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(1)))
}

private func formattedMs(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(1)))
}
