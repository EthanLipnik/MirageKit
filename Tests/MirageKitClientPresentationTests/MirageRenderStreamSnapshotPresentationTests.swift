//
//  MirageRenderStreamSnapshotPresentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreMedia
@testable import MirageKitClientPresentation
import Testing

@Suite("Render Stream Snapshots")
struct MirageRenderStreamSnapshotPresentationTests {
    @Test("Submission snapshots compare generation-aware cursors")
    func submissionSnapshotsCompareGenerationAwareCursors() {
        let baseline = SubmissionSnapshot(
            cursor: MirageRenderCursor(generation: 1, sequence: 7),
            sequence: 7,
            submittedTime: 100,
            remotePresentationTime: CMTime(value: 7, timescale: 60)
        )
        let sameSequenceNewGeneration = SubmissionSnapshot(
            cursor: MirageRenderCursor(generation: 2, sequence: 1),
            sequence: 1,
            submittedTime: 101,
            remotePresentationTime: CMTime(value: 8, timescale: 60)
        )
        let zeroSequence = SubmissionSnapshot(
            cursor: MirageRenderCursor(generation: 2, sequence: 0),
            sequence: 0,
            submittedTime: 102,
            remotePresentationTime: .invalid
        )

        #expect(sameSequenceNewGeneration.hasSubmittedFrame(after: baseline))
        #expect(!zeroSequence.hasSubmittedFrame(after: baseline))
    }

    @Test("Render enqueue result preserves queue telemetry")
    func renderEnqueueResultPreservesQueueTelemetry() {
        let result = MirageRenderEnqueueResult(
            cursor: MirageRenderCursor(generation: 3, sequence: 11),
            didEnqueue: true,
            pendingFrameCount: 2,
            pendingFrameAgeMs: 4.5,
            overwrittenPendingFrames: 1
        )

        #expect(result.cursor == MirageRenderCursor(generation: 3, sequence: 11))
        #expect(result.didEnqueue)
        #expect(result.pendingFrameCount == 2)
        #expect(result.pendingFrameAgeMs == 4.5)
        #expect(result.overwrittenPendingFrames == 1)
    }

    @Test("Render telemetry snapshot preserves presentation counters")
    func renderTelemetrySnapshotPreservesPresentationCounters() {
        let snapshot = RenderTelemetrySnapshot(
            displayTickFPS: 60,
            submitAttemptFPS: 58,
            layerAcceptedFPS: 57,
            visibleFrameFPS: 56,
            submittedFPS: 59,
            uniqueSubmittedFPS: 55,
            pendingFrameCount: 2,
            pendingFrameAgeMs: 12.5,
            pendingFrameAgeP95Ms: 20,
            pendingFrameAgeMaxMs: 24,
            pendingFrameDepthMax: 3,
            smoothestDisplayDebtMs: 4,
            smoothestDisplayDebtCapMs: 8,
            smoothestTargetDelayMs: 16,
            overwrittenPendingFrames: 1,
            smoothestQueueDrops: 2,
            smoothestDepthDrops: 3,
            smoothestAgeDrops: 4,
            smoothestDropsUnder100ms: 5,
            smoothestDroppedFrameAgeMaxMs: 6,
            smoothestDisplayDebtDrops: 7,
            smoothestFifoResetCount: 8,
            lateFrameDrops: 9,
            coalescedBeforeSubmitCount: 10,
            duplicateRemoteTimestampCount: 11,
            correctedStreamTimestampCount: 12,
            displayLayerNotReadyCount: 13,
            repeatedFrameCount: 14,
            displayTickNoFrameCount: 15,
            pendingFrameNotReadyDisplayTickCount: 16,
            frameArrivedAfterNoFrameTickCount: 17,
            frameArrivalFallbackCount: 18,
            frameArrivalFallbackScheduledCount: 19,
            frameArrivalFallbackSubmittedCount: 20,
            noFrameTickToFrameArrivalMaxMs: 21,
            missedVSyncCount: 22,
            displayTickIntervalP95Ms: 23,
            displayTickIntervalP99Ms: 24,
            playoutDelayFrames: 2,
            presentationStallCount: 25,
            worstPresentationGapMs: 26,
            frameIntervalP95Ms: 27,
            frameIntervalP99Ms: 28,
            decodeHealthy: true
        )

        #expect(snapshot.displayTickFPS == 60)
        #expect(snapshot.pendingFrameAgeMs == 12.5)
        #expect(snapshot.smoothestQueueDrops == 2)
        #expect(snapshot.frameArrivalFallbackSubmittedCount == 20)
        #expect(snapshot.decodeHealthy)
    }
}
