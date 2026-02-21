//
//  PacketizerChecksumTests.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Encrypted checksum emission and fragment accounting coverage for host packetizers.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import Testing

@Suite("Host Packetizer Checksums")
struct PacketizerChecksumTests {
    @Test("Stream packet sender emits zero checksums for encrypted payloads")
    func streamPacketSenderEncryptedChecksumEmission() async throws {
        let payload = makePayload(byteCount: 1450)
        let maxPayloadSize = 512
        let expectedFragments = (payload.count + maxPayloadSize - 1) / maxPayloadSize
        let captured = Locked<[CapturedVideoPacket]>([])

        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: makeSecurityContext()
        ) { packet, header, release in
            captured.withLock { $0.append(CapturedVideoPacket(packet: packet, header: header)) }
            release()
        }

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            StreamPacketSender.WorkItem(
                encodedData: payload,
                frameByteCount: payload.count,
                isKeyframe: false,
                presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                streamID: 7,
                frameNumber: 21,
                sequenceNumberStart: 1000,
                additionalFlags: [],
                dimensionToken: 0,
                epoch: 3,
                fecBlockSize: 0,
                wireBytes: payload.count,
                logPrefix: "test",
                generation: generation,
                onSendStart: nil,
                onSendComplete: nil
            )
        )

        let packets = try await waitForPackets(captured, expectedCount: expectedFragments)
            .sorted { $0.header.fragmentIndex < $1.header.fragmentIndex }
        #expect(packets.count == expectedFragments)

        for (index, packet) in packets.enumerated() {
            let expectedPayloadLength = UInt32(min(maxPayloadSize, payload.count - index * maxPayloadSize))
            #expect(packet.header.flags.contains(.encryptedPayload))
            #expect(packet.header.checksum == 0)
            #expect(packet.header.fragmentCount == UInt16(expectedFragments))
            #expect(packet.header.payloadLength == expectedPayloadLength)
            let wirePayload = Data(packet.packet.dropFirst(mirageHeaderSize))
            #expect(wirePayload.count == Int(expectedPayloadLength) + MirageMediaSecurity.authTagLength)
        }

        await sender.stop()
    }

    @Test("Stream packet sender keeps CRC for unencrypted payloads")
    func streamPacketSenderUnencryptedChecksumEmission() async throws {
        let payload = makePayload(byteCount: 1450)
        let maxPayloadSize = 512
        let expectedFragments = (payload.count + maxPayloadSize - 1) / maxPayloadSize
        let captured = Locked<[CapturedVideoPacket]>([])

        let sender = StreamPacketSender(maxPayloadSize: maxPayloadSize) { packet, header, release in
            captured.withLock { $0.append(CapturedVideoPacket(packet: packet, header: header)) }
            release()
        }

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            StreamPacketSender.WorkItem(
                encodedData: payload,
                frameByteCount: payload.count,
                isKeyframe: false,
                presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                streamID: 8,
                frameNumber: 22,
                sequenceNumberStart: 2000,
                additionalFlags: [],
                dimensionToken: 0,
                epoch: 0,
                fecBlockSize: 0,
                wireBytes: payload.count,
                logPrefix: "test",
                generation: generation,
                onSendStart: nil,
                onSendComplete: nil
            )
        )

        let packets = try await waitForPackets(captured, expectedCount: expectedFragments)
            .sorted { $0.header.fragmentIndex < $1.header.fragmentIndex }
        #expect(packets.count == expectedFragments)

        for (index, packet) in packets.enumerated() {
            let start = index * maxPayloadSize
            let end = min(payload.count, start + maxPayloadSize)
            let expectedPayload = Data(payload[start ..< end])
            let expectedChecksum = CRC32.calculate(expectedPayload)

            #expect(!packet.header.flags.contains(.encryptedPayload))
            #expect(packet.header.checksum == expectedChecksum)
            #expect(packet.header.fragmentCount == UInt16(expectedFragments))
            #expect(packet.header.payloadLength == UInt32(expectedPayload.count))

            let wirePayload = Data(packet.packet.dropFirst(mirageHeaderSize))
            #expect(wirePayload == expectedPayload)
        }

        await sender.stop()
    }

    @Test("Audio packetizer checksum behavior matches encrypted contract")
    func audioPacketizerChecksumBehavior() async {
        let payload = makePayload(byteCount: 1450)
        let maxPayloadSize = 512
        let expectedFragments = (payload.count + maxPayloadSize - 1) / maxPayloadSize
        let frame = EncodedAudioFrame(
            data: payload,
            codec: .aacLC,
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 1024,
            timestampNs: 1234
        )

        let encryptedPacketizer = AudioPacketizer(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: makeSecurityContext()
        )
        let encryptedPackets = await encryptedPacketizer.packetize(frame: frame, streamID: 9)
        #expect(encryptedPackets.count == expectedFragments)

        for (index, packet) in encryptedPackets.enumerated() {
            guard let header = AudioPacketHeader.deserialize(from: packet) else {
                Issue.record("Failed to deserialize encrypted audio packet header")
                return
            }
            let expectedPayloadLength = min(maxPayloadSize, payload.count - index * maxPayloadSize)
            #expect(header.flags.contains(.encryptedPayload))
            #expect(header.checksum == 0)
            #expect(header.fragmentCount == UInt16(expectedFragments))
            #expect(Int(header.payloadLength) == expectedPayloadLength)
            let wirePayload = Data(packet.dropFirst(mirageAudioHeaderSize))
            #expect(wirePayload.count == expectedPayloadLength + MirageMediaSecurity.authTagLength)
        }

        let plainPacketizer = AudioPacketizer(maxPayloadSize: maxPayloadSize)
        let plainPackets = await plainPacketizer.packetize(frame: frame, streamID: 10)
        #expect(plainPackets.count == expectedFragments)

        for (index, packet) in plainPackets.enumerated() {
            guard let header = AudioPacketHeader.deserialize(from: packet) else {
                Issue.record("Failed to deserialize unencrypted audio packet header")
                return
            }
            let start = index * maxPayloadSize
            let end = min(payload.count, start + maxPayloadSize)
            let expectedPayload = Data(payload[start ..< end])
            let wirePayload = Data(packet.dropFirst(mirageAudioHeaderSize))

            #expect(!header.flags.contains(.encryptedPayload))
            #expect(header.checksum == CRC32.calculate(expectedPayload))
            #expect(Int(header.payloadLength) == expectedPayload.count)
            #expect(wirePayload == expectedPayload)
        }
    }

    private func waitForPackets(
        _ captured: Locked<[CapturedVideoPacket]>,
        expectedCount: Int,
        timeoutSeconds: TimeInterval = 2.0
    ) async throws -> [CapturedVideoPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while captured.read({ $0.count }) < expectedCount, CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return captured.read { $0 }
    }

    private func makePayload(byteCount: Int) -> Data {
        Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func makeSecurityContext() -> MirageMediaSecurityContext {
        MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) }),
            udpRegistrationToken: Data(repeating: 0xA5, count: MirageMediaSecurity.registrationTokenLength)
        )
    }
}

private struct CapturedVideoPacket: Sendable {
    let packet: Data
    let header: FrameHeader
}
#endif
