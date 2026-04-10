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

    @Test("Source-bound diagnostic message includes host-side pressure details")
    func sourceBoundDiagnosticMessageIncludesHostPressureDetails() {
        let message = sourceBoundDecodeSubmissionDiagnosticMessage(
            decodedFPS: 29,
            receivedFPS: 29,
            targetFPS: 60,
            hostCadencePressure: HostCadencePressureDiagnostic(
                kind: .captureAdmissionPressure,
                summary: "hostCapture=60.0fps hostEncodeAttempt=29.0fps hostEncoded=29.0fps captureAdmissionDrops=31 encodeAvg=11.5ms queue=0KB sendStart=0.2ms sendDone=1.1ms pacer=0.1ms transport=clean"
            )
        )

        #expect(message.contains("host-side capture-admission pressure"))
        #expect(message.contains("captureAdmissionDrops=31"))
    }
}
#endif
