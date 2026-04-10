//
//  HostCadencePressureDiagnostic.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

import Foundation
import MirageKit

struct HostCadencePressureDiagnosticSample: Sendable, Equatable {
    let targetFPS: Int
    let frameBudgetMs: Double?
    let encodedFPS: Double
    let captureAdmissionDrops: UInt64
    let averageEncodeMs: Double?
    let captureIngressFPS: Double?
    let captureFPS: Double?
    let encodeAttemptFPS: Double?
    let queueBytes: Int
    let sendStartDelayAverageMs: Double
    let sendCompletionAverageMs: Double
    let packetPacerAverageSleepMs: Double
    let transportDropCount: UInt64

    init(
        targetFPS: Int,
        frameBudgetMs: Double? = nil,
        encodedFPS: Double,
        captureAdmissionDrops: UInt64 = 0,
        averageEncodeMs: Double? = nil,
        captureIngressFPS: Double? = nil,
        captureFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        queueBytes: Int = 0,
        sendStartDelayAverageMs: Double = 0,
        sendCompletionAverageMs: Double = 0,
        packetPacerAverageSleepMs: Double = 0,
        transportDropCount: UInt64 = 0
    ) {
        self.targetFPS = targetFPS
        self.frameBudgetMs = frameBudgetMs
        self.encodedFPS = encodedFPS
        self.captureAdmissionDrops = captureAdmissionDrops
        self.averageEncodeMs = averageEncodeMs
        self.captureIngressFPS = captureIngressFPS
        self.captureFPS = captureFPS
        self.encodeAttemptFPS = encodeAttemptFPS
        self.queueBytes = max(0, queueBytes)
        self.sendStartDelayAverageMs = max(0, sendStartDelayAverageMs)
        self.sendCompletionAverageMs = max(0, sendCompletionAverageMs)
        self.packetPacerAverageSleepMs = max(0, packetPacerAverageSleepMs)
        self.transportDropCount = transportDropCount
    }

    init(metrics: StreamMetricsMessage) {
        self.init(
            targetFPS: metrics.targetFrameRate,
            frameBudgetMs: metrics.frameBudgetMs,
            encodedFPS: metrics.encodedFPS,
            captureAdmissionDrops: metrics.captureAdmissionDrops ?? 0,
            averageEncodeMs: metrics.averageEncodeMs,
            captureIngressFPS: metrics.captureIngressFPS,
            captureFPS: metrics.captureFPS,
            encodeAttemptFPS: metrics.encodeAttemptFPS,
            queueBytes: metrics.sendQueueBytes ?? 0,
            sendStartDelayAverageMs: metrics.sendStartDelayAverageMs ?? 0,
            sendCompletionAverageMs: metrics.sendCompletionAverageMs ?? 0,
            packetPacerAverageSleepMs: metrics.packetPacerAverageSleepMs ?? 0,
            transportDropCount: (metrics.stalePacketDrops ?? 0) +
                (metrics.generationAbortDrops ?? 0) +
                (metrics.nonKeyframeHoldDrops ?? 0)
        )
    }
}

enum HostCadencePressureDiagnosticKind: String, Sendable, Equatable {
    case captureAdmissionPressure
    case encodeAttemptDeficit
    case encodeOverBudget
    case captureCadenceDeficit

    var logLabel: String {
        switch self {
        case .captureAdmissionPressure:
            "capture-admission pressure"
        case .encodeAttemptDeficit:
            "encode-attempt deficit"
        case .encodeOverBudget:
            "encode over-budget"
        case .captureCadenceDeficit:
            "capture cadence deficit"
        }
    }
}

struct HostCadencePressureDiagnostic: Sendable, Equatable {
    let kind: HostCadencePressureDiagnosticKind
    let summary: String

    var signature: String { kind.rawValue }
}

func hostCadencePressureDiagnostic(
    sample: HostCadencePressureDiagnosticSample?
) -> HostCadencePressureDiagnostic? {
    guard let sample else { return nil }

    let targetFPS = Double(max(1, sample.targetFPS))
    let encodedFPS = max(0, sample.encodedFPS)
    let captureIngressFPS = max(0, sample.captureIngressFPS ?? 0)
    let captureFPS = max(0, sample.captureFPS ?? 0)
    let encodeAttemptFPS = max(0, sample.encodeAttemptFPS ?? 0)
    let frameBudgetMs = max(0, sample.frameBudgetMs ?? 0)
    let averageEncodeMs = max(0, sample.averageEncodeMs ?? 0)
    let fpsGapGrace = max(4.0, targetFPS * 0.08)
    let captureHealthy = (captureIngressFPS <= 0 || captureIngressFPS + fpsGapGrace >= targetFPS) &&
        (captureFPS <= 0 || captureFPS + fpsGapGrace >= targetFPS)
    let encodedDeficit = encodedFPS > 0 && encodedFPS + fpsGapGrace < targetFPS
    guard encodedDeficit else { return nil }

    let transportAssessment = MirageTransportPressure.assess(
        sample: MirageTransportPressureSample(
            queueBytes: sample.queueBytes,
            queueStressBytes: 800_000,
            queueSevereBytes: 2_000_000,
            packetPacerAverageSleepMs: sample.packetPacerAverageSleepMs,
            packetPacerStressThresholdMs: 0.75,
            packetPacerSevereThresholdMs: 2.0,
            sendStartDelayAverageMs: sample.sendStartDelayAverageMs,
            sendStartDelayStressThresholdMs: 2.0,
            sendStartDelaySevereThresholdMs: 6.0,
            sendCompletionAverageMs: sample.sendCompletionAverageMs,
            sendCompletionStressThresholdMs: 12.0,
            sendCompletionSevereThresholdMs: 28.0,
            transportDropCount: sample.transportDropCount,
            transportDropSevereCount: 12
        )
    )
    guard !transportAssessment.isStress || transportAssessment.isPacerOnlyStress else { return nil }

    let captureText = captureFPS.formatted(.number.precision(.fractionLength(1)))
    let attemptText = encodeAttemptFPS.formatted(.number.precision(.fractionLength(1)))
    let encodedText = encodedFPS.formatted(.number.precision(.fractionLength(1)))
    let averageEncodeText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
    let queueKB = Int((Double(sample.queueBytes) / 1024.0).rounded())
    let transportTokens = transportAssessment.isPacerOnlyStress
        ? ""
        : transportAssessment.reasonTokens.joined(separator: ",")
    let transportText = transportTokens.isEmpty ? "clean" : transportTokens
    let sharedSummary =
        "hostCapture=\(captureText)fps hostEncodeAttempt=\(attemptText)fps hostEncoded=\(encodedText)fps " +
        "captureAdmissionDrops=\(sample.captureAdmissionDrops) encodeAvg=\(averageEncodeText)ms " +
        "queue=\(queueKB)KB sendStart=\(sample.sendStartDelayAverageMs.formatted(.number.precision(.fractionLength(1))))ms " +
        "sendDone=\(sample.sendCompletionAverageMs.formatted(.number.precision(.fractionLength(1))))ms " +
        "pacer=\(sample.packetPacerAverageSleepMs.formatted(.number.precision(.fractionLength(1))))ms transport=\(transportText)"

    if captureHealthy,
       sample.captureAdmissionDrops > 0,
       encodeAttemptFPS > 0,
       encodeAttemptFPS + fpsGapGrace < targetFPS {
        return HostCadencePressureDiagnostic(
            kind: .captureAdmissionPressure,
            summary: sharedSummary
        )
    }

    if captureHealthy,
       encodeAttemptFPS > 0,
       encodeAttemptFPS + fpsGapGrace < targetFPS {
        return HostCadencePressureDiagnostic(
            kind: .encodeAttemptDeficit,
            summary: sharedSummary
        )
    }

    if captureHealthy,
       frameBudgetMs > 0,
       averageEncodeMs > frameBudgetMs * 1.05 {
        return HostCadencePressureDiagnostic(
            kind: .encodeOverBudget,
            summary: sharedSummary
        )
    }

    if captureIngressFPS > 0, captureIngressFPS + fpsGapGrace < targetFPS {
        return HostCadencePressureDiagnostic(
            kind: .captureCadenceDeficit,
            summary: sharedSummary
        )
    }

    if captureFPS > 0, captureFPS + fpsGapGrace < targetFPS {
        return HostCadencePressureDiagnostic(
            kind: .captureCadenceDeficit,
            summary: sharedSummary
        )
    }

    return nil
}

func sourceBoundDecodeSubmissionDiagnosticMessage(
    decodedFPS: Double,
    receivedFPS: Double,
    targetFPS: Int,
    hostCadencePressure: HostCadencePressureDiagnostic?
) -> String {
    let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
    let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
    if let hostCadencePressure {
        return "Decode submission stress classified as host-side \(hostCadencePressure.kind.logLabel) " +
            "(decoded \(decodedText)fps, received \(receivedText)fps, target \(targetFPS)fps, \(hostCadencePressure.summary))"
    }
    return "Decode submission stress classified as source-bound " +
        "(decoded \(decodedText)fps, received \(receivedText)fps, target \(targetFPS)fps)"
}
