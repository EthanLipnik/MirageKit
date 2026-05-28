//
//  MirageKitStreamSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreMedia
import Foundation
@testable import MirageKit
import Testing

@Suite("MirageKit Stream Serialization")
struct MirageKitStreamSerializationTests {
    @Test("Desktop cursor presentation change message serialization")
    func desktopCursorPresentationChangeSerialization() throws {
        let request = DesktopCursorPresentationChangeMessage(
            streamID: 42,
            cursorPresentation: MirageDesktopCursorPresentation(
                source: .host,
                lockClientCursorWhenUsingMirageCursor: false,
                lockClientCursorWhenUsingHostCursor: true
            )
        )

        let envelope = try ControlMessage(type: .desktopCursorPresentationChange, content: request)
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        let decoded = try decodedEnvelope.decode(DesktopCursorPresentationChangeMessage.self)
        #expect(decoded.streamID == 42)
        #expect(decoded.cursorPresentation.source == .host)
        #expect(decoded.cursorPresentation.lockClientCursorWhenUsingMirageCursor == false)
        #expect(decoded.cursorPresentation.lockClientCursorWhenUsingHostCursor)
    }

    @Test("Stream metrics validation payload serialization")
    func streamMetricsValidationPayloadSerialization() throws {
        let captureCadence = StreamCaptureCadenceMetrics(
            wallClockGapWorstMs: 80,
            wallClockGapP95Ms: 40,
            wallClockGapP99Ms: 60,
            displayTimeGapWorstMs: 82,
            displayTimeGapP95Ms: 41,
            displayTimeGapP99Ms: 61,
            deliveredFrameGapWorstMs: 84,
            deliveredFrameGapP95Ms: 42,
            deliveredFrameGapP99Ms: 62,
            callbackDurationP95Ms: 2.5,
            callbackDurationP99Ms: 4.5,
            longFrameGapCount: 2,
            displayTimeDriftCount: 3,
            blankFrameStatusCount: 1,
            suspendedFrameStatusCount: 2,
            stoppedFrameStatusCount: 3,
            cadenceDropCount: 1,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 60,
            displayRefreshRate: 60,
            virtualDisplayID: 62,
            virtualDisplayRefreshRate: 60,
            virtualDisplayScaleFactor: 2,
            virtualDisplayTimingSuspect: true
        )
        let metrics = StreamMetricsMessage(
            streamID: 1,
            encodedFPS: 58.0,
            idleEncodedFPS: 0.2,
            droppedFrames: 12,
            activeQuality: 0.74,
            targetFrameRate: 60,
            currentBitrate: 12_000_000,
            encoderRequestedBitrateBps: 12_000_000,
            encoderActualBitrateBps: 18_500_000,
            encoderActualWindowMs: 1500,
            encodedFrameBytesP50: 18_000,
            encodedFrameBytesP95: 48_000,
            encodedFrameBytesP99: 62_000,
            encodedKeyframeBytesP50: 420_000,
            encodedKeyframeBytesP95: 580_000,
            encodedKeyframeBytesP99: 640_000,
            encoderRateControlStrategy: .averageBitRateDataRateLimits,
            encoderRateLimitBytes: 750_000,
            encoderRateLimitWindowMs: 500,
            effectiveStreamScale: 0.75,
            adaptiveStreamScaleReason: "adaptive-downscale-client-requested",
            encoderRetuneValidationResult: "session-recreation-overshoot-structural-adaptation-needed",
            encoderKeyframeForRetuneCount: 1,
            encoderSessionRecreationCount: 1,
            realtimeBitrateCeiling: 16_000_000,
            realtimePressureState: "pressured",
            realtimePressureReason: "p-frame-latency",
            averageEncodeMs: 13.2,
            captureCadence: captureCadence,
            sendQueueBytes: 262_144,
            sendStartDelayAverageMs: 3.7,
            sendStartDelayMaxMs: 8.8,
            sendCompletionAverageMs: 9.4,
            sendCompletionMaxMs: 21.1,
            nonKeyframeSendStartDelayMaxMs: 5.5,
            nonKeyframeSendCompletionMaxMs: 14.2,
            packetPacerAverageSleepMs: 1.3,
            packetPacerTotalSleepMs: 24,
            packetPacerMaxSleepMs: 6,
            packetPacerFrameMaxSleepMs: 8,
            stalePacketDrops: 1,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 4,
            usingHardwareEncoder: true,
            encoderGPURegistryID: 12345,
            capturePixelFormat: "xf20",
            captureColorPrimaries: kCVImageBufferColorPrimaries_P3_D65 as String,
            encoderPixelFormat: "10-bit (P010)",
            encoderProfile: "HEVC Main10 (4:2:0)",
            encoderColorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65 as String,
            encoderTransferFunction: kCMFormatDescriptionTransferFunction_sRGB as String,
            encoderYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            tenBitDisplayP3Validated: true
        )

        let envelope = try ControlMessage(type: .streamMetricsUpdate, content: metrics)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StreamMetricsMessage.self)
        #expect(decoded.averageEncodeMs == 13.2)
        #expect(decoded.encoderRequestedBitrateBps == 12_000_000)
        #expect(decoded.encoderActualBitrateBps == 18_500_000)
        #expect(decoded.encoderActualWindowMs == 1500)
        #expect(decoded.encodedFrameBytesP95 == 48_000)
        #expect(decoded.encodedKeyframeBytesP99 == 640_000)
        #expect(decoded.encoderRateControlStrategy == .averageBitRateDataRateLimits)
        #expect(decoded.encoderRateLimitBytes == 750_000)
        #expect(decoded.encoderRateLimitWindowMs == 500)
        #expect(decoded.effectiveStreamScale == 0.75)
        #expect(decoded.adaptiveStreamScaleReason == "adaptive-downscale-client-requested")
        #expect(decoded.encoderRetuneValidationResult == "session-recreation-overshoot-structural-adaptation-needed")
        #expect(decoded.encoderKeyframeForRetuneCount == 1)
        #expect(decoded.encoderSessionRecreationCount == 1)
        #expect(decoded.realtimeBitrateCeiling == 16_000_000)
        #expect(decoded.realtimePressureState == "pressured")
        #expect(decoded.realtimePressureReason == "p-frame-latency")
        #expect(decoded.sendQueueBytes == 262_144)
        #expect(decoded.sendCompletionMaxMs == 21.1)
        #expect(decoded.nonKeyframeSendCompletionMaxMs == 14.2)
        #expect(decoded.packetPacerTotalSleepMs == 24)
        #expect(decoded.packetPacerFrameMaxSleepMs == 8)
        #expect(decoded.nonKeyframeHoldDrops == 4)
        #expect(decoded.captureCadence?.deliveredFrameGapP99Ms == 62)
        #expect(decoded.captureCadence?.displayTimeDriftCount == 3)
        #expect(decoded.captureCadence?.stoppedFrameStatusCount == 3)
        #expect(decoded.captureCadence?.virtualDisplayID == 62)
        #expect(decoded.captureCadence?.virtualDisplayTimingSuspect == true)
        #expect(decoded.usingHardwareEncoder == true)
        #expect(decoded.encoderGPURegistryID == 12345)
        #expect(decoded.capturePixelFormat == "xf20")
        #expect(decoded.encoderProfile == "HEVC Main10 (4:2:0)")
        #expect(decoded.tenBitDisplayP3Validated == true)
    }

    @Test("Stream metrics validation mismatch serialization")
    func streamMetricsValidationMismatchSerialization() throws {
        let metrics = StreamMetricsMessage(
            streamID: 2,
            encodedFPS: 42.0,
            idleEncodedFPS: 0,
            droppedFrames: 101,
            activeQuality: 0.68,
            targetFrameRate: 60,
            capturePixelFormat: "420v",
            captureColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            encoderPixelFormat: "8-bit (NV12)",
            encoderProfile: "HEVC Main (4:2:0)",
            encoderColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            encoderTransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            encoderYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            tenBitDisplayP3Validated: false
        )

        let envelope = try ControlMessage(type: .streamMetricsUpdate, content: metrics)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StreamMetricsMessage.self)
        #expect(decoded.averageEncodeMs == nil)
        #expect(decoded.usingHardwareEncoder == nil)
        #expect(decoded.encoderGPURegistryID == nil)
        #expect(decoded.capturePixelFormat == "420v")
        #expect(decoded.encoderPixelFormat == "8-bit (NV12)")
        #expect(decoded.tenBitDisplayP3Validated == false)
    }
}
