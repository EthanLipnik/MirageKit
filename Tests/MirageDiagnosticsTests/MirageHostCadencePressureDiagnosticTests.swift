//
//  MirageHostCadencePressureDiagnosticTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageDiagnostics
import Testing

@Suite("Mirage Host Cadence Pressure Diagnostic")
struct MirageHostCadencePressureDiagnosticTests {
    @Test("Clean transport capture-admission collapse is classified as host pressure")
    func cleanTransportCaptureAdmissionCollapseIsClassifiedAsHostPressure() {
        let diagnostic = mirageHostCadencePressureDiagnostic(
            sample: MirageHostCadencePressureDiagnosticSample(
                targetFPS: 60,
                frameBudgetMs: 16.67,
                encodedFPS: 29,
                captureAdmissionDrops: 31,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 29,
                queueBytes: 0,
                sendStartDelayAverageMs: 0.2,
                sendCompletionAverageMs: 1.1,
                packetPacerAverageSleepMs: 0.1,
                transportDropCount: 0
            )
        )

        #expect(diagnostic?.kind == .captureAdmissionPressure)
        #expect(diagnostic?.kind.logLabel == "capture-admission pressure")
    }

    @Test("Clean transport encode-attempt deficit is classified as host pressure")
    func cleanTransportEncodeAttemptDeficitIsClassifiedAsHostPressure() {
        let diagnostic = mirageHostCadencePressureDiagnostic(
            sample: MirageHostCadencePressureDiagnosticSample(
                targetFPS: 60,
                frameBudgetMs: 16.67,
                encodedFPS: 29,
                captureAdmissionDrops: 0,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 30,
                queueBytes: 0,
                sendStartDelayAverageMs: 0.2,
                sendCompletionAverageMs: 1.0,
                packetPacerAverageSleepMs: 0.1,
                transportDropCount: 0
            )
        )

        #expect(diagnostic?.kind == .encodeAttemptDeficit)
    }

    @Test("Transport-stressed sample does not produce host-side cadence pressure diagnostic")
    func transportStressedSampleDoesNotProduceHostPressureDiagnostic() {
        let diagnostic = mirageHostCadencePressureDiagnostic(
            sample: MirageHostCadencePressureDiagnosticSample(
                targetFPS: 60,
                frameBudgetMs: 16.67,
                encodedFPS: 29,
                captureAdmissionDrops: 31,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 29,
                queueBytes: 1_600_000,
                sendStartDelayAverageMs: 3.0,
                sendCompletionAverageMs: 16.0,
                packetPacerAverageSleepMs: 1.5,
                transportDropCount: 4
            )
        )

        #expect(diagnostic == nil)
    }

    @Test("Packet pacer pressure alone still reports host-side cadence pressure")
    func packetPacerPressureAloneStillReportsHostPressure() {
        let diagnostic = mirageHostCadencePressureDiagnostic(
            sample: MirageHostCadencePressureDiagnosticSample(
                targetFPS: 60,
                frameBudgetMs: 16.67,
                encodedFPS: 29,
                captureAdmissionDrops: 31,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 29,
                queueBytes: 0,
                sendStartDelayAverageMs: 0.2,
                sendCompletionAverageMs: 1.1,
                packetPacerAverageSleepMs: 1.0,
                transportDropCount: 0
            )
        )

        #expect(diagnostic?.kind == .captureAdmissionPressure)
    }
}
