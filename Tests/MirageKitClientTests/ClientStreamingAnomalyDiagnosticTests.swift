//
//  ClientStreamingAnomalyDiagnosticTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Client Streaming Anomaly Diagnostic")
struct ClientStreamingAnomalyDiagnosticTests {
    @Test("Healthy host plus decode-limited client is classified as decode-bound")
    func decodeLimitedClientIsClassifiedAsDecodeBound() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 1,
                trigger: "decode-submission",
                decodedFPS: 88,
                receivedFPS: 120,
                submittedFPS: 88,
                uniqueSubmittedFPS: 88,
                pendingFrameCount: 1,
                pendingFrameAgeMs: 8,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                decodeHealthy: false,
                decodeSubmissionLimit: 3,
                presentationTier: .activeLive,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 120,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 120,
                    encodedFPS: 120,
                    captureFPS: 120,
                    encodeAttemptFPS: 120
                )
            )
        )

        #expect(diagnostic.bottleneckKind == .decodeBound)
        #expect(diagnostic.label == "decode-bound")
        #expect(diagnostic.message.contains("hostEncoded=120.0fps"))
        #expect(diagnostic.message.contains("limit=3"))
    }

    @Test("Clean host capture-admission pressure is surfaced as host-side pressure")
    func hostCaptureAdmissionPressureIsSurfaced() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 2,
                trigger: "decode-submission",
                decodedFPS: 29,
                receivedFPS: 29,
                submittedFPS: 29,
                uniqueSubmittedFPS: 29,
                pendingFrameCount: 0,
                pendingFrameAgeMs: 0,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                decodeHealthy: true,
                decodeSubmissionLimit: 2,
                presentationTier: .activeLive,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 60,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 60,
                    encodedFPS: 29,
                    captureFPS: 60,
                    encodeAttemptFPS: 29,
                    captureAdmissionDrops: 31,
                    frameBudgetMs: 16.67,
                    averageEncodeMs: 11.5
                )
            )
        )

        #expect(diagnostic.bottleneckKind == .hostCadenceLimited)
        #expect(diagnostic.label == "host-side capture-admission pressure")
        #expect(diagnostic.message.contains("captureAdmissionDrops=31"))
    }

    @Test("Render backpressure is classified as presentation-bound")
    func renderBackpressureIsClassifiedAsPresentationBound() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 3,
                trigger: "freeze-recovery-keyframe-starved",
                decodedFPS: 120,
                receivedFPS: 120,
                submittedFPS: 72,
                uniqueSubmittedFPS: 72,
                pendingFrameCount: 1,
                pendingFrameAgeMs: 28,
                overwrittenPendingFrames: 4,
                displayLayerNotReadyCount: 3,
                decodeHealthy: true,
                decodeSubmissionLimit: 2,
                presentationTier: .activeLive,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 120,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 120,
                    encodedFPS: 120,
                    captureFPS: 120,
                    encodeAttemptFPS: 120
                )
            )
        )

        #expect(diagnostic.bottleneckKind == .presentationBound)
        #expect(diagnostic.label == "presentation-bound")
        #expect(diagnostic.message.contains("layerBackpressure=3"))
        #expect(diagnostic.message.contains("overwritten=4"))
    }

    private func makeHostMetrics(
        targetFrameRate: Int,
        encodedFPS: Double,
        captureFPS: Double,
        encodeAttemptFPS: Double,
        captureAdmissionDrops: UInt64? = 0,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double? = 5.0
    ) -> StreamMetricsMessage {
        StreamMetricsMessage(
            streamID: 1,
            encodedFPS: encodedFPS,
            idleEncodedFPS: 0,
            droppedFrames: 0,
            activeQuality: 1.0,
            targetFrameRate: targetFrameRate,
            captureAdmissionDrops: captureAdmissionDrops,
            frameBudgetMs: frameBudgetMs,
            averageEncodeMs: averageEncodeMs,
            captureIngressFPS: captureFPS,
            captureFPS: captureFPS,
            encodeAttemptFPS: encodeAttemptFPS,
            sendQueueBytes: 0,
            sendStartDelayAverageMs: 0.2,
            sendCompletionAverageMs: 1.0,
            packetPacerAverageSleepMs: 0.1,
            stalePacketDrops: 0,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 0
        )
    }
}
#endif
