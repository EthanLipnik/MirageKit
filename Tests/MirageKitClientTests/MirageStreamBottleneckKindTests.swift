//
//  MirageStreamBottleneckKindTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

import MirageKitClient
import Testing
import MirageDiagnostics

@Suite("Mirage Stream Bottleneck Kind")
struct MirageStreamBottleneckKindTests {
    @Test("Client facade exposes diagnostics bottleneck classification")
    func clientFacadeExposesDiagnosticsBottleneckClassification() {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            clientPresentedFPS: 60,
            submittedFPS: 60,
            uniqueSubmittedFPS: 60,
            pendingFrameCount: 0,
            decodeHealthy: true,
            hostEncodedFPS: 60,
            hostActiveQuality: 0.85,
            hostTargetFrameRate: 60,
            hostFrameBudgetMs: 16.67,
            hostAverageEncodeMs: 12,
            hostCaptureIngressFPS: 60,
            hostCaptureFPS: 60,
            hostEncodeAttemptFPS: 60,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 1_200_000

        #expect(snapshot.bottleneckKind == .networkBound)
        #expect(MirageDiagnostics.MirageStreamBottleneckKind.decodeBound.displayName == "Decode-bound")
        #expect(MirageDiagnostics.MirageStreamBottleneckKind.classify(snapshot: nil) == .unknown)
    }
}
