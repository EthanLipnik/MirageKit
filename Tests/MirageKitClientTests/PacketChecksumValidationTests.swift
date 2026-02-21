//
//  PacketChecksumValidationTests.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  CRC validation behavior for encrypted and unencrypted packet paths.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing

#if os(macOS)
@Suite("Client Packet Checksum Validation")
struct PacketChecksumValidationTests {
    @Test("Encrypted video packet with zero checksum bypasses CRC validation")
    func encryptedVideoZeroChecksumBypassesCRC() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let delivered = LockedCounter()
        reassembler.setFrameHandler { _, _, _, _, _, release in
            delivered.increment()
            release()
        }

        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        reassembler.processPacket(
            payload,
            header: makeVideoHeader(
                flags: [.keyframe, .endOfFrame, .encryptedPayload],
                frameNumber: 1,
                payload: payload,
                checksum: 0
            )
        )

        #expect(delivered.value == 1)
        #expect(reassembler.packetsDiscardedCRC == 0)
    }

    @Test("Encrypted video packet with non-zero checksum still validates CRC")
    func encryptedVideoNonZeroChecksumStillValidatesCRC() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let delivered = LockedCounter()
        reassembler.setFrameHandler { _, _, _, _, _, release in
            delivered.increment()
            release()
        }

        let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        reassembler.processPacket(
            payload,
            header: makeVideoHeader(
                flags: [.keyframe, .endOfFrame, .encryptedPayload],
                frameNumber: 2,
                payload: payload,
                checksum: 0xDEAD_BEEF
            )
        )

        #expect(delivered.value == 0)
        #expect(reassembler.packetsDiscardedCRC == 1)
    }

    @Test("Unencrypted video packets keep mandatory CRC validation")
    func unencryptedVideoChecksumRemainsMandatory() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let delivered = LockedCounter()
        reassembler.setFrameHandler { _, _, _, _, _, release in
            delivered.increment()
            release()
        }

        let payload = Data([0x11, 0x22, 0x33, 0x44, 0x55])
        reassembler.processPacket(
            payload,
            header: makeVideoHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 3,
                payload: payload,
                checksum: 0
            )
        )

        #expect(delivered.value == 0)
        #expect(reassembler.packetsDiscardedCRC == 1)
    }

    @Test("Audio checksum validation bypass only applies to encrypted zero checksum packets")
    func audioChecksumValidationPolicy() {
        #expect(!MirageClientService.shouldValidateAudioChecksum(flags: [.encryptedPayload], checksum: 0))
        #expect(MirageClientService.shouldValidateAudioChecksum(flags: [.encryptedPayload], checksum: 7))
        #expect(MirageClientService.shouldValidateAudioChecksum(flags: [], checksum: 0))
    }

    private func makeVideoHeader(
        flags: FrameFlags,
        frameNumber: UInt32,
        payload: Data,
        checksum: UInt32
    ) -> FrameHeader {
        FrameHeader(
            flags: flags,
            streamID: 1,
            sequenceNumber: frameNumber,
            timestamp: UInt64(frameNumber),
            frameNumber: frameNumber,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count),
            checksum: checksum,
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            dimensionToken: 0,
            epoch: 0
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
#endif
