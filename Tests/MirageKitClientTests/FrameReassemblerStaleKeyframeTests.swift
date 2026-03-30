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

    @Test("Small forward gap buffers and drains once missing frame arrives")
    func smallForwardGapBuffersAndDrainsInOrder() {
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
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe() == false)

        let pFrame21 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x21])
        reassembler.processPacket(
            pFrame21,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 21,
                payload: pFrame21,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 3)
        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe() == false)
    }

    @Test("Multiple forward gaps stay buffered and drain in order")
    func sustainedForwardGapsDrainWithoutKeyframeWait() {
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

        for frame in [22, 24, 26] {
            let pFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, UInt8(frame & 0xFF)])
            reassembler.processPacket(
                pFrame,
                header: makeHeader(
                    flags: [.endOfFrame],
                    frameNumber: UInt32(frame),
                    payload: pFrame,
                    fragmentIndex: 0,
                    fragmentCount: 1
                )
            )
        }
        #expect(reassembler.isAwaitingKeyframe() == false)
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)

        let pFrame21 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x21])
        reassembler.processPacket(
            pFrame21,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 21,
                payload: pFrame21,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(reassembler.isAwaitingKeyframe() == false)
        #expect(deliveredCounter.value == 3)
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
        #expect(deliveredCounter.value == 5)
        #expect(reassembler.isAwaitingKeyframe() == false)

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
        #expect(deliveredCounter.value == 7)
        #expect(lossCounter.value == 0)
    }

    @Test("P-frame timeout enters keyframe wait until new anchor arrives")
    func pFrameTimeoutEntersKeyframeWait() async throws {
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

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)

        let incompletePFrame = Data(repeating: 0xAB, count: 1200)
        reassembler.processPacket(
            incompletePFrame,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: incompletePFrame,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 2400
            )
        )

        try await Task.sleep(for: .milliseconds(700))

        let timeoutProbe = Data(repeating: 0xCD, count: 1200)
        reassembler.processPacket(
            timeoutProbe,
            header: makeHeader(
                flags: [],
                frameNumber: 3,
                payload: timeoutProbe,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 2400
            )
        )

        let pFrame2 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x02])
        reassembler.processPacket(
            pFrame2,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 2,
                payload: pFrame2,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value >= 1)
        #expect(reassembler.isAwaitingKeyframe() == true)

        let keyframe4 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x04])
        reassembler.processPacket(
            keyframe4,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 4,
                payload: keyframe4,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 2)
        #expect(reassembler.isAwaitingKeyframe() == false)
    }

    @Test("Buffered forward gap without pending expected frame enters keyframe wait")
    func bufferedForwardGapWithoutExpectedFrameEntersKeyframeWait() async throws {
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

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)
        #expect(reassembler.isAwaitingKeyframe() == false)

        let pFrame2 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x02])
        reassembler.processPacket(
            pFrame2,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 2,
                payload: pFrame2,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)

        try await Task.sleep(for: .milliseconds(700))

        let pFrame4 = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x04])
        reassembler.processPacket(
            pFrame4,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 4,
                payload: pFrame4,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value >= 1)
        #expect(reassembler.isAwaitingKeyframe() == true)

        let keyframe5 = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x05])
        reassembler.processPacket(
            keyframe5,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 5,
                payload: keyframe5,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 2)
        #expect(reassembler.isAwaitingKeyframe() == false)
    }

    @Test("Keyframe timeout tracks assembly progress instead of first-fragment age")
    func keyframeTimeoutTracksAssemblyProgress() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredCounter = LockedCounter()
        let lossCounter = LockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _ in
            lossCounter.increment()
        }

        let fragment0 = Data([0x00, 0x00, 0x00, 0x01])
        reassembler.processPacket(
            fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 30,
                payload: fragment0,
                fragmentIndex: 0,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        try await Task.sleep(for: .milliseconds(2500))

        let fragment1 = Data([0x26, 0x30, 0x30, 0x30])
        reassembler.processPacket(
            fragment1,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 30,
                payload: fragment1,
                fragmentIndex: 1,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        try await Task.sleep(for: .milliseconds(1000))

        let timeoutProbe = Data([0x00, 0x00, 0x00, 0x02])
        reassembler.processPacket(
            timeoutProbe,
            header: makeHeader(
                flags: [],
                frameNumber: 31,
                payload: timeoutProbe,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 8
            )
        )

        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe() == false)

        let fragment2 = Data([0x40, 0x40, 0x40, 0x40])
        reassembler.processPacket(
            fragment2,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 30,
                payload: fragment2,
                fragmentIndex: 2,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
    }

    @Test("Keyframe FEC recovery infers startup block size from fragment layout")
    func keyframeFECRecoveryInfersStartupBlockSize() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredFrame = LockedOptionalData()

        reassembler.setFrameHandler { _, data, _, _, _, release in
            deliveredFrame.set(data)
            release()
        }

        let fragment0 = Data([0x00, 0x00, 0x00, 0x18])
        let fragment1 = Data([0x00, 0x00, 0x00, 0x01])
        let fragment2 = Data([0x40, 0x01, 0x0C, 0x01])
        let fragment3 = Data([0xFF, 0xFF, 0x01, 0x60])
        let fragment4 = Data([0x00, 0x00, 0x00, 0x04])
        let fragment5 = Data([0x26, 0xAA, 0xBB, 0xCC])
        let parity0 = xorFragments([fragment0, fragment1, fragment2, fragment3])

        let payloadsByFragment: [(UInt16, FrameFlags, Data)] = [
            (1, [.keyframe], fragment1),
            (2, [.keyframe], fragment2),
            (3, [.keyframe], fragment3),
            (4, [.keyframe], fragment4),
            (5, [.keyframe], fragment5),
            (6, [.keyframe, .fecParity], parity0),
        ]

        for (fragmentIndex, flags, payload) in payloadsByFragment {
            reassembler.processPacket(
                payload,
                header: makeHeader(
                flags: flags,
                frameNumber: 40,
                payload: payload,
                fragmentIndex: fragmentIndex,
                fragmentCount: 8,
                frameByteCount: 24,
                fecBlockSize: 4
            )
        )
    }

        let expectedFrame = fragment0 + fragment1 + fragment2 + fragment3 + fragment4 + fragment5
        #expect(deliveredFrame.value == expectedFrame)
    }

    private func makeHeader(
        flags: FrameFlags,
        frameNumber: UInt32,
        payload: Data,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        frameByteCount: UInt32? = nil,
        fecBlockSize: UInt8 = 0
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
            fecBlockSize: fecBlockSize,
            payloadLength: UInt32(payload.count),
            frameByteCount: frameByteCount ?? UInt32(payload.count),
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

    private func xorFragments(_ fragments: [Data]) -> Data {
        guard let first = fragments.first else { return Data() }
        var result = Data(repeating: 0, count: first.count)
        result.withUnsafeMutableBytes { resultBytes in
            let resultPointer = resultBytes.bindMemory(to: UInt8.self)
            guard let resultBase = resultPointer.baseAddress else { return }
            for fragment in fragments {
                fragment.withUnsafeBytes { fragmentBytes in
                    let fragmentPointer = fragmentBytes.bindMemory(to: UInt8.self)
                    guard let fragmentBase = fragmentPointer.baseAddress else { return }
                    for index in 0 ..< min(fragment.count, first.count) {
                        resultBase[index] ^= fragmentBase[index]
                    }
                }
            }
        }
        return result
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

private final class LockedOptionalData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}
#endif
