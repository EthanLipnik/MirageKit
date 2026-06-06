//
//  ClientFullFrameServiceIngressPipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing
import MirageCore
import MirageWire

@Suite("Client Full-Frame Service Ingress Pipeline")
struct ClientFullFrameServiceIngressPipelineTests {
    @Test("Service ingress and full-frame client pipeline match plaintext packet provenance")
    func serviceIngressAndFullFramePipelineMatchPlaintextPacketProvenance() async throws {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x20, 0x31])
        let header = makeHeader(
            streamID: 120,
            flags: [.keyframe, .endOfFrame],
            payload: payload,
            checksum: MirageWire.CRC32.calculate(payload)
        )
        let packet = header.serialize() + payload

        let serviceFrame = try await deliverThroughServiceIngress(
            packet,
            streamID: 120
        )
        let pipelineFrame = try await deliverThroughFullFramePipeline(
            packet,
            streamID: 120
        )

        #expect(serviceFrame == pipelineFrame)
    }

    @Test("Service ingress and full-frame client pipeline match encrypted packet provenance")
    func serviceIngressAndFullFramePipelineMatchEncryptedPacketProvenance() async throws {
        let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        let context = MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) })
        )
        let packetKey = MirageMediaPacketKey(context: context)
        let header = makeHeader(
            streamID: 121,
            flags: [.keyframe, .endOfFrame, .encryptedPayload],
            payload: payload,
            checksum: 0,
            frameNumber: 12,
            sequenceNumber: 44,
            timestamp: 12_000_000,
            dimensionToken: 5,
            epoch: 2,
            contentRect: CGRect(x: 4, y: 8, width: 1024, height: 768)
        )
        let encryptedPayload = try payload.withUnsafeBytes {
            try MirageMediaSecurity.encryptVideoPayload(
                $0,
                header: header,
                key: packetKey,
                direction: .hostToClient
            )
        }
        let packet = header.serialize() + encryptedPayload

        let serviceFrame = try await deliverThroughServiceIngress(
            packet,
            streamID: 121,
            mediaSecurityContext: context
        )
        let pipelineFrame = try await deliverThroughFullFramePipeline(
            packet,
            streamID: 121,
            mediaSecurityContext: context
        )

        #expect(serviceFrame == pipelineFrame)
    }
}

private struct DeliveredFullFrame: Equatable, Sendable {
    let streamID: StreamID
    let data: Data
    let isKeyframe: Bool
    let frameNumber: UInt32
    let timestamp: UInt64
    let epoch: UInt16
    let dimensionToken: UInt16
    let contentRect: CGRect
}

private final class LockedDeliveredFullFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: DeliveredFullFrame?

    var frame: DeliveredFullFrame? {
        lock.withLock { storage }
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
            storage = DeliveredFullFrame(
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

private func deliverThroughServiceIngress(
    _ packet: Data,
    streamID: StreamID,
    mediaSecurityContext: MirageMediaSecurityContext? = nil
) async throws -> DeliveredFullFrame {
    let service = await MainActor.run {
        let service = MirageClientService(deviceName: "Full-Frame Ingress Test")
        service.fastPathState.addActiveStreamID(streamID)
        if let mediaSecurityContext {
            service.setMediaSecurityContext(mediaSecurityContext)
        }
        return service
    }
    let reassembler = FrameReassembler(streamID: streamID, maxPayloadSize: 1200)
    let delivered = LockedDeliveredFullFrame()
    reassembler.setFrameHandler { streamID, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release in
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
    service.fastPathState.setReassemblerSnapshot([streamID: reassembler])
    service.processIncomingVideoData(packet, expectedStreamID: streamID)

    return try #require(delivered.frame)
}

private func deliverThroughFullFramePipeline(
    _ packet: Data,
    streamID: StreamID,
    mediaSecurityContext: MirageMediaSecurityContext? = nil
) async throws -> DeliveredFullFrame {
    let header = try #require(MirageWire.FrameHeader.deserialize(from: packet))
    let payload = try decodeCurrentWirePayload(
        packet,
        header: header,
        mediaSecurityContext: mediaSecurityContext
    )
    let controller = StreamController(
        streamID: streamID,
        maxPayloadSize: 1200,
        nowProvider: { 1_000 }
    )
    let delivered = LockedDeliveredFullFrame()
    await controller.setFullFrameServiceIngressFrameHandler { streamID, data, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, release in
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
    await controller.fullFrameClientPipeline().processPacket(
        StreamControllerFullFrameMediaPacket(
            payload: payload,
            header: header
        )
    )

    return try #require(delivered.frame)
}

private func decodeCurrentWirePayload(
    _ packet: Data,
    header: MirageWire.FrameHeader,
    mediaSecurityContext: MirageMediaSecurityContext?
) throws -> Data {
    let wirePayload = packet.dropFirst(MirageWire.mirageHeaderSize)
    guard header.flags.contains(.encryptedPayload) else {
        return Data(wirePayload)
    }
    let context = try #require(mediaSecurityContext)
    return try MirageMediaSecurity.decryptVideoPayload(
        wirePayload,
        header: header,
        key: MirageMediaPacketKey(context: context),
        direction: .hostToClient
    )
}

private extension StreamController {
    func setFullFrameServiceIngressFrameHandler(
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
}

private func makeHeader(
    streamID: StreamID,
    flags: MirageWire.FrameFlags,
    payload: Data,
    checksum: UInt32,
    frameNumber: UInt32 = 7,
    sequenceNumber: UInt32 = 30,
    timestamp: UInt64 = 7_000_000,
    dimensionToken: UInt16 = 3,
    epoch: UInt16 = 1,
    contentRect: CGRect = CGRect(x: 1, y: 2, width: 640, height: 360)
) -> MirageWire.FrameHeader {
    MirageWire.FrameHeader(
        flags: flags,
        streamID: streamID,
        sequenceNumber: sequenceNumber,
        timestamp: timestamp,
        frameNumber: frameNumber,
        fragmentIndex: 0,
        fragmentCount: 1,
        payloadLength: UInt32(payload.count),
        frameByteCount: UInt32(payload.count),
        checksum: checksum,
        contentRect: contentRect,
        dimensionToken: dimensionToken,
        epoch: epoch
    )
}
#endif
