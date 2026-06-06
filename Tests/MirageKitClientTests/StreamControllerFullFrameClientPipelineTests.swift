//
//  StreamControllerFullFrameClientPipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageKit
@testable import MirageKitClient
import Testing
import MirageCore
import MirageMedia
import MirageWire

@Suite("StreamController Full-Frame Client Pipeline")
struct StreamControllerFullFrameClientPipelineTests {
    @Test("Full-frame client pipeline accepts only single-unit full-frame topology")
    func fullFrameClientPipelineAcceptsOnlySingleUnitFullFrameTopology() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "916CE656-331E-484D-A6BF-4237AC9889F8"))
        )
        let controller = makeController(streamID: 91)
        let pipeline = controller.fullFrameClientPipeline(topologyID: topologyID)

        let acceptedTopology = MirageMediaTopology.singleUnit(
            id: topologyID,
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            codec: .hevc
        )
        await pipeline.updateTopology(acceptedTopology)
        #expect(await pipeline.currentTopology() == acceptedTopology)

        let rejectedTopology = MirageMediaTopology(
            id: MirageMediaTopologyID(),
            kind: .multiUnit,
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            units: [
                MirageMediaUnitDescriptor(
                    id: MirageMediaUnitID(rawValue: "secondary"),
                    sourceRect: MiragePixelRect(x: 0, y: 0, width: 960, height: 1080),
                    presentationRect: MiragePixelRect(x: 0, y: 0, width: 960, height: 1080),
                    codec: .hevc
                ),
            ]
        )
        await pipeline.updateTopology(rejectedTopology)

        #expect(await pipeline.currentTopology() == acceptedTopology)
    }

    @Test("Full-frame client pipeline forwards matching legacy packets to the reassembler")
    func fullFrameClientPipelineForwardsMatchingLegacyPacketsToReassembler() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "7E48DB0F-D31F-4E4B-BD91-C0A0C4F90634"))
        )
        let controller = makeController(streamID: 92)
        let pipeline = controller.fullFrameClientPipeline(topologyID: topologyID)
        let packet = makePacket(streamID: 92, frameNumber: 1, topologyID: topologyID)

        await pipeline.processPacket(packet)

        let snapshot = await controller.fullFrameClientPipelineTestSnapshot()
        #expect(snapshot.packetAcceptance.rawPacketsReceived == 1)
        #expect(snapshot.packetAcceptance.acceptedPacketsReceived == 1)
    }

    @Test("Full-frame client pipeline forwards legacy packets without topology metadata unchanged")
    func fullFrameClientPipelineForwardsLegacyPacketsWithoutTopologyMetadataUnchanged() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "4B164227-0654-4642-B9C8-2D71F13BB51D"))
        )
        let controller = makeController(streamID: 96)
        let delivered = LockedFullFrameClientFrame()
        await controller.setFullFrameClientPipelineFrameHandler { streamID, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release in
            delivered.record(
                streamID: streamID,
                data: data,
                isKeyframe: isKeyframe,
                frameNumber: frameNumber,
                timestamp: timestamp,
                epoch: epoch,
                dimensionToken: dimensionToken,
                contentRect: contentRect
            )
            release()
        }
        let pipeline = controller.fullFrameClientPipeline(topologyID: topologyID)
        await pipeline.updateTopology(
            MirageMediaTopology.singleUnit(
                id: topologyID,
                logicalSize: MiragePixelSize(width: 2560, height: 1440),
                codec: .hevc
            )
        )
        let packet = makePacket(
            streamID: 96,
            frameNumber: 7,
            timestamp: 321,
            dimensionToken: 42,
            epoch: 9,
            contentRect: CGRect(x: 10, y: 11, width: 1280, height: 720)
        )

        await pipeline.processPacket(packet)

        #expect(delivered.streamID == 96)
        #expect(delivered.data == packet.payload)
        #expect(delivered.isKeyframe == true)
        #expect(delivered.frameNumber == 7)
        #expect(delivered.timestamp == 321)
        #expect(delivered.epoch == 9)
        #expect(delivered.dimensionToken == 42)
        #expect(delivered.contentRect == CGRect(x: 10, y: 11, width: 1280, height: 720))

        let snapshot = await controller.fullFrameClientPipelineTestSnapshot()
        #expect(snapshot.packetAcceptance.rawPacketsReceived == 1)
        #expect(snapshot.packetAcceptance.acceptedPacketsReceived == 1)
    }

    @Test("Full-frame client pipeline drops mismatched stream topology and media-unit packets")
    func fullFrameClientPipelineDropsMismatchedStreamTopologyAndMediaUnitPackets() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "18B174BF-F11C-47E6-B318-6A06E98F3057"))
        )
        let controller = makeController(streamID: 93)
        let pipeline = controller.fullFrameClientPipeline(topologyID: topologyID)

        await pipeline.processPacket(makePacket(streamID: 99, frameNumber: 1, topologyID: topologyID))
        await pipeline.processPacket(makePacket(streamID: 93, frameNumber: 2, topologyID: MirageMediaTopologyID()))
        await pipeline.processPacket(
            makePacket(
                streamID: 93,
                frameNumber: 3,
                topologyID: topologyID,
                mediaUnitID: MirageMediaUnitID(rawValue: "secondary")
            )
        )

        let snapshot = await controller.fullFrameClientPipelineTestSnapshot()
        #expect(snapshot.packetAcceptance.rawPacketsReceived == 0)
        #expect(snapshot.packetAcceptance.acceptedPacketsReceived == 0)
    }

    @Test("Full-frame client pipeline maps matching recovery scopes to manual keyframe recovery")
    func fullFrameClientPipelineMapsMatchingRecoveryScopesToManualKeyframeRecovery() async throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "2CE4878A-8E76-42B1-A19B-57A264D4C8D8"))
        )
        let controller = makeController(streamID: 94)
        let recorder = KeyframeRequestRecorder()
        await controller.setCallbacks(onKeyframeNeeded: {
            recorder.record()
            return true
        })
        let pipeline = controller.fullFrameClientPipeline(topologyID: topologyID)

        await pipeline.requestRecovery(.fullStream(999))
        await pipeline.requestRecovery(
            MirageRecoveryScope(
                streamID: 94,
                topologyID: MirageMediaTopologyID(),
                mediaUnitID: .primary
            )
        )
        await pipeline.requestRecovery(
            MirageRecoveryScope(
                streamID: 94,
                topologyID: topologyID,
                mediaUnitID: MirageMediaUnitID(rawValue: "secondary")
            )
        )
        #expect(recorder.count == 0)

        await pipeline.requestRecovery(
            MirageRecoveryScope(
                streamID: 94,
                topologyID: topologyID,
                mediaUnitID: .primary
            )
        )

        let snapshot = await controller.fullFrameClientPipelineTestSnapshot()
        #expect(recorder.count == 1)
        #expect(snapshot.clientRecoveryStatus == .keyframeRecovery)
        #expect(snapshot.clientRecoveryCause == .manual)
    }

    @Test("Full-frame client pipeline stops the wrapped controller")
    func fullFrameClientPipelineStopsWrappedController() async {
        let controller = makeController(streamID: 95)
        await controller.start()

        await controller.fullFrameClientPipeline().stop()

        let snapshot = await controller.fullFrameClientPipelineTestSnapshot()
        #expect(snapshot.isRunning == false)
        #expect(snapshot.isStopping)
    }
}

private struct FullFrameClientPipelineSnapshot: Sendable {
    let isRunning: Bool
    let isStopping: Bool
    let packetAcceptance: FrameReassembler.PacketAcceptanceSnapshot
    let clientRecoveryStatus: MirageStreamClientRecoveryStatus
    let clientRecoveryCause: MirageStreamClientRecoveryCause
}

private final class KeyframeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0

    var count: Int {
        lock.withLock { requestCount }
    }

    func record() {
        lock.withLock {
            requestCount += 1
        }
    }
}

private final class LockedFullFrameClientFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (
        streamID: StreamID,
        data: Data,
        isKeyframe: Bool,
        frameNumber: UInt32,
        timestamp: UInt64,
        epoch: UInt16,
        dimensionToken: UInt16,
        contentRect: CGRect
    )?

    var streamID: StreamID? {
        lock.withLock { storage?.streamID }
    }

    var data: Data? {
        lock.withLock { storage?.data }
    }

    var isKeyframe: Bool? {
        lock.withLock { storage?.isKeyframe }
    }

    var frameNumber: UInt32? {
        lock.withLock { storage?.frameNumber }
    }

    var timestamp: UInt64? {
        lock.withLock { storage?.timestamp }
    }

    var epoch: UInt16? {
        lock.withLock { storage?.epoch }
    }

    var dimensionToken: UInt16? {
        lock.withLock { storage?.dimensionToken }
    }

    var contentRect: CGRect? {
        lock.withLock { storage?.contentRect }
    }

    func record(
        streamID: StreamID,
        data: Data,
        isKeyframe: Bool,
        frameNumber: UInt32,
        timestamp: UInt64,
        epoch: UInt16,
        dimensionToken: UInt16,
        contentRect: CGRect
    ) {
        lock.withLock {
            storage = (
                streamID: streamID,
                data: data,
                isKeyframe: isKeyframe,
                frameNumber: frameNumber,
                timestamp: timestamp,
                epoch: epoch,
                dimensionToken: dimensionToken,
                contentRect: contentRect
            )
        }
    }
}

private func makeController(streamID: StreamID) -> StreamController {
    StreamController(
        streamID: streamID,
        maxPayloadSize: 1200,
        nowProvider: { 1_000 }
    )
}

private func makePacket(
    streamID: StreamID,
    frameNumber: UInt32,
    topologyID: MirageMediaTopologyID? = nil,
    mediaUnitID: MirageMediaUnitID? = nil,
    timestamp: UInt64? = nil,
    dimensionToken: UInt16 = 0,
    epoch: UInt16 = 0,
    contentRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
) -> StreamControllerFullFrameMediaPacket {
    let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, UInt8(frameNumber & 0xFF)])
    return StreamControllerFullFrameMediaPacket(
        payload: payload,
        header: MirageWire.FrameHeader(
            flags: [.keyframe, .endOfFrame],
            streamID: streamID,
            sequenceNumber: frameNumber,
            timestamp: timestamp ?? UInt64(frameNumber),
            frameNumber: frameNumber,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count),
            checksum: testCRC32(payload),
            contentRect: contentRect,
            dimensionToken: dimensionToken,
            epoch: epoch
        ),
        topologyID: topologyID,
        mediaUnitID: mediaUnitID
    )
}

private func testCRC32(_ data: Data) -> UInt32 {
    let polynomial: UInt32 = 0xEDB8_8320
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1
        }
    }
    return ~crc
}

private extension StreamController {
    func setFullFrameClientPipelineFrameHandler(
        _ handler: @escaping @Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            UInt16,
            UInt16,
            CGRect,
            @escaping @Sendable () -> Void
        ) -> Void
    ) {
        reassembler.setFrameHandler(handler)
    }

    func fullFrameClientPipelineTestSnapshot() -> FullFrameClientPipelineSnapshot {
        FullFrameClientPipelineSnapshot(
            isRunning: isRunning,
            isStopping: isStopping,
            packetAcceptance: reassembler.packetAcceptanceSnapshot,
            clientRecoveryStatus: clientRecoveryStatus,
            clientRecoveryCause: clientRecoveryCause
        )
    }
}
