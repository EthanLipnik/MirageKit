//
//  StreamPacketSenderFullFramePacketizationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing
import MirageWire

@Suite("Stream Packet Sender Full-Frame Packetization")
struct StreamPacketSenderFullFramePacketizationTests {
    @Test("Current generation full-frame packetization keeps legacy header contract")
    func currentGenerationFullFramePacketizationKeepsLegacyHeaderContract() async throws {
        let payload = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99])
        let maxPayloadSize = 4
        let contentRect = CGRect(x: 12, y: 24, width: 640, height: 360)
        let captured = Locked<[CapturedFullFramePacket]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            sendPacketWithMetadata: { packet, metadata, onComplete in
                captured.withLock { $0.append(CapturedFullFramePacket(packet: packet, metadata: metadata)) }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(StreamPacketSender.WorkItem(
            encodedData: payload,
            frameByteCount: payload.count,
            isKeyframe: true,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            contentRect: contentRect,
            streamID: 73,
            frameNumber: 99,
            sequenceNumberStart: 700,
            additionalFlags: [.desktopStream, .discontinuity],
            dimensionToken: 17,
            epoch: 5,
            fecBlockSize: 0,
            wireBytes: payload.count,
            logPrefix: "test",
            generation: generation,
            encodedAt: CFAbsoluteTimeGetCurrent(),
            pacingOverride: nil
        ))

        let packets = try await waitForFullFramePackets(captured, expectedCount: 3)
            .sorted { $0.metadata.fragmentIndex < $1.metadata.fragmentIndex }
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        guard packets.count == 3 else {
            Issue.record("Expected 3 full-frame packets, captured \(packets.count)")
            await sender.stop()
            return
        }

        try assertFullFramePacket(
            packets[0],
            payload: payload,
            payloadRange: 0 ..< 4,
            contentRect: contentRect,
            expectedSequence: 700,
            expectedFragmentIndex: 0,
            expectedFlags: [.desktopStream, .discontinuity, .keyframe, .parameterSet]
        )
        try assertFullFramePacket(
            packets[1],
            payload: payload,
            payloadRange: 4 ..< 8,
            contentRect: contentRect,
            expectedSequence: 701,
            expectedFragmentIndex: 1,
            expectedFlags: [.desktopStream, .keyframe]
        )
        try assertFullFramePacket(
            packets[2],
            payload: payload,
            payloadRange: 8 ..< 10,
            contentRect: contentRect,
            expectedSequence: 702,
            expectedFragmentIndex: 2,
            expectedFlags: [.desktopStream, .keyframe, .endOfFrame]
        )

        await sender.stop()
    }

    @Test("Encrypted FEC full-frame packetization keeps decryptable current-generation packets")
    func encryptedFECFullFramePacketizationKeepsDecryptableCurrentGenerationPackets() async throws {
        let payload = Data([0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87, 0x98, 0xA9])
        let maxPayloadSize = 4
        let fecBlockSize = 2
        let mediaSecurityContext = makeSecurityContext()
        let mediaSecurityKey = MirageMediaPacketKey(context: mediaSecurityContext)
        let captured = Locked<[CapturedFullFramePacket]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            sendPacketWithMetadata: { packet, metadata, onComplete in
                captured.withLock { $0.append(CapturedFullFramePacket(packet: packet, metadata: metadata)) }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(StreamPacketSender.WorkItem(
            encodedData: payload,
            frameByteCount: payload.count,
            isKeyframe: false,
            presentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            streamID: 74,
            frameNumber: 100,
            sequenceNumberStart: 800,
            additionalFlags: [.desktopStream],
            dimensionToken: 18,
            epoch: 6,
            fecBlockSize: fecBlockSize,
            wireBytes: payload.count,
            logPrefix: "test",
            generation: generation,
            encodedAt: CFAbsoluteTimeGetCurrent(),
            pacingOverride: nil
        ))

        let packets = try await waitForFullFramePackets(captured, expectedCount: 5)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        guard packets.count == 5 else {
            Issue.record("Expected 5 encrypted FEC full-frame packets, captured \(packets.count)")
            await sender.stop()
            return
        }

        #expect(packets.map { $0.metadata.fragmentIndex } == [0, 1, 3, 2, 4])
        for (sendIndex, packet) in packets.enumerated() {
            let header = try #require(MirageWire.FrameHeader.deserialize(from: packet.packet))
            let fragmentIndex = Int(header.fragmentIndex)
            let expectedPlaintext = expectedFullFramePlaintext(
                fragmentIndex: fragmentIndex,
                payload: payload,
                maxPayloadSize: maxPayloadSize,
                fecBlockSize: fecBlockSize
            )
            let wirePayload = Data(packet.packet.dropFirst(MirageWire.mirageHeaderSize))
            let decryptedPayload = try MirageMediaSecurity.decryptVideoPayload(
                wirePayload,
                header: header,
                key: mediaSecurityKey,
                direction: .hostToClient
            )

            #expect(header.magic == MirageWire.mirageProtocolMagic)
            #expect(header.version == MirageKit.mediaPacketProtocolVersion)
            #expect(header.flags.contains(.desktopStream))
            #expect(header.flags.contains(.encryptedPayload))
            #expect(header.streamID == 74)
            #expect(header.sequenceNumber == UInt32(800 + sendIndex))
            #expect(header.timestamp == 3_000_000_000)
            #expect(header.frameNumber == 100)
            #expect(header.fragmentCount == 5)
            #expect(header.fecBlockSize == UInt8(fecBlockSize))
            #expect(header.payloadLength == UInt32(expectedPlaintext.count))
            #expect(header.frameByteCount == UInt32(payload.count))
            #expect(header.checksum == 0)
            #expect(header.dimensionToken == 18)
            #expect(header.epoch == 6)
            #expect(wirePayload.count == expectedPlaintext.count + MirageMediaSecurity.authTagLength)
            #expect(decryptedPayload == expectedPlaintext)

            let isParity = fragmentIndex >= 3
            #expect(header.flags.contains(.fecParity) == isParity)
            #expect(header.flags.contains(.endOfFrame) == (fragmentIndex == 4))
            #expect(packet.metadata.streamID == 74)
            #expect(packet.metadata.frameNumber == 100)
            #expect(packet.metadata.fragmentIndex == fragmentIndex)
            #expect(packet.metadata.fragmentCount == 5)
            #expect(!packet.metadata.isKeyframe)
            #expect(packet.metadata.isParity == isParity)
            #expect(packet.metadata.isRecovery == !isParity)
        }

        await sender.stop()
    }

    private func assertFullFramePacket(
        _ packet: CapturedFullFramePacket,
        payload: Data,
        payloadRange: Range<Int>,
        contentRect: CGRect,
        expectedSequence: UInt32,
        expectedFragmentIndex: Int,
        expectedFlags: MirageWire.FrameFlags
    ) throws {
        let header = try #require(MirageWire.FrameHeader.deserialize(from: packet.packet))
        let expectedPayload = Data(payload[payloadRange])
        let wirePayload = Data(packet.packet.dropFirst(MirageWire.mirageHeaderSize))

        #expect(packet.packet.count == MirageWire.mirageHeaderSize + expectedPayload.count)
        #expect(wirePayload == expectedPayload)
        #expect(header.magic == MirageWire.mirageProtocolMagic)
        #expect(header.version == MirageKit.mediaPacketProtocolVersion)
        #expect(header.streamID == 73)
        #expect(header.sequenceNumber == expectedSequence)
        #expect(header.timestamp == 2_000_000_000)
        #expect(header.frameNumber == 99)
        #expect(header.fragmentIndex == UInt16(expectedFragmentIndex))
        #expect(header.fragmentCount == 3)
        #expect(header.fecBlockSize == 0)
        #expect(header.payloadLength == UInt32(expectedPayload.count))
        #expect(header.frameByteCount == UInt32(payload.count))
        #expect(header.checksum == MirageWire.CRC32.calculate(expectedPayload))
        #expect(header.contentRect == contentRect)
        #expect(header.dimensionToken == 17)
        #expect(header.epoch == 5)
        #expect(header.flags == expectedFlags)
        #expect(!header.flags.contains(.fecParity))
        #expect(!header.flags.contains(.encryptedPayload))

        #expect(packet.metadata.streamID == 73)
        #expect(packet.metadata.frameNumber == 99)
        #expect(packet.metadata.fragmentIndex == expectedFragmentIndex)
        #expect(packet.metadata.fragmentCount == 3)
        #expect(packet.metadata.isKeyframe)
        #expect(!packet.metadata.isParity)
        #expect(!packet.metadata.isRecovery)
    }

    private func waitForFullFramePackets(
        _ captured: Locked<[CapturedFullFramePacket]>,
        expectedCount: Int,
        timeout: Duration = .seconds(2)
    ) async throws -> [CapturedFullFramePacket] {
        let deadline = ContinuousClock.now + timeout
        while captured.read({ $0.count }) < expectedCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return captured.read { $0 }
    }

    private func expectedFullFramePlaintext(
        fragmentIndex: Int,
        payload: Data,
        maxPayloadSize: Int,
        fecBlockSize: Int
    ) -> Data {
        let dataFragmentCount = (payload.count + maxPayloadSize - 1) / maxPayloadSize
        if fragmentIndex < dataFragmentCount {
            let start = fragmentIndex * maxPayloadSize
            let end = min(payload.count, start + maxPayloadSize)
            return Data(payload[start ..< end])
        }

        let parityIndex = fragmentIndex - dataFragmentCount
        let blockStart = parityIndex * fecBlockSize
        let blockEnd = min(blockStart + fecBlockSize, dataFragmentCount)
        let parityStart = blockStart * maxPayloadSize
        let parityLength = min(maxPayloadSize, max(0, payload.count - parityStart))
        var parity = Data(repeating: 0, count: parityLength)
        for dataFragmentIndex in blockStart ..< blockEnd {
            let start = dataFragmentIndex * maxPayloadSize
            let end = min(payload.count, start + maxPayloadSize)
            let fragment = Data(payload[start ..< end])
            for byteIndex in 0 ..< min(fragment.count, parity.count) {
                parity[byteIndex] ^= fragment[byteIndex]
            }
        }
        return parity
    }

    private func makeSecurityContext() -> MirageMediaSecurityContext {
        MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) })
        )
    }
}

private struct CapturedFullFramePacket: Sendable {
    let packet: Data
    let metadata: StreamPacketSender.TransportPacketMetadata
}
#endif
