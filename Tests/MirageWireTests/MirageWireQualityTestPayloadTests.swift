//
//  MirageWireQualityTestPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageDiagnostics
import MirageWire
import Testing

@Suite("MirageWire Quality Test Payloads")
struct MirageWireQualityTestPayloadTests {
    @Test("Quality test packet header round-trips in wire target")
    func qualityTestPacketHeaderRoundTripsInWireTarget() throws {
        let testID = try #require(UUID(uuidString: "73000000-0000-0000-0000-000000000003"))
        let header = MirageWire.QualityTestPacketHeader(
            testID: testID,
            stageID: 2,
            sequenceNumber: 42,
            timestampNs: 1_234_567_890,
            payloadLength: 1_188
        )
        let serialized = header.serialize()
        let decoded = try #require(MirageWire.QualityTestPacketHeader.deserialize(from: serialized))

        #expect(MirageWire.mirageQualityTestMagic == 0x4D49_5251)
        #expect(MirageWire.mirageQualityTestVersion == 1)
        #expect(serialized.count == MirageWire.mirageQualityTestHeaderSize)
        #expect(decoded.testID == testID)
        #expect(decoded.stageID == 2)
        #expect(decoded.sequenceNumber == 42)
        #expect(decoded.timestampNs == 1_234_567_890)
        #expect(decoded.payloadLength == 1_188)

        var invalidMagic = serialized
        invalidMagic[0] = 0
        #expect(MirageWire.QualityTestPacketHeader.deserialize(from: invalidMagic) == nil)

        var invalidVersion = serialized
        invalidVersion[MemoryLayout<UInt32>.size] = 2
        #expect(MirageWire.QualityTestPacketHeader.deserialize(from: invalidVersion) == nil)
    }

    @Test("Quality test request and cancel payloads round-trip in wire target")
    func qualityTestRequestAndCancelPayloadsRoundTripInWireTarget() throws {
        let testID = try #require(UUID(uuidString: "73000000-0000-0000-0000-000000000001"))
        let plan = MirageDiagnostics.MirageQualityTestPlan(stages: [
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 1,
                probeKind: .transport,
                targetBitrateBps: 80_000_000,
                durationMs: 500
            ),
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 2,
                probeKind: .streamingReplay,
                targetBitrateBps: 120_000_000,
                durationMs: 750,
                settleGraceMs: 900
            ),
        ])
        let request = MirageWire.QualityTestRequestMessage(
            testID: testID,
            plan: plan,
            payloadBytes: 1_188,
            mediaMaxPacketSize: 1_400,
            stopAfterFirstBreach: true,
            transferByteCount: 100_000_000
        )
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .qualityTestRequest, content: request).serialize()
        ).message
        let decodedRequest = try requestEnvelope.decode(MirageWire.QualityTestRequestMessage.self)

        #expect(decodedRequest.testID == testID)
        #expect(decodedRequest.plan == plan)
        #expect(decodedRequest.payloadBytes == 1_188)
        #expect(decodedRequest.mediaMaxPacketSize == 1_400)
        #expect(decodedRequest.stopAfterFirstBreach)
        #expect(decodedRequest.transferByteCount == 100_000_000)

        let cancel = MirageWire.QualityTestCancelMessage(testID: testID)
        let cancelEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .qualityTestCancel, content: cancel).serialize()
        ).message
        let decodedCancel = try cancelEnvelope.decode(MirageWire.QualityTestCancelMessage.self)

        #expect(decodedCancel.testID == testID)
    }

    @Test("Quality test benchmark and stage-complete payloads round-trip in wire target")
    func qualityTestResultPayloadsRoundTripInWireTarget() throws {
        let testID = try #require(UUID(uuidString: "73000000-0000-0000-0000-000000000002"))
        let capability = MirageDiagnostics.MirageHostCaptureCapability(
            targetFrameRate: 120,
            validThresholdFPS: 60,
            sustainThresholdFPS: 115,
            highestValidPixelWidth: 3_840,
            highestValidPixelHeight: 2_160,
            highestValidFrameRate: 120,
            highestSustainedPixelWidth: 3_840,
            highestSustainedPixelHeight: 2_160,
            highestSustainedFrameRate: 118
        )
        let benchmark = MirageWire.QualityTestBenchmarkMessage(
            testID: testID,
            encodeMs: 4.25,
            hostCaptureCapability: capability
        )
        let benchmarkEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .qualityTestResult, content: benchmark).serialize()
        ).message
        let decodedBenchmark = try benchmarkEnvelope.decode(MirageWire.QualityTestBenchmarkMessage.self)

        #expect(decodedBenchmark.testID == testID)
        #expect(decodedBenchmark.encodeMs == 4.25)
        #expect(decodedBenchmark.hostCaptureCapability == capability)
        #expect(decodedBenchmark.hostCaptureCapability?.highestSustainedPixelCount == 8_294_400)

        let completion = MirageWire.QualityTestStageCompleteMessage(
            testID: testID,
            stageID: 2,
            probeKind: .streamingReplay,
            startedAtTimestampNs: 100,
            measurementEndedAtTimestampNs: 1_500_000_100,
            sentPacketCount: 256,
            sentPayloadBytes: 1_048_576,
            deliveryWindowMissed: false
        )
        let completionEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .qualityTestStageComplete, content: completion).serialize()
        ).message
        let decodedCompletion = try completionEnvelope.decode(MirageWire.QualityTestStageCompleteMessage.self)

        #expect(decodedCompletion.testID == testID)
        #expect(decodedCompletion.stageID == 2)
        #expect(decodedCompletion.probeKind == .streamingReplay)
        #expect(decodedCompletion.startedAtTimestampNs == 100)
        #expect(decodedCompletion.measurementEndedAtTimestampNs == 1_500_000_100)
        #expect(decodedCompletion.sentPacketCount == 256)
        #expect(decodedCompletion.sentPayloadBytes == 1_048_576)
        #expect(decodedCompletion.deliveryWindowMissed == false)
    }
}
