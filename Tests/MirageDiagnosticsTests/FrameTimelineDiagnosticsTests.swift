//
//  FrameTimelineDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageCore
import MirageDiagnostics
import Testing

@Suite("Frame Timeline Diagnostics")
struct FrameTimelineDiagnosticsTests {
    @Test("Timeline marking operations preserve packet and presentation diagnostics")
    func timelineMarkingOperationsPreservePacketAndPresentationDiagnostics() {
        let timeline = MirageDiagnostics.FrameTimeline(
            streamID: 9,
            frameNumber: 42,
            dependencyEpoch: MirageDiagnostics.DependencyEpoch(3),
            isKeyframe: true,
            encodedByteCount: 1024,
            fragmentCount: 4
        )

        let marked = timeline
            .markingPacketReceived(at: 10, receivedFragmentCount: 1)
            .markingPacketReceived(at: 11, receivedFragmentCount: 3)
            .markingReassembled(
                at: 12,
                byteCount: 2048,
                receivedFragmentCount: 4,
                queueAgeMs: -5
            )
            .markingDecodeSubmitted(at: 13)
            .markingDecodeCallback(at: 14)
            .markingRenderEnqueued(at: 15, queueAgeMs: 7)
            .markingDisplayAccepted(at: 16)

        #expect(marked.streamID == 9)
        #expect(marked.frameNumber == 42)
        #expect(marked.dependencyEpoch == MirageDiagnostics.DependencyEpoch(3))
        #expect(marked.isKeyframe)
        #expect(marked.encodedByteCount == 2048)
        #expect(marked.fragmentCount == 4)
        #expect(marked.receivedFragmentCount == 4)
        #expect(marked.firstPacketReceiveTime == 10)
        #expect(marked.lastPacketReceiveTime == 12)
        #expect(marked.reassemblyCompleteTime == 12)
        #expect(marked.decodeSubmitTime == 13)
        #expect(marked.decodeCallbackTime == 14)
        #expect(marked.renderEnqueueTime == 15)
        #expect(marked.displayPresentationAcceptedTime == 16)
        #expect(marked.queueAgeMs == 7)
        #expect(marked.dropReason == nil)
    }

    @Test("Dropped timelines preserve receive time and reason")
    func droppedTimelinesPreserveReceiveTimeAndReason() {
        let timeline = MirageDiagnostics.FrameTimeline(
            streamID: 11,
            frameNumber: 7,
            dependencyEpoch: MirageDiagnostics.DependencyEpoch(4),
            isKeyframe: false,
            encodedByteCount: 512,
            fragmentCount: 2
        )

        let droppedWithoutPacket = timeline.markingDropped(.decodeFailure, at: 20)
        let droppedAfterPacket = timeline
            .markingPacketReceived(at: 21, receivedFragmentCount: 1)
            .markingDropped(.rendererQueueEviction, at: 22)

        #expect(droppedWithoutPacket.lastPacketReceiveTime == 20)
        #expect(droppedWithoutPacket.dropReason == .decodeFailure)
        #expect(droppedAfterPacket.lastPacketReceiveTime == 21)
        #expect(droppedAfterPacket.dropReason == .rendererQueueEviction)
        #expect(MirageDiagnostics.DependencyEpoch(4) > MirageDiagnostics.DependencyEpoch(3))
    }
}
