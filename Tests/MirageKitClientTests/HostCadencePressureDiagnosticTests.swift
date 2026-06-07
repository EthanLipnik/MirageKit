//
//  HostCadencePressureDiagnosticTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing
import MirageDiagnostics
import MirageWire

#if os(macOS)
@Suite("Host Cadence Pressure Diagnostic")
struct HostCadencePressureDiagnosticTests {
    @Test("Stream metrics adapter feeds diagnostics-owned host cadence classifier")
    func streamMetricsAdapterFeedsDiagnosticsOwnedHostCadenceClassifier() {
        let sample = MirageHostCadencePressureDiagnosticSample(
            metrics: MirageWire.StreamMetricsMessage(
                streamID: 42,
                encodedFPS: 29,
                idleEncodedFPS: 0,
                droppedFrames: 0,
                activeQuality: 0.6,
                targetFrameRate: 60,
                captureAdmissionDrops: 31,
                frameBudgetMs: 16.67,
                averageEncodeMs: 11.5,
                captureIngressFPS: 60,
                captureFPS: 60,
                encodeAttemptFPS: 29,
                sendQueueBytes: -40,
                sendStartDelayAverageMs: -1,
                sendCompletionAverageMs: 1.1,
                packetPacerAverageSleepMs: 0.1
            )
        )

        let diagnostic = hostCadencePressureDiagnostic(sample: sample)

        #expect(sample.queueBytes == 0)
        #expect(sample.sendStartDelayAverageMs == 0)
        #expect(diagnostic?.kind == .captureAdmissionPressure)
    }
}
#endif
