//
//  ClientMetricsStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  Coverage for host encode telemetry propagation into client metrics snapshots.
//

@testable import MirageKitClient
@testable import MirageKit
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
            enteredBitrate: 300_000_000,
            currentBitrate: 380_000_000,
            requestedTargetBitrate: 414_187_500,
            bitrateAdaptationCeiling: 414_187_500,
            startupBitrate: 414_187_500,
            averageEncodeMs: 14.6,
            captureIngressFPS: 58.8,
            captureFPS: 57.9,
            encodeAttemptFPS: 57.4,
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
        store.updateClientMetrics(
            streamID: 7,
            decodedFPS: 59.0,
            receivedFPS: 60.0,
            receivedWorstGapMs: 44.0,
            receivedFrameIntervalP95Ms: 18.0,
            receivedFrameIntervalP99Ms: 33.0,
            droppedFrames: 3,
            submitAttemptFPS: 61.0,
            layerAcceptedFPS: 59.0,
            presentedFPS: 58.0,
            submittedFPS: 59.0,
            uniqueSubmittedFPS: 58.0,
            pendingFrameCount: 1,
            pendingFrameAgeMs: 4.0,
            overwrittenPendingFrames: 2,
            displayLayerNotReadyCount: 0,
            decodeHealthy: true
        )
        let captureCadence = StreamCaptureCadenceMetrics(
            wallClockGapWorstMs: 88,
            wallClockGapP95Ms: 44,
            wallClockGapP99Ms: 66,
            displayTimeGapWorstMs: 90,
            displayTimeGapP95Ms: 45,
            displayTimeGapP99Ms: 67,
            deliveredFrameGapWorstMs: 92,
            deliveredFrameGapP95Ms: 46,
            deliveredFrameGapP99Ms: 68,
            callbackDurationP95Ms: 2.4,
            callbackDurationP99Ms: 4.8,
            longFrameGapCount: 3,
            displayTimeDriftCount: 2,
            cadenceDropCount: 1,
            admissionDropCount: 5,
            sampleOverwriteCount: 7,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 60,
            displayRefreshRate: 60,
            virtualDisplayID: 62,
            virtualDisplayRefreshRate: 60,
            virtualDisplayScaleFactor: 2,
            virtualDisplayGeneration: 4,
            virtualDisplayTimingSuspect: true
        )
        store.updateHostPipelineMetrics(
            streamID: 7,
            captureIngressAverageMs: 4.2,
            captureIngressMaxMs: 11.8,
            preEncodeWaitAverageMs: 5.4,
            preEncodeWaitMaxMs: 13.1,
            captureCallbackAverageMs: 1.9,
            captureCallbackMaxMs: 4.6,
            captureCadence: captureCadence,
            sendQueueBytes: 196_608,
            sendStartDelayAverageMs: 3.3,
            sendStartDelayMaxMs: 8.4,
            sendCompletionAverageMs: 9.1,
            sendCompletionMaxMs: 22.7,
            packetPacerAverageSleepMs: 1.4,
            packetPacerTotalSleepMs: 42,
            packetPacerMaxSleepMs: 6,
            packetPacerFrameMaxSleepMs: 9,
            stalePacketDrops: 2,
            generationAbortDrops: 1,
            nonKeyframeHoldDrops: 7
        )

        let snapshot = store.snapshot(for: 7)
        #expect(snapshot?.hostAverageEncodeMs == 14.6)
        #expect(snapshot?.hostEnteredBitrate == 300_000_000)
        #expect(snapshot?.hostCurrentBitrate == 380_000_000)
        #expect(snapshot?.hostRequestedTargetBitrate == 414_187_500)
        #expect(snapshot?.hostBitrateAdaptationCeiling == 414_187_500)
        #expect(snapshot?.hostStartupBitrate == 414_187_500)
        #expect(snapshot?.hostCaptureIngressFPS == 58.8)
        #expect(snapshot?.hostCaptureFPS == 57.9)
        #expect(snapshot?.hostEncodeAttemptFPS == 57.4)
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
        #expect(snapshot?.clientReceivedWorstGapMs == 44.0)
        #expect(snapshot?.clientReceivedFrameIntervalP95Ms == 18.0)
        #expect(snapshot?.clientReceivedFrameIntervalP99Ms == 33.0)
        #expect(snapshot?.clientSubmitAttemptFPS == 61.0)
        #expect(snapshot?.clientLayerAcceptedFPS == 59.0)
        #expect(snapshot?.clientPresentedFPS == 58.0)
        #expect(snapshot?.hostCaptureIngressAverageMs == 4.2)
        #expect(snapshot?.hostSendQueueBytes == 196_608)
        #expect(snapshot?.hostSendCompletionMaxMs == 22.7)
        #expect(snapshot?.hostTransportPacketPacerTotalSleepMs == 42)
        #expect(snapshot?.hostTransportPacketPacerMaxSleepMs == 6)
        #expect(snapshot?.hostTransportPacketPacerFrameMaxSleepMs == 9)
        #expect(snapshot?.hostNonKeyframeHoldDrops == 7)
        #expect(snapshot?.hostCaptureDeliveredFrameGapP99Ms == 68)
        #expect(snapshot?.hostCaptureWallClockGapWorstMs == 88)
        #expect(snapshot?.hostCaptureDisplayTimeGapP99Ms == 67)
        #expect(snapshot?.hostCaptureCallbackP99Ms == 4.8)
        #expect(snapshot?.hostCaptureLongFrameGapCount == 3)
        #expect(snapshot?.hostCaptureDisplayTimeDriftCount == 2)
        #expect(snapshot?.hostCaptureVirtualDisplayTimingSuspect == true)
        #expect(snapshot?.hostCaptureUsesDisplayRefreshCadence == true)
        #expect(snapshot?.hostCaptureUsesNativeRefreshMinimumFrameInterval == true)
        #expect(snapshot?.hostCaptureMinimumFrameIntervalRate == 60)
        #expect(snapshot?.hostCaptureDisplayRefreshRate == 60)
        #expect(snapshot?.hostVirtualDisplayID == 62)
        #expect(snapshot?.hostVirtualDisplayScaleFactor == 2)
        #expect(snapshot?.hasHostMetrics == true)
    }
}
