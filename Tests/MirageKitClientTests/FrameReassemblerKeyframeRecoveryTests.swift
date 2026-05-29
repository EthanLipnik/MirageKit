//
//  FrameReassemblerKeyframeRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Frame Reassembler Keyframe Recovery")
struct FrameReassemblerKeyframeRecoveryTests {
    @Test("Mismatched dimension-token keyframe is rejected")
    func mismatchedDimensionTokenKeyframeIsRejected() {
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
        reassembler.updateExpectedDimensionToken(2)

        let staleKeyframe = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            staleKeyframe,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 10,
                payload: staleKeyframe,
                fragmentIndex: 0,
                fragmentCount: 1,
                dimensionToken: 1
            )
        )

        #expect(deliveredCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe == true)

        let stalePFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x11])
        reassembler.processPacket(
            stalePFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 11,
                payload: stalePFrame,
                fragmentIndex: 0,
                fragmentCount: 1,
                dimensionToken: 1
            )
        )

        #expect(deliveredCounter.value == 0)
        #expect(lossCounter.value == 0)

        let currentKeyframe = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x02])
        reassembler.processPacket(
            currentKeyframe,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 12,
                payload: currentKeyframe,
                fragmentIndex: 0,
                fragmentCount: 1,
                dimensionToken: 2
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(reassembler.isAwaitingKeyframe == false)
    }

    @Test("Dimension-change reset preserves delivered keyframe anchor")
    func dimensionChangeResetPreservesDeliveredKeyframeAnchor() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        let deliveredCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }

        let keyframe = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            keyframe,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 100,
                payload: keyframe,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        reassembler.resetAfterDeliveredDimensionChangeKeyframe(frameNumber: 100)

        let pFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x11])
        reassembler.processPacket(
            pFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 101,
                payload: pFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 2)
        #expect(reassembler.hasKeyframeAnchor == true)
        #expect(reassembler.isAwaitingKeyframe == false)
    }

    @Test("Keyframe FEC recovery infers startup block size from fragment layout")
    func keyframeFECRecoveryInfersStartupBlockSize() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredFrame = FrameReassemblerLockedOptionalData()

        reassembler.setFrameHandler { _, data, _, _, _, _, release in
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

    @Test("Keyframe FEC block size one is ignored")
    func keyframeFECBlockSizeOneIsIgnored() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        let deliveredFrame = FrameReassemblerLockedOptionalData()

        reassembler.setFrameHandler { _, data, _, _, _, _, release in
            deliveredFrame.set(data)
            release()
        }

        let fragment0 = Data([0x00, 0x00, 0x00, 0x01])
        let fragment1 = Data([0x26, 0xAA, 0xBB, 0xCC])
        let fragment2 = Data([0x11, 0x22, 0x33, 0x44])

        let payloadsByFragment: [(UInt16, FrameFlags, Data)] = [
            (0, [.keyframe], fragment0),
            (2, [.keyframe], fragment2),
            (4, [.keyframe, .fecParity], fragment1),
        ]

        for (fragmentIndex, flags, payload) in payloadsByFragment {
            reassembler.processPacket(
                payload,
                header: makeHeader(
                    flags: flags,
                    frameNumber: 41,
                    payload: payload,
                    fragmentIndex: fragmentIndex,
                    fragmentCount: 6,
                    frameByteCount: 12,
                    fecBlockSize: 1
                )
            )
        }

        #expect(deliveredFrame.value == nil)
    }
}
#endif
