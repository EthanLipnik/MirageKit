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
        let deliveredCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
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

    @Test("Keyframe wait admits dependent P-frames after recovery keyframe")
    func keyframeWaitAdmitsDependentPFramesAfterRecoveryKeyframe() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }

        reassembler.beginKeyframeWait()

        let stalePFramePayload = Data([0x00, 0x00, 0x00, 0x02, 0x02, 0x03])
        reassembler.processPacket(
            stalePFramePayload,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 10,
                payload: stalePFramePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 0)

        let keyframePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            keyframePayload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 11,
                payload: keyframePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)
        #expect(reassembler.isAwaitingKeyframe == false)

        let dependentPFramePayload = Data([0x00, 0x00, 0x00, 0x03, 0x02, 0x04])
        reassembler.processPacket(
            dependentPFramePayload,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 12,
                payload: dependentPFramePayload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 2)
    }

    @Test("Delivered keyframe duplicate is dropped without triggering loss")
    func deliveredKeyframeDuplicateDoesNotTriggerLossLoop() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
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

    @Test("Multiple forward gaps stay buffered and drain in order")
    func sustainedForwardGapsDrainWithoutKeyframeWait() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
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
        #expect(reassembler.isAwaitingKeyframe == false)
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
        #expect(reassembler.isAwaitingKeyframe == false)
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
        #expect(reassembler.isAwaitingKeyframe == false)

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

    @Test("Severe forward gap buffers inside grace window")
    func severeForwardGapBuffersInsideGraceWindow() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, reason in
            lossCounter.increment()
            lossReason.value = reason
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

        let severeGapPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x28])
        reassembler.processPacket(
            severeGapPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 40,
                payload: severeGapPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(lossReason.value == nil)
        #expect(reassembler.isAwaitingKeyframe == false)
        #expect(reassembler.snapshotMetrics.pendingFrameCount == 1)
    }

    @Test("Severe forward gap enters keyframe wait after grace expires")
    func severeForwardGapEntersKeyframeWaitAfterGraceExpires() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, reason in
            lossCounter.increment()
            lossReason.value = reason
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

        let severeGapPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x28])
        reassembler.processPacket(
            severeGapPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 40,
                payload: severeGapPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(lossCounter.value == 0)

        Thread.sleep(forTimeInterval: 0.320)

        let laterSevereGapPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x29])
        reassembler.processPacket(
            laterSevereGapPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 41,
                payload: laterSevereGapPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 1)
        #expect(lossReason.value == .severeForwardGap)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

    @Test("Smoothest severe forward gap waits for reorder timeout")
    func smoothestSevereForwardGapWaitsForReorderTimeout() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        reassembler.setLatencyMode(.smoothest)
        reassembler.setTransportPathKind(.vpn)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, reason in
            lossCounter.increment()
            lossReason.value = reason
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

        let severeGapPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x28])
        reassembler.processPacket(
            severeGapPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 40,
                payload: severeGapPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(lossCounter.value == 0)

        Thread.sleep(forTimeInterval: 0.070)

        let reorderedWindowPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x29])
        reassembler.processPacket(
            reorderedWindowPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 41,
                payload: reorderedWindowPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(lossReason.value == nil)
        #expect(reassembler.isAwaitingKeyframe == false)

        Thread.sleep(forTimeInterval: 0.260)

        let timedOutPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x2A])
        reassembler.processPacket(
            timedOutPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 42,
                payload: timedOutPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 1)
        #expect(lossReason.value == .severeForwardGap)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

    @Test("Smoothest non-VPN severe forward gap also waits for reorder timeout")
    func smoothestNonVPNSevereForwardGapWaitsForReorderTimeout() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        reassembler.setLatencyMode(.smoothest)
        reassembler.setTransportPathKind(.wifi)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, reason in
            lossCounter.increment()
            lossReason.value = reason
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

        let severeGapPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x28])
        reassembler.processPacket(
            severeGapPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 40,
                payload: severeGapPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(lossCounter.value == 0)

        Thread.sleep(forTimeInterval: 0.070)

        let reorderedWindowPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x29])
        reassembler.processPacket(
            reorderedWindowPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 41,
                payload: reorderedWindowPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(lossReason.value == nil)
        #expect(reassembler.isAwaitingKeyframe == false)

        Thread.sleep(forTimeInterval: 0.260)

        let timedOutPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x2A])
        reassembler.processPacket(
            timedOutPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 42,
                payload: timedOutPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(lossCounter.value == 1)
        #expect(lossReason.value == .severeForwardGap)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

}

func makeHeader(
    flags: FrameFlags,
    frameNumber: UInt32,
    payload: Data,
    fragmentIndex: UInt16,
    fragmentCount: UInt16,
    frameByteCount: UInt32? = nil,
    fecBlockSize: UInt8 = 0,
    dimensionToken: UInt16 = 0
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
        dimensionToken: dimensionToken,
        epoch: 0
    )
}

func crc32(_ data: Data) -> UInt32 {
    let polynomial: UInt32 = 0xEDB8_8320
    var crc: UInt32 = 0xFFFF_FFFF
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
    return crc ^ 0xFFFF_FFFF
}

func xorFragments(_ fragments: [Data]) -> Data {
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

final class FrameReassemblerLockedCounter: @unchecked Sendable {
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

final class FrameReassemblerLockedOptionalData: @unchecked Sendable {
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

final class FrameReassemblerLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
#endif
