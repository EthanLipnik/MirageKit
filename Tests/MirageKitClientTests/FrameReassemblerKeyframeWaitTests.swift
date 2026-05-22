//
//  FrameReassemblerKeyframeWaitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
extension FrameReassemblerStaleKeyframeTests {
    @Test("VPN keyframes wait past the default no-progress timeout")
    func vpnKeyframeWaitsPastDefaultNoProgressTimeout() async throws {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        reassembler.setTransportPathKind(.vpn)
        let deliveredCounter = FrameReassemblerLockedCounter()
        let lossCounter = FrameReassemblerLockedCounter()

        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            deliveredCounter.increment()
            release()
        }
        reassembler.setFrameLossHandler { _, _ in
            lossCounter.increment()
        }

        let anchorKeyframe = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00])
        reassembler.processPacket(
            anchorKeyframe,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 0,
                payload: anchorKeyframe,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(deliveredCounter.value == 1)

        let partialKeyframe = Data(repeating: 0xAB, count: 1200)
        reassembler.processPacket(
            partialKeyframe,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 1,
                payload: partialKeyframe,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 2400
            )
        )

        try await Task.sleep(for: .milliseconds(5200))

        let laterPFrame = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x02])
        reassembler.processPacket(
            laterPFrame,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 2,
                payload: laterPFrame,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        #expect(deliveredCounter.value == 1)
        #expect(lossCounter.value == 0)
        #expect(reassembler.isAwaitingKeyframe == false)
    }

    @Test("P-frame timeout enters keyframe wait until new anchor arrives")
    func pFrameTimeoutEntersKeyframeWait() async throws {
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
        #expect(reassembler.isAwaitingKeyframe == true)
        let timeoutMetrics = reassembler.snapshotMetrics
        #expect(timeoutMetrics.incompleteFrameTimeouts == 1)
        #expect(timeoutMetrics.missingFragmentTimeouts == 1)

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
        #expect(reassembler.isAwaitingKeyframe == false)
    }

    @Test("Buffered forward gap without pending expected frame enters keyframe wait")
    func bufferedForwardGapWithoutExpectedFrameEntersKeyframeWait() async throws {
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
        #expect(reassembler.isAwaitingKeyframe == false)

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
        #expect(reassembler.isAwaitingKeyframe == true)

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
        #expect(reassembler.isAwaitingKeyframe == false)
    }
}
#endif
