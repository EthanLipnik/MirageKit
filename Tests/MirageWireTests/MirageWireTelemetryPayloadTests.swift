//
//  MirageWireTelemetryPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire Telemetry Payloads")
struct MirageWireTelemetryPayloadTests {
    @Test("Stream metrics payload round-trips in wire target")
    func streamMetricsPayloadRoundTripsInWireTarget() throws {
        let captureCadence = MirageWire.StreamCaptureCadenceMetrics(
            deliveredFrameGapWorstMs: 84,
            deliveredFrameGapP95Ms: 42,
            deliveredFrameGapP99Ms: 62,
            displayTimeDriftCount: 3,
            cadenceDropCount: 1,
            virtualDisplayID: 62,
            virtualDisplayTimingSuspect: true
        )
        let message = MirageWire.StreamMetricsMessage(
            streamID: 31,
            encodedFPS: 58,
            idleEncodedFPS: 0.2,
            droppedFrames: 12,
            activeQuality: 0.74,
            targetFrameRate: 60,
            encoderRateControlStrategy: .averageBitRateDataRateLimits,
            captureCadence: captureCadence,
            stalePacketDrops: 1,
            senderLocalDeadlineDrops: 2,
            queuedUnreliableDeadlineExpiredDrops: 3,
            queuedUnreliableQueueLimitDrops: 4,
            queuedUnreliableSupersededDrops: 5,
            queuedUnreliableUnsupportedTransportDrops: 6,
            queuedUnreliableClosedDrops: 7,
            displayP3CoverageStatus: .sRGBFallback,
            tenBitDisplayP3Validated: false
        )

        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamMetricsUpdate, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamMetricsMessage.self)

        #expect(decoded.streamID == 31)
        #expect(decoded.encoderRateControlStrategy == .averageBitRateDataRateLimits)
        #expect(decoded.displayP3CoverageStatus == .sRGBFallback)
        #expect(decoded.displayP3CoverageStatus?.requiresCanonicalCoverageWarning == true)
        #expect(decoded.queuedUnreliableDropCount == 25)
        #expect(decoded.transportPressureDropCount == 28)
        #expect(decoded.captureCadence?.deliveredFrameGapP99Ms == 62)
        #expect(decoded.captureCadence?.displayTimeDriftCount == 3)
        #expect(decoded.captureCadence?.virtualDisplayID == 62)
        #expect(decoded.captureCadence?.virtualDisplayTimingSuspect == true)
        #expect(decoded.tenBitDisplayP3Validated == false)
    }

    @Test("Stream metrics Mosaic payload round-trips in wire target")
    func streamMetricsMosaicPayloadRoundTripsInWireTarget() throws {
        let topologyID = MirageMediaTopologyID(
            rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000F1E0"))
        )
        let tilePlan = MirageMosaicTilePlan.fixedGrid(
            id: topologyID,
            epoch: 12,
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            columns: 2,
            rows: 2,
            codec: .hevc
        )
        let dirtyTileID = MirageMosaicTileID(rawValue: "grid-1")
        let reusedTileID = MirageMosaicTileID(rawValue: "grid-0")
        let epochSummary = MirageMosaicEpochSummary(
            tilePlanID: topologyID,
            tilePlanEpoch: 12,
            frameNumber: 89,
            dirtyTileIDs: [dirtyTileID],
            reusedTileVersions: [reusedTileID: 4],
            updatedTileVersions: [dirtyTileID: 7]
        )
        let message = MirageWire.StreamMetricsMessage(
            streamID: 52,
            encodedFPS: 59,
            idleEncodedFPS: 1,
            droppedFrames: 0,
            activeQuality: 0.82,
            targetFrameRate: 60,
            mosaicTilePlan: tilePlan,
            mosaicEpochSummary: epochSummary
        )

        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamMetricsUpdate, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamMetricsMessage.self)

        #expect(decoded.mosaicTilePlan == tilePlan)
        #expect(decoded.mosaicTilePlan?.kind == .fixedGrid)
        #expect(decoded.mosaicTilePlan?.tiles.count == 4)
        #expect(decoded.mosaicEpochSummary == epochSummary)
        #expect(decoded.mosaicEpochSummary?.dirtyTileIDs == [dirtyTileID])
        #expect(decoded.mosaicEpochSummary?.updatedTileVersions[dirtyTileID] == 7)
    }

    @Test("Receiver media feedback payload round-trips in wire target")
    func receiverMediaFeedbackPayloadRoundTripsInWireTarget() throws {
        let timingSamples = (0 ..< 140).map {
            MirageWire.ReceiverPFrameTimingSample(
                frameNumber: UInt32($0),
                packetSpanMs: Double($0),
                completionGapMs: -1,
                completionAgeAtFeedbackMs: Double($0) + 0.5,
                firstPacketGapMs: -2
            )
        }
        let message = MirageWire.ReceiverMediaFeedbackMessage(
            streamID: 41,
            sequence: 99,
            sentAtUptime: 12.5,
            targetFPS: 500,
            ackRanges: [
                MirageWire.MediaFeedbackFrameRange(startFrame: 10, endFrame: 12),
                MirageWire.MediaFeedbackFrameRange(startFrame: 20, endFrame: 20),
            ],
            pFrameTimingSamples: timingSamples,
            lostFrameCount: 3,
            discardedPacketCount: 4,
            jitterP95Ms: -5,
            jitterP99Ms: 9,
            queueEstimateFrames: -1,
            reassemblyBacklogFrames: 2,
            reassemblyBacklogKeyframes: 1,
            reassemblyBacklogBytes: 1024,
            decodeBacklogFrames: 3,
            presentationBacklogFrames: 4,
            decodedFPS: 58,
            receivedFPS: 59,
            rendererAcceptedFPS: 57,
            rendererPresentedFPS: 56,
            recoveryState: .keyframeRecovery,
            recoveryCause: .frameLoss,
            reliabilityCauses: [.forwardGapStall, .keyframeStarvation],
            latestPresentedFrameAgeMs: -10,
            decodeQueueDepth: -2,
            presentationQueueDepth: 5,
            receiverJitterP95Ms: -1,
            receiverJitterP99Ms: 11,
            audioDroppedFrameCount: 6,
            audioGateActive: true
        )

        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .receiverMediaFeedback, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.ReceiverMediaFeedbackMessage.self)

        #expect(decoded.streamID == 41)
        #expect(decoded.targetFPS == 240)
        #expect(decoded.ackRanges == [
            MirageWire.MediaFeedbackFrameRange(startFrame: 10, endFrame: 12),
            MirageWire.MediaFeedbackFrameRange(startFrame: 20, endFrame: 20),
        ])
        #expect(decoded.pFrameTimingSamples.count == 128)
        #expect(decoded.pFrameTimingSamples.first?.frameNumber == 12)
        #expect(decoded.pFrameTimingSamples.first?.completionGapMs == 0)
        #expect(decoded.pFrameTimingSamples.first?.firstPacketGapMs == 0)
        #expect(decoded.jitterP95Ms == 0)
        #expect(decoded.queueEstimateFrames == 0)
        #expect(decoded.recoveryCause == .frameLoss)
        #expect(decoded.reliabilityCauses == [.forwardGapStall, .keyframeStarvation])
        #expect(decoded.latestPresentedFrameAgeMs == 0)
        #expect(decoded.decodeQueueDepth == 0)
        #expect(decoded.presentationQueueDepth == 5)
        #expect(decoded.receiverJitterP95Ms == 0)
        #expect(decoded.receiverJitterP99Ms == 11)
        #expect(decoded.audioDroppedFrameCount == 6)
        #expect(decoded.audioGateActive == true)
    }

    @Test("Receiver media feedback defaults legacy optional fields")
    func receiverMediaFeedbackDefaultsLegacyOptionalFields() throws {
        let legacyPayload = Data("""
        {
          "streamID": 7,
          "sequence": 4,
          "sentAtUptime": 42.0,
          "targetFPS": 0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(MirageWire.ReceiverMediaFeedbackMessage.self, from: legacyPayload)

        #expect(decoded.streamID == 7)
        #expect(decoded.targetFPS == 1)
        #expect(decoded.ackRanges.isEmpty)
        #expect(decoded.pFrameTimingSamples.isEmpty)
        #expect(decoded.recoveryState == .idle)
        #expect(decoded.recoveryCause == .none)
        #expect(decoded.lostFrameCount == 0)
        #expect(decoded.decodedFPS == 0)
    }
}
