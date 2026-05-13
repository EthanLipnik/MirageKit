//
//  FrameReassemblerMemoryBudgetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Frame Reassembler Memory Budget")
struct FrameReassemblerMemoryBudgetTests {
    @Test("Memory budget prefers newer keyframes until old progress is near complete")
    func memoryBudgetPrefersNewerKeyframesUntilOldProgressIsNearComplete() {
        let budget = FrameReassembler.MemoryBudget(
            maxPendingFrames: 12,
            maxPendingKeyframes: 2,
            maxPendingBytes: 20
        )
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4, memoryBudget: budget)

        let keyframe10Fragment0 = Data([0x10, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            keyframe10Fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 10,
                payload: keyframe10Fragment0,
                fragmentIndex: 0,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        let keyframe10Fragment1 = Data([0x10, 0x01, 0x00, 0x00])
        reassembler.processPacket(
            keyframe10Fragment1,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 10,
                payload: keyframe10Fragment1,
                fragmentIndex: 1,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        let keyframe11Fragment0 = Data([0x11, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            keyframe11Fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 11,
                payload: keyframe11Fragment0,
                fragmentIndex: 0,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        let metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameCount == 1)
        #expect(metrics.pendingKeyframeCount == 1)
        #expect(metrics.budgetEvictions == 1)

        let deliveredFrames = DeliveredFrames()
        reassembler.onFrameComplete = { _, _, _, frameNumber, _, _, releaseBuffer in
            deliveredFrames.append(frameNumber)
            releaseBuffer()
        }
        for fragmentIndex in 1 ..< 4 {
            let payload = Data([0x11, UInt8(fragmentIndex), 0x00, 0x00])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: [.keyframe],
                    frameNumber: 11,
                    payload: payload,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: 4,
                    frameByteCount: 16
                )
            )
        }
        #expect(deliveredFrames.values == [11])
    }

    @Test("Memory budget preserves a nearly complete recovery keyframe")
    func memoryBudgetPreservesNearlyCompleteRecoveryKeyframe() {
        let budget = FrameReassembler.MemoryBudget(
            maxPendingFrames: 12,
            maxPendingKeyframes: 2,
            maxPendingBytes: 20
        )
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4, memoryBudget: budget)

        for fragmentIndex in 0 ..< 3 {
            let payload = Data([0x10, UInt8(fragmentIndex), 0x00, 0x00])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: [.keyframe],
                    frameNumber: 10,
                    payload: payload,
                    fragmentIndex: UInt16(fragmentIndex),
                    fragmentCount: 4,
                    frameByteCount: 16
                )
            )
        }

        let keyframe11Fragment0 = Data([0x11, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            keyframe11Fragment0,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 11,
                payload: keyframe11Fragment0,
                fragmentIndex: 0,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )

        let metrics = reassembler.snapshotMetrics
        #expect(metrics.pendingFrameCount == 1)
        #expect(metrics.pendingKeyframeCount == 1)
        #expect(metrics.budgetEvictions == 1)

        let deliveredFrames = DeliveredFrames()
        reassembler.onFrameComplete = { _, _, _, frameNumber, _, _, releaseBuffer in
            deliveredFrames.append(frameNumber)
            releaseBuffer()
        }
        let finalFragment = Data([0x10, 0x03, 0x00, 0x00])
        reassembler.processPacket(
            finalFragment,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 10,
                payload: finalFragment,
                fragmentIndex: 3,
                fragmentCount: 4,
                frameByteCount: 16
            )
        )
        #expect(deliveredFrames.values == [10])
    }

    @Test("Memory pressure trim clears pending reassembly and requests recovery")
    func memoryPressureTrimClearsPendingReassemblyAndRequestsRecovery() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)

        for frameNumber in UInt32(1) ... UInt32(2) {
            let payload = Data([UInt8(frameNumber), 0x00, 0x00, 0x00])
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: [.keyframe],
                    frameNumber: frameNumber,
                    payload: payload,
                    fragmentIndex: 0,
                    fragmentCount: 3,
                    frameByteCount: 12
                )
            )
        }

        let trimResult = reassembler.trimForMemoryPressure()
        let metrics = reassembler.snapshotMetrics
        #expect(trimResult.evictedFrames == 2)
        #expect(trimResult.releasedPendingBytes == 24)
        #expect(trimResult.purgedRetainedBytes == 24)
        #expect(metrics.pendingFrameCount == 0)
        #expect(metrics.pendingFrameBytes == 0)
        #expect(metrics.frameBufferPoolRetainedBytes == 0)
        #expect(reassembler.isAwaitingKeyframe == true)
    }
}

private final class DeliveredFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frameNumbers: [UInt32] = []

    var values: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return frameNumbers
    }

    func append(_ frameNumber: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        frameNumbers.append(frameNumber)
    }
}
#endif
