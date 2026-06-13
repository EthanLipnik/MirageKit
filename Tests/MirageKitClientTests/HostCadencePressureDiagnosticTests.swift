//
//  HostCadencePressureDiagnosticTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Host Cadence Pressure Diagnostic")
struct HostCadencePressureDiagnosticTests {
    @Test("Clean transport capture-admission collapse is classified as host pressure")
    func cleanTransportCaptureAdmissionCollapseIsClassifiedAsHostPressure() {
        let diagnostic = hostCadencePressureDiagnostic(
            sample: HostCadencePressureDiagnosticSample(
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
    }

    @Test("Clean transport encode-attempt deficit is classified as host pressure")
    func cleanTransportEncodeAttemptDeficitIsClassifiedAsHostPressure() {
        let diagnostic = hostCadencePressureDiagnostic(
            sample: HostCadencePressureDiagnosticSample(
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
        let diagnostic = hostCadencePressureDiagnostic(
            sample: HostCadencePressureDiagnosticSample(
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
        let diagnostic = hostCadencePressureDiagnostic(
            sample: HostCadencePressureDiagnosticSample(
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

    @Test("Transport admission pacing suppresses host cadence pressure diagnostic")
    func transportAdmissionPacingSuppressesHostCadencePressureDiagnostic() {
        let diagnostic = hostCadencePressureDiagnostic(
            sample: HostCadencePressureDiagnosticSample(
                targetFPS: 60,
                frameBudgetMs: 16.67,
                encodedFPS: 29,
                captureAdmissionDrops: 0,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 29,
                queueBytes: 0,
                sendStartDelayAverageMs: 0.2,
                sendCompletionAverageMs: 1.0,
                packetPacerAverageSleepMs: 0.1,
                transportDropCount: 0,
                transportAdmissionSkips: 31,
                transportAdmissionActiveHoldMs: 750
            )
        )

        #expect(diagnostic == nil)
    }
}
#endif
