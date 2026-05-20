//
//  FrameReassemblerRecoveryProgressTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Frame Reassembler Recovery Progress")
struct FrameReassemblerRecoveryProgressTests {
    @Test("Newer keyframe progress fast-forwards a stalled P-frame gap")
    func pendingKeyframeProgressPromotesFastForwardRecovery() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
            lossCounter.increment()
        }

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )
        #expect(deliveredCounter.value == 1)

        let pFrame2 = Data([0x00, 0x00, 0x00, 0x02])
        reassembler.processPacket(
            pFrame2,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 2,
                payload: pFrame2,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )
        #expect(reassembler.isAwaitingKeyframe == false)

        let keyframe4Fragment0 = Data([0x00, 0x00, 0x00, 0x04])
        reassembler.processPacket(
            keyframe4Fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 4,
                payload: keyframe4Fragment0,
                fragmentIndex: 0,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        #expect(reassembler.isAwaitingKeyframe == true)
        #expect(lossCounter.value >= 1)

        let keyframe4Fragment1 = Data([0x26, 0x04, 0x04, 0x04])
        let keyframe4Fragment2 = Data([0x40, 0x40, 0x40, 0x40])
        let keyframe4Fragment3 = Data([0x41, 0x41, 0x41, 0x41])

        reassembler.processPacket(
            keyframe4Fragment1,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 4,
                payload: keyframe4Fragment1,
                fragmentIndex: 1,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )
        reassembler.processPacket(
            keyframe4Fragment2,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 4,
                payload: keyframe4Fragment2,
                fragmentIndex: 2,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )
        reassembler.processPacket(
            keyframe4Fragment3,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 4,
                payload: keyframe4Fragment3,
                fragmentIndex: 3,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        #expect(deliveredCounter.value == 2)
        #expect(reassembler.isAwaitingKeyframe == false)
    }

    @Test("Keyframe timeout tracks assembly progress instead of first-fragment age")
    func keyframeTimeoutTracksAssemblyProgress() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
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
        #expect(reassembler.isAwaitingKeyframe == false)

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

    @Test("P-frame timeout tracks fragment progress instead of first-fragment age")
    func pFrameTimeoutTracksFragmentProgress() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        reassembler.setLatencyMode(.smoothest)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
            lossCounter.increment()
        }

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )

        let fragment0 = Data([0x11, 0x11, 0x11, 0x11])
        reassembler.processPacket(
            fragment0,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment0,
                fragmentIndex: 0,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        try await Task.sleep(for: .milliseconds(220))

        let fragment1 = Data([0x22, 0x22, 0x22, 0x22])
        reassembler.processPacket(
            fragment1,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment1,
                fragmentIndex: 1,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        try await Task.sleep(for: .milliseconds(220))

        reassembler.processPacket(
            fragment0,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment0,
                fragmentIndex: 0,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe == false)

        let fragment2 = Data([0x33, 0x33, 0x33, 0x33])
        reassembler.processPacket(
            fragment2,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 1,
                payload: fragment2,
                fragmentIndex: 2,
                fragmentCount: 3,
                frameByteCount: 12
            )
        )

        #expect(deliveredCounter.value == 2)
        #expect(lossCounter.value == 0)
    }

    @Test("P-frame absolute lifetime cap eventually triggers recovery")
    func pFrameAbsoluteLifetimeCapTriggersRecovery() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
            lossCounter.increment()
        }

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )

        let fragment0 = Data([0x11, 0x11, 0x11, 0x11])
        reassembler.processPacket(
            fragment0,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment0,
                fragmentIndex: 0,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        try await Task.sleep(for: .milliseconds(230))

        let fragment1 = Data([0x22, 0x22, 0x22, 0x22])
        reassembler.processPacket(
            fragment1,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment1,
                fragmentIndex: 1,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        try await Task.sleep(for: .milliseconds(230))

        let fragment2 = Data([0x33, 0x33, 0x33, 0x33])
        reassembler.processPacket(
            fragment2,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment2,
                fragmentIndex: 2,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        try await Task.sleep(for: .milliseconds(180))

        reassembler.processPacket(
            fragment2,
            header: makeHeader(
                flags: [],
                frameNumber: 1,
                payload: fragment2,
                fragmentIndex: 2,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        let metrics = reassembler.snapshotMetrics
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value >= 1)
        #expect(reassembler.isAwaitingKeyframe == true)
        #expect(metrics.incompleteFrameTimeouts == 1)
        #expect(metrics.incompleteFrameNoProgressTimeouts == 0)
        #expect(metrics.incompleteFrameLifetimeTimeouts == 1)
    }

    @Test("Pending keyframe progress preserves dependent P-frames for post-keyframe drain")
    func pendingKeyframeProgressPreservesDependentPFramesForPostKeyframeDrain() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
            lossCounter.increment()
        }

        let keyframe0 = Data([0x00, 0x00, 0x00, 0x01])
        reassembler.processPacket(
            keyframe0,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: keyframe0,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )

        reassembler.beginKeyframeWait()

        let keyframe30Fragment0 = Data([0x00, 0x00, 0x00, 0x1E])
        reassembler.processPacket(
            keyframe30Fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 30,
                payload: keyframe30Fragment0,
                fragmentIndex: 0,
                fragmentCount: 8,
                frameByteCount: 32
            )
        )

        let pFrame31 = Data([0x1F, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            pFrame31,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 31,
                payload: pFrame31,
                fragmentIndex: 0,
                fragmentCount: 1,
                frameByteCount: 4
            )
        )

        var metrics = reassembler.snapshotMetrics
        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe == true)
        #expect(metrics.pendingKeyframeCount == 1)
        #expect(metrics.pendingFrameCount == 2)

        for fragmentIndex in UInt16(1) ..< UInt16(8) {
            let payload = Data([UInt8(fragmentIndex), 0x30, 0x30, 0x30])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: fragmentIndex == 7 ? [.keyframe, .endOfFrame] : [.keyframe],
                    frameNumber: 30,
                    payload: payload,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: 8,
                    frameByteCount: 32
                )
            )
        }

        metrics = reassembler.snapshotMetrics
        #expect(deliveredCounter.value == 3)
        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe == false)
        #expect(metrics.pendingFrameCount == 0)
    }

    @Test("Old incomplete keyframes are capped by memory budget")
    func oldIncompleteKeyframesAreCappedByMemoryBudget() {
        let reassembler = FrameReassembler(
            streamID: 1,
            maxPayloadSize: 4,
            memoryBudget: FrameReassembler.MemoryBudget(
                maxPendingFrames: 12,
                maxPendingKeyframes: 2,
                maxPendingBytes: 1024
            )
        )
        let lossCounter = FrameReassemblerLockedCounter()
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)
        reassembler.setFrameLossHandler { _, reason in
            lossCounter.increment()
            lossReason.value = reason
        }

        for frameNumber in UInt32(1) ... UInt32(3) {
            let payload = Data([UInt8(frameNumber), 0x00, 0x00, 0x00])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: [.keyframe],
                    frameNumber: frameNumber,
                    payload: payload,
                    fragmentIndex: 0,
                    fragmentCount: 4,
                    frameByteCount: 16
                )
            )
        }

        let metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameCount == 2)
        #expect(metrics.pendingKeyframeCount == 2)
        #expect(metrics.budgetEvictions == 1)
        #expect(lossCounter.value == 1)
        #expect(lossReason.value == .memoryBudget)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

    @Test("Memory budget keyframe wait purges dependent P-frame backlog")
    func memoryBudgetKeyframeWaitPurgesDependentPFrameBacklog() {
        let reassembler = FrameReassembler(
            streamID: 1,
            maxPayloadSize: 4,
            memoryBudget: FrameReassembler.MemoryBudget(
                maxPendingFrames: 3,
                maxPendingKeyframes: 2,
                maxPendingBytes: 1024
            )
        )
        let lossReason = FrameReassemblerLockedValue<FrameReassembler.FrameLossReason?>(nil)
        reassembler.setFrameLossHandler { _, reason in
            lossReason.value = reason
        }

        let keyframePayload = Data([0x00, 0x00, 0x00, 0x01])
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

        for frameNumber in UInt32(1) ... UInt32(4) {
            let payload = Data([UInt8(frameNumber), 0x00, 0x00, 0x00])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: [],
                    frameNumber: frameNumber,
                    payload: payload,
                    fragmentIndex: 0,
                    fragmentCount: 2,
                    frameByteCount: 8
                )
            )
        }

        let metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameCount == 0)
        #expect(metrics.budgetEvictions == 1)
        #expect(lossReason.value == .memoryBudget)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

    @Test("Pending encoded bytes preserve the most progressed keyframe")
    func pendingEncodedBytesPreserveMostProgressedKeyframe() {
        let budget = FrameReassembler.MemoryBudget(
            maxPendingFrames: 12,
            maxPendingKeyframes: 2,
            maxPendingBytes: 12
        )
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4, memoryBudget: budget)

        let payload1 = Data([0x01, 0x01, 0x01, 0x01])
        reassembler.processPacket(
            payload1,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 1,
                payload: payload1,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 8
            )
        )

        let payload2 = Data([0x02, 0x02, 0x02, 0x02])
        reassembler.processPacket(
            payload2,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 2,
                payload: payload2,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 8
            )
        )

        var metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameBytes <= budget.maxPendingBytes)
        #expect(metrics.pendingFrameCount == 1)

        let oversizedPayload = Data([0x03, 0x03, 0x03, 0x03])
        reassembler.processPacket(
            oversizedPayload,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 3,
                payload: oversizedPayload,
                fragmentIndex: 0,
                fragmentCount: 5,
                frameByteCount: 20
            )
        )

        metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameCount == 1)
        #expect(metrics.pendingKeyframeCount == 1)
        #expect(metrics.pendingFrameBytes == 8)
        #expect(metrics.pendingFrameBytes <= budget.maxPendingBytes)
        #expect(metrics.budgetEvictions == 1)
        #expect(metrics.droppedFrames == 2)
    }
}
#endif
