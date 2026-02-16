//
//  FrameReassemblerStaleKeyframeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Coverage for stale delivered-keyframe packet handling.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Frame Reassembler Stale Keyframe")
struct FrameReassemblerStaleKeyframeTests {
    @Test("Initial keyframe 0 anchors P-frame delivery")
    func initialKeyframeZeroDoesNotBlockPFrames() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = LockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }

        let keyframePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            keyframePayload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        let pFramePayload = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x03])
        reassembler.processPacket(
            pFramePayload,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 1,
                payload: pFramePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 2)
    }

    @Test("Delivered keyframe duplicate is dropped without triggering loss")
    func deliveredKeyframeDuplicateDoesNotTriggerLossLoop() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = LockedCounter()
        let lossCounter = LockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _ in
            lossCounter.increment()
        }

        let keyframePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            keyframePayload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 10,
                payload: keyframePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)

        let duplicatePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x02])
        reassembler.processPacket(
            duplicatePayload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 10,
                payload: duplicatePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        try await Task.sleep(for: .seconds(3.2))

        let pFramePayload = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x03])
        reassembler.processPacket(
            pFramePayload,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 11,
                payload: pFramePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 2)
        #expect(lossCounter.value == 0)
    }

    @Test("P-frame gaps continue forward delivery without recovery request")
    func pFrameGapContinuesForwardDelivery() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = LockedCounter()
        let lossCounter = LockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _ in
            lossCounter.increment()
        }

        let keyframe20 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x20])
        reassembler.processPacket(
            keyframe20,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 20,
                payload: keyframe20,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)

        let pFrame22 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x22])
        reassembler.processPacket(
            pFrame22,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 22,
                payload: pFrame22,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 2)
        #expect(lossCounter.value == 0)

        let pFrame23 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x23])
        reassembler.processPacket(
            pFrame23,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 23,
                payload: pFrame23,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 3)
        #expect(lossCounter.value == 0)

        let keyframe24 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x24])
        reassembler.processPacket(
            keyframe24,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 24,
                payload: keyframe24,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 4)

        let pFrame25 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x25])
        reassembler.processPacket(
            pFrame25,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 25,
                payload: pFrame25,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 5)
        #expect(lossCounter.value == 0)
    }

    private func makeHeader(
        flags: FrameFlags,
        frameNumber: UInt32,
        payload: Data,
        fragmentIndex: UInt16,
        fragmentCount: UInt16
    )
    -> FrameHeader {
        FrameHeader(
            flags: flags,
            streamID: 1,
            sequenceNumber: frameNumber,
            timestamp: UInt64(frameNumber),
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count),
            checksum: crc32(payload),
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            dimensionToken: 0,
            epoch: 0
        )
    }

    private func crc32(_ data: Data) -> UInt32 {
        let polynomial: UInt32 = 0xEDB88320
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0 ..< 8 {
                if (current & 1) == 1 {
                    current = (current >> 1) ^ polynomial
                } else {
                    current >>= 1
                }
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xFFFFFFFF
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
