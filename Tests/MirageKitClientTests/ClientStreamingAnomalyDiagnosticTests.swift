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
                layerEnqueueFPS: 88,
                uniqueLayerEnqueueFPS: 88,
                visibleFrameFPS: 88,
                visibleFrameCadenceKnown: true,
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
                layerEnqueueFPS: 29,
                uniqueLayerEnqueueFPS: 29,
                visibleFrameFPS: 29,
                visibleFrameCadenceKnown: true,
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

    @Test("AWDL host policy telemetry is included in anomaly diagnostics")
    func awdlHostPolicyTelemetryIsIncludedInAnomalyDiagnostics() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 23,
                trigger: "awdl-telemetry",
                decodedFPS: 45,
                receivedFPS: 45,
                layerEnqueueFPS: 45,
                uniqueLayerEnqueueFPS: 45,
                visibleFrameFPS: 45,
                visibleFrameCadenceKnown: true,
                pendingFrameCount: 1,
                pendingFrameAgeMs: 12,
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
                    encodedFPS: 45,
                    captureFPS: 60,
                    encodeAttemptFPS: 45,
                    awdlPolicyState: "stressed",
                    awdlPolicyTrigger: "networkJitter",
                    awdlSelectedLever: "resolutionScale",
                    awdlPlayoutDelayMs: 64,
                    awdlResolutionScale: 0.875,
                    awdlQualityReductionAllowed: false,
                    awdlHostPacingBudgetBps: 22_000_000
                )
            )
        )

        #expect(diagnostic.message.contains("hostAwdlState=stressed"))
        #expect(diagnostic.message.contains("hostAwdlTrigger=networkJitter"))
        #expect(diagnostic.message.contains("hostAwdlLever=resolutionScale"))
        #expect(diagnostic.message.contains("hostAwdlPlayout=64.0ms"))
        #expect(diagnostic.message.contains("hostAwdlScale=0.875"))
        #expect(diagnostic.message.contains("hostAwdlQualityCuts=false"))
        #expect(diagnostic.message.contains("hostAwdlPacing=22.0Mbps"))
    }

    @Test("Equal received and decoded cadence is not classified as decode-bound")
    func equalReceivedAndDecodedCadenceIsNotDecodeBound() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 22,
                trigger: "decode-submission",
                decodedFPS: 29,
                receivedFPS: 29,
                layerEnqueueFPS: 29,
                uniqueLayerEnqueueFPS: 29,
                visibleFrameFPS: 29,
                visibleFrameCadenceKnown: true,
                pendingFrameCount: 0,
                pendingFrameAgeMs: 0,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                decodeHealthy: false,
                decodeSubmissionLimit: 2,
                presentationTier: .activeLive,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 60,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 60,
                    encodedFPS: 60,
                    captureFPS: 60,
                    encodeAttemptFPS: 60
                )
            )
        )

        #expect(diagnostic.bottleneckKind != .decodeBound)
        #expect(diagnostic.label != "decode-bound")
    }

    @Test("Render backpressure is classified as presentation-bound")
    func renderBackpressureIsClassifiedAsPresentationBound() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 3,
                trigger: "freeze-recovery-keyframe-starved",
                decodedFPS: 120,
                receivedFPS: 120,
                submitAttemptFPS: 120,
                layerEnqueueFPS: 72,
                uniqueLayerEnqueueFPS: 72,
                visibleFrameFPS: 72,
                visibleFrameCadenceKnown: true,
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
        #expect(diagnostic.message.contains("submitAttempt=120.0fps"))
        #expect(diagnostic.message.contains("layerEnqueueFPS=72.0fps"))
        #expect(diagnostic.message.contains("uniqueLayerEnqueueFPS=72.0fps"))
        #expect(diagnostic.message.contains("visibleFrameFPS=72.0fps"))
        #expect(diagnostic.message.contains("layerBackpressure=3"))
        #expect(diagnostic.message.contains("overwritten=4"))
    }

    @Test("Stable decode with low layer acceptance is classified as presentation-bound")
    func stableDecodeWithLowLayerAcceptanceIsClassifiedAsPresentationBound() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 33,
                trigger: "freeze-recovery-render-submission",
                decodedFPS: 30,
                receivedFPS: 30,
                displayTickFPS: 30,
                submitAttemptFPS: 30,
                layerAcceptedFPS: 2,
                visibleFrameFPS: 2,
                submittedFPS: 2,
                uniqueSubmittedFPS: 2,
                pendingFrameCount: 0,
                pendingFrameAgeMs: 0,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                decodeHealthy: true,
                decodeSubmissionLimit: 2,
                presentationTier: .activeLive,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 30,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 30,
                    encodedFPS: 30,
                    captureFPS: 30,
                    encodeAttemptFPS: 30
                )
            )
        )

        #expect(diagnostic.bottleneckKind == .presentationBound)
        #expect(diagnostic.label == "presentation-bound")
    }

    @Test("Stale layer enqueue loop uses layer-enqueue diagnostic language")
    func staleLayerEnqueueLoopUsesLayerEnqueueDiagnosticLanguage() {
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: 4,
                trigger: "freeze-recovery-render-submission",
                decodedFPS: 0,
                receivedFPS: 0,
                submitAttemptFPS: 60,
                layerEnqueueFPS: 60,
                uniqueLayerEnqueueFPS: 0,
                visibleFrameFPS: 0,
                visibleFrameCadenceKnown: true,
                pendingFrameCount: 1,
                pendingFrameAgeMs: 1_433,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                decodeHealthy: false,
                decodeSubmissionLimit: 2,
                presentationTier: .activeLive,
                reassemblerPendingFrameCount: 0,
                reassemblerPendingKeyframeCount: 0,
                decoderOutputPixelFormat: "420f",
                usingHardwareDecoder: true,
                targetFrameRate: 60,
                hostMetrics: makeHostMetrics(
                    targetFrameRate: 60,
                    encodedFPS: 60,
                    captureFPS: 60,
                    encodeAttemptFPS: 60
                )
            )
        )

        #expect(diagnostic.bottleneckKind == .presentationBound)
        #expect(diagnostic.message.contains("layerEnqueueFPS=60.0fps"))
        #expect(diagnostic.message.contains("uniqueLayerEnqueueFPS=0.0fps"))
        #expect(diagnostic.message.contains("visibleFrameFPS=0.0fps"))
    }

    private func makeHostMetrics(
        targetFrameRate: Int,
        encodedFPS: Double,
        captureFPS: Double,
        encodeAttemptFPS: Double,
        awdlPolicyState: String? = nil,
        awdlPolicyTrigger: String? = nil,
        awdlSelectedLever: String? = nil,
        awdlPlayoutDelayMs: Double? = nil,
        awdlResolutionScale: Double? = nil,
        awdlQualityReductionAllowed: Bool? = nil,
        awdlHostPacingBudgetBps: Int? = nil,
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
            awdlPolicyState: awdlPolicyState,
            awdlPolicyTrigger: awdlPolicyTrigger,
            awdlSelectedLever: awdlSelectedLever,
            awdlPlayoutDelayMs: awdlPlayoutDelayMs,
            awdlResolutionScale: awdlResolutionScale,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed,
            awdlHostPacingBudgetBps: awdlHostPacingBudgetBps,
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
