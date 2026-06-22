//
//  MirageHostCadencePressureDiagnostic.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

package struct MirageHostCadencePressureDiagnosticSample: Sendable, Equatable {
    package let targetFPS: Int
    package let frameBudgetMs: Double?
    package let encodedFPS: Double
    package let captureAdmissionDrops: UInt64
    package let averageEncodeMs: Double?
    package let captureIngressFPS: Double?
    package let captureFPS: Double?
    package let encodeAttemptFPS: Double?
    package let queueBytes: Int
    package let sendStartDelayAverageMs: Double
    package let sendCompletionAverageMs: Double
    package let packetPacerAverageSleepMs: Double
    package let transportDropCount: UInt64
    package let transportAdmissionSkips: UInt64
    package let transportAdmissionActiveHoldMs: Double

    package init(
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
        transportDropCount: UInt64 = 0,
        transportAdmissionSkips: UInt64 = 0,
        transportAdmissionActiveHoldMs: Double = 0
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
        self.transportAdmissionSkips = transportAdmissionSkips
        self.transportAdmissionActiveHoldMs = max(0, transportAdmissionActiveHoldMs)
    }
}

package enum MirageHostCadencePressureDiagnosticKind: String, Sendable, Equatable {
    case captureAdmissionPressure
    case encodeAttemptDeficit
    case encodeOverBudget
    case captureCadenceDeficit

    package var logLabel: String {
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

package struct MirageHostCadencePressureDiagnostic: Sendable, Equatable {
    package let kind: MirageHostCadencePressureDiagnosticKind

    package init(kind: MirageHostCadencePressureDiagnosticKind) {
        self.kind = kind
    }
}

package func mirageHostCadencePressureDiagnostic(
    sample: MirageHostCadencePressureDiagnosticSample?
) -> MirageHostCadencePressureDiagnostic? {
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
    guard sample.transportAdmissionSkips == 0,
          sample.transportAdmissionActiveHoldMs <= 0 else {
        return nil
    }

    let transportAssessment = MirageTransportPressure.assess(
        sample: MirageTransportPressureSample(
            queueBytes: sample.queueBytes,
            queueStressBytes: 800_000,
            packetPacerAverageSleepMs: sample.packetPacerAverageSleepMs,
            packetPacerStressThresholdMs: 0.75,
            sendStartDelayAverageMs: sample.sendStartDelayAverageMs,
            sendStartDelayStressThresholdMs: 2.0,
            sendCompletionAverageMs: sample.sendCompletionAverageMs,
            sendCompletionStressThresholdMs: 12.0,
            transportDropCount: sample.transportDropCount
        )
    )
    guard !transportAssessment.primaryStress || transportAssessment.isPacerOnlyStress else { return nil }

    if captureHealthy,
       sample.captureAdmissionDrops > 0,
       encodeAttemptFPS > 0,
       encodeAttemptFPS + fpsGapGrace < targetFPS {
        return MirageHostCadencePressureDiagnostic(
            kind: .captureAdmissionPressure
        )
    }

    if captureHealthy,
       encodeAttemptFPS > 0,
       encodeAttemptFPS + fpsGapGrace < targetFPS {
        return MirageHostCadencePressureDiagnostic(
            kind: .encodeAttemptDeficit
        )
    }

    if captureHealthy,
       frameBudgetMs > 0,
       averageEncodeMs > frameBudgetMs * 1.05 {
        return MirageHostCadencePressureDiagnostic(
            kind: .encodeOverBudget
        )
    }

    if captureIngressFPS > 0, captureIngressFPS + fpsGapGrace < targetFPS {
        return MirageHostCadencePressureDiagnostic(
            kind: .captureCadenceDeficit
        )
    }

    if captureFPS > 0, captureFPS + fpsGapGrace < targetFPS {
        return MirageHostCadencePressureDiagnostic(
            kind: .captureCadenceDeficit
        )
    }

    return nil
}
