//
//  FreezeMonitorIdleDetectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/11/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

@Suite("Freeze Monitor Idle Detection")
struct FreezeMonitorIdleDetectionTests {
    private func hostMetrics(
        encodedFPS: Double = 0,
        idleEncodedFPS: Double = 0,
        captureIngressFPS: Double? = nil,
        captureFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        observedSCKFPS: Double? = nil,
        includesCadence: Bool = true
    ) -> StreamMetricsMessage {
        StreamMetricsMessage(
            streamID: 1,
            encodedFPS: encodedFPS,
            idleEncodedFPS: idleEncodedFPS,
            droppedFrames: 0,
            activeQuality: 0.5,
            targetFrameRate: 60,
            captureIngressFPS: captureIngressFPS,
            captureFPS: captureFPS,
            encodeAttemptFPS: encodeAttemptFPS,
            captureCadence: includesCadence
                ? StreamCaptureCadenceMetrics(
                    rawScreenCallbackFPS: captureFPS,
                    observedSCKFPS: observedSCKFPS
                )
                : nil
        )
    }

    @Test("Virtual display idle callbacks still classify as dynamically idle")
    func virtualDisplayIdleCallbacksClassifyAsDynamicallyIdle() {
        // The desktop virtual display keeps raw capture callbacks alive while the
        // content is static; only content-change evidence distinguishes idle from
        // a delivery stall.
        let metrics = hostMetrics(
            captureIngressFPS: 38.0,
            captureFPS: 38.0,
            encodeAttemptFPS: 38.0,
            observedSCKFPS: 0.0
        )
        #expect(StreamController.hostMetricsIndicateDynamicallyIdleCapture(metrics))
    }

    @Test("Content flowing on the host is never classified as idle")
    func contentFlowingOnHostIsNeverClassifiedAsIdle() {
        let producing = hostMetrics(
            encodedFPS: 58.0,
            captureIngressFPS: 60.0,
            captureFPS: 60.0,
            encodeAttemptFPS: 60.0,
            observedSCKFPS: 59.0
        )
        #expect(!StreamController.hostMetricsIndicateDynamicallyIdleCapture(producing))

        // Content changes observed but nothing encoded yet: a stall, not idleness.
        let stalled = hostMetrics(
            captureIngressFPS: 60.0,
            captureFPS: 60.0,
            encodeAttemptFPS: 60.0,
            observedSCKFPS: 45.0
        )
        #expect(!StreamController.hostMetricsIndicateDynamicallyIdleCapture(stalled))
    }

    @Test("Hosts without content-change telemetry fall back to raw capture fps")
    func hostsWithoutContentChangeTelemetryFallBackToRawCaptureFPS() {
        let idleLegacy = hostMetrics(
            captureIngressFPS: 0.0,
            captureFPS: 0.0,
            encodeAttemptFPS: 0.0,
            includesCadence: false
        )
        #expect(StreamController.hostMetricsIndicateDynamicallyIdleCapture(idleLegacy))

        let activeLegacy = hostMetrics(
            captureIngressFPS: 38.0,
            captureFPS: 38.0,
            encodeAttemptFPS: 38.0,
            includesCadence: false
        )
        #expect(!StreamController.hostMetricsIndicateDynamicallyIdleCapture(activeLegacy))
    }
}
#endif
