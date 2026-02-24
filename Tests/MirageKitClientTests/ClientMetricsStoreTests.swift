//
//  ClientMetricsStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  Coverage for host encode telemetry propagation into client metrics snapshots.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Client Metrics Store")
struct ClientMetricsStoreTests {
    @Test("Host encode telemetry fields are stored in the metrics snapshot")
    func hostEncodeTelemetryPropagation() {
        let store = MirageClientMetricsStore()

        store.updateHostMetrics(
            streamID: 7,
            encodedFPS: 58.4,
            idleEncodedFPS: 0.2,
            droppedFrames: 12,
            activeQuality: 0.72,
            targetFrameRate: 60,
            averageEncodeMs: 14.6,
            usingHardwareEncoder: true,
            encoderGPURegistryID: 123_456,
            capturePixelFormat: "xf20",
            captureColorPrimaries: "P3_D65",
            encoderPixelFormat: "10-bit (P010)",
            encoderProfile: "HEVC Main10",
            encoderColorPrimaries: "P3_D65",
            encoderTransferFunction: "sRGB",
            encoderYCbCrMatrix: "ITU_R_709_2",
            tenBitDisplayP3Validated: true
        )

        let snapshot = store.snapshot(for: 7)
        #expect(snapshot?.hostAverageEncodeMs == 14.6)
        #expect(snapshot?.hostUsingHardwareEncoder == true)
        #expect(snapshot?.hostEncoderGPURegistryID == 123_456)
        #expect(snapshot?.hostCapturePixelFormat == "xf20")
        #expect(snapshot?.hostEncoderProfile == "HEVC Main10")
        #expect(snapshot?.hostTenBitDisplayP3Validated == true)
        #expect(snapshot?.hasHostMetrics == true)
    }
}
