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
    let submittedFPS: Double
    let uniqueSubmittedFPS: Double
    let pendingFrameCount: Int
    let pendingFrameAgeMs: Double
    let overwrittenPendingFrames: UInt64
    let displayLayerNotReadyCount: UInt64
    let decodeHealthy: Bool
    let decodeSubmissionLimit: Int
    let presentationTier: StreamPresentationTier
    let decoderOutputPixelFormat: String?
    let usingHardwareDecoder: Bool?
    let targetFrameRate: Int
    let hostMetrics: StreamMetricsMessage?

    fileprivate func metricsSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            submittedFPS: submittedFPS,
            uniqueSubmittedFPS: uniqueSubmittedFPS,
            pendingFrameCount: pendingFrameCount,
            clientPendingFrameAgeMs: pendingFrameAgeMs,
            clientOverwrittenPendingFrames: overwrittenPendingFrames,
            clientDisplayLayerNotReadyCount: displayLayerNotReadyCount,
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
        snapshot.hostPacketPacerMaxSleepMs = hostMetrics?.packetPacerMaxSleepMs
        snapshot.hostStalePacketDrops = hostMetrics?.stalePacketDrops
        snapshot.hostGenerationAbortDrops = hostMetrics?.generationAbortDrops
        snapshot.hostNonKeyframeHoldDrops = hostMetrics?.nonKeyframeHoldDrops
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
    let captureAdmissionDropsText = sample.hostMetrics?.captureAdmissionDrops.map(String.init) ?? "--"
    let decoderFormat = sample.decoderOutputPixelFormat ?? "unknown"
    let hardwareDecoderText = sample.usingHardwareDecoder.map { $0 ? "true" : "false" } ?? "unknown"
    let message =
        "Streaming anomaly (\(sample.trigger)): " +
        "stream=\(sample.streamID) classification=\(label) " +
        "decoded=\(formattedFPS(sample.decodedFPS))fps received=\(formattedFPS(sample.receivedFPS))fps " +
        "submitted=\(formattedFPS(sample.submittedFPS))fps uniqueSubmitted=\(formattedFPS(sample.uniqueSubmittedFPS))fps " +
        "pending=\(sample.pendingFrameCount) pendingAge=\(formattedMs(sample.pendingFrameAgeMs))ms " +
        "overwritten=\(sample.overwrittenPendingFrames) layerBackpressure=\(sample.displayLayerNotReadyCount) " +
        "decodeHealthy=\(sample.decodeHealthy) limit=\(sample.decodeSubmissionLimit) " +
        "tier=\(sample.presentationTier.rawValue) target=\(sample.targetFrameRate) " +
        "decoderFormat=\(decoderFormat) hardwareDecoder=\(hardwareDecoderText) " +
        "hostEncoded=\(hostEncodedText)fps hostCapture=\(hostCaptureText)fps " +
        "hostEncodeAttempt=\(hostEncodeAttemptText)fps captureAdmissionDrops=\(captureAdmissionDropsText) " +
        "sendQueue=\(hostQueueText) sendStart=\(formattedMs(sample.hostMetrics?.sendStartDelayAverageMs))ms " +
        "sendDone=\(formattedMs(sample.hostMetrics?.sendCompletionAverageMs))ms " +
        "pacer=\(formattedMs(sample.hostMetrics?.packetPacerAverageSleepMs))ms transportDrops=\(hostTransportDrops)"

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
    if decodeKeepsUp && submissionLaggingDecode && presentationBackpressure {
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
