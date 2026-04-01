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
            encodedWidth: 2_732,
            encodedHeight: 2_048,
            capturePixelFormat: "xf20",
            captureColorPrimaries: "P3_D65",
            encoderPixelFormat: "10-bit (P010)",
            encoderChromaSampling: "4:2:0",
            encoderProfile: "HEVC Main10",
            encoderColorPrimaries: "P3_D65",
            encoderTransferFunction: "sRGB",
            encoderYCbCrMatrix: "ITU_R_709_2",
            displayP3CoverageStatus: .strictCanonical,
            tenBitDisplayP3Validated: true,
            ultra444Validated: false
        )
        store.updateClientDecoderTelemetry(
            streamID: 7,
            outputPixelFormat: "x420 (10-bit FullRange)",
            usingHardwareDecoder: true
        )
        store.updateHostPipelineMetrics(
            streamID: 7,
            captureIngressAverageMs: 4.2,
            captureIngressMaxMs: 11.8,
            preEncodeWaitAverageMs: 5.4,
            preEncodeWaitMaxMs: 13.1,
            captureCallbackAverageMs: 1.9,
            captureCallbackMaxMs: 4.6,
            captureCopyAverageMs: 2.7,
            captureCopyMaxMs: 6.2,
            captureCopyPoolDrops: 3,
            captureCopyInFlightDrops: 5,
            sendQueueBytes: 196_608,
            sendStartDelayAverageMs: 3.3,
            sendStartDelayMaxMs: 8.4,
            sendCompletionAverageMs: 9.1,
            sendCompletionMaxMs: 22.7,
            packetPacerAverageSleepMs: 1.4,
            packetPacerMaxSleepMs: 6,
            stalePacketDrops: 2,
            generationAbortDrops: 1,
            nonKeyframeHoldDrops: 7
        )

        let snapshot = store.snapshot(for: 7)
        #expect(snapshot?.hostAverageEncodeMs == 14.6)
        #expect(snapshot?.hostUsingHardwareEncoder == true)
        #expect(snapshot?.hostEncoderGPURegistryID == 123_456)
        #expect(snapshot?.hostEncodedWidth == 2_732)
        #expect(snapshot?.hostEncodedHeight == 2_048)
        #expect(snapshot?.hostCapturePixelFormat == "xf20")
        #expect(snapshot?.hostEncoderChromaSampling == "4:2:0")
        #expect(snapshot?.hostEncoderProfile == "HEVC Main10")
        #expect(snapshot?.hostDisplayP3CoverageStatus == .strictCanonical)
        #expect(snapshot?.hostTenBitDisplayP3Validated == true)
        #expect(snapshot?.hostUltra444Validated == false)
        #expect(snapshot?.clientDecoderOutputPixelFormat == "x420 (10-bit FullRange)")
        #expect(snapshot?.clientUsingHardwareDecoder == true)
        #expect(snapshot?.hostCaptureIngressAverageMs == 4.2)
        #expect(snapshot?.hostCaptureCopyPoolDrops == 3)
        #expect(snapshot?.hostSendQueueBytes == 196_608)
        #expect(snapshot?.hostSendCompletionMaxMs == 22.7)
        #expect(snapshot?.hostNonKeyframeHoldDrops == 7)
        #expect(snapshot?.hasHostMetrics == true)
    }
}
