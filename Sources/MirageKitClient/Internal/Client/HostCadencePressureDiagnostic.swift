import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageHostCadencePressureDiagnostic.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

extension MirageHostCadencePressureDiagnosticSample {
    init(metrics: MirageWire.StreamMetricsMessage) {
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
            transportDropCount: metrics.transportPressureDropCount
        )
    }
}

func hostCadencePressureDiagnostic(
    sample: MirageHostCadencePressureDiagnosticSample?
) -> MirageHostCadencePressureDiagnostic? {
    mirageHostCadencePressureDiagnostic(sample: sample)
}
