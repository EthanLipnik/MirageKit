//
//  RenderFrameQueueSPSCTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latest-frame render store behavior.
//

@testable import MirageKitClient
import CoreMedia
import CoreVideo
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Render Stream Store")
struct RenderFrameQueueSPSCTests {
    @Test("Pending frames accumulate inside the bounded playout queue")
    func pendingFramesAccumulateInsideBoundedPlayoutQueue() {
        let streamID: StreamID = 301
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )
        let second = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            for: streamID
        )

        #expect(first.overwrittenPendingFrames == 0)
        #expect(second.overwrittenPendingFrames == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor.sequence == 1)
    }

    @Test("Lowest latency replaces older pending frames with the newest frame")
    func lowestLatencyReplacesOlderPendingFramesWithNewestFrame() {
        let streamID: StreamID = 9010
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 10 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + Double(index) * 0.001,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
        }

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor.sequence == 10)
        #expect(telemetry.overwrittenPendingFrames == 9)
        #expect(telemetry.renderStoreOverwriteFPS >= 9)
        #expect(telemetry.lowestLatencyFreshBacklogDrops == 0)
    }

    @Test("Lowest latency drops a stale singleton instead of presenting it late")
    func lowestLatencyDropsStaleSingletonInsteadOfPresentingItLate() {
        let streamID: StreamID = 9011
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .lowestLatency
            )
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        Thread.sleep(forTimeInterval: 0.05)

        let baseline = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: baseline)
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(frame == nil)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
        #expect(telemetry.lowestLatencyFreshBacklogDrops == 1)
        #expect(telemetry.lateFrameDrops == 1)
    }

    @Test("Smoothest preserves one fresh frame only while display cadence is healthy")
    func smoothestPreservesOneFreshFrameOnlyWhileDisplayCadenceIsHealthy() {
        let healthyStreamID: StreamID = 9012
        let underfiringStreamID: StreamID = 9013
        MirageRenderStreamStore.shared.clear(for: healthyStreamID)
        MirageRenderStreamStore.shared.clear(for: underfiringStreamID)
        defer {
            MirageRenderStreamStore.shared.clear(for: healthyStreamID)
            MirageRenderStreamStore.shared.clear(for: underfiringStreamID)
        }
        let now = CFAbsoluteTimeGetCurrent()

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: healthyStreamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 60, latencyMode: .smoothest)
        )
        let healthyFirst = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now,
            presentationTime: .zero,
            for: healthyStreamID
        )
        let healthySecond = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now + 0.001,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: healthyStreamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: healthyFirst.cursor,
            mappedPresentationTime: .zero,
            for: healthyStreamID
        )

        #expect(
            MirageRenderStreamStore.shared.shouldPreserveSmoothestPacingFrame(
                for: healthyStreamID,
                after: healthyFirst.cursor
            )
        )
        #expect(
            MirageRenderStreamStore.shared.hasFrameForPresentation(
                for: healthyStreamID,
                after: healthyFirst.cursor
            )
        )
        #expect(healthySecond.cursor.sequence == 2)

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: underfiringStreamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 40, latencyMode: .smoothest)
        )
        let underfiringFirst = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now,
            presentationTime: .zero,
            for: underfiringStreamID
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now + 0.001,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: underfiringStreamID
        )
        MirageRenderStreamStore.shared.noteDisplayTick(for: underfiringStreamID)
        Thread.sleep(forTimeInterval: 0.03)
        MirageRenderStreamStore.shared.noteDisplayTick(for: underfiringStreamID)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: underfiringFirst.cursor,
            mappedPresentationTime: .zero,
            for: underfiringStreamID
        )

        #expect(
            !MirageRenderStreamStore.shared.shouldPreserveSmoothestPacingFrame(
                for: underfiringStreamID,
                after: underfiringFirst.cursor
            )
        )

        let underfiringTelemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: underfiringStreamID)
        #expect(underfiringTelemetry.displayCadenceBelowSourceCount == 1)
    }

    @Test("Taking pending frames preserves bounded playout delay")
    func takePendingFramesPreservesBoundedPlayoutDelay() {
        let streamID: StreamID = 302
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        for index in 0 ..< 5 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let firstFrame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        let secondFrame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(firstFrame?.cursor.sequence == 4)
        #expect(secondFrame?.cursor.sequence == 5)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
    }

    @Test("Submission snapshot does not regress on older sequence marks")
    func submissionSnapshotDoesNotRegress() {
        let streamID: StreamID = 303
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let generation = MirageRenderStreamStore.shared.currentGeneration(for: streamID)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(generation: generation, sequence: 3),
            mappedPresentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(generation: generation, sequence: 2),
            mappedPresentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            for: streamID
        )

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(snapshot.cursor.sequence == 3)
        #expect(CMTimeCompare(snapshot.mappedPresentationTime, CMTime(seconds: 3, preferredTimescale: 600)) == 0)
    }

    @Test("Render telemetry reports submitted cadence and resets per-snapshot counters")
    func renderTelemetrySnapshot() {
        let streamID: StreamID = 304
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: 60)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        var latestCursor = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        for index in 0 ..< 3 {
            let result = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
            latestCursor = result.cursor
        }
        MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
        MirageRenderStreamStore.shared.noteSubmitAttempt(for: streamID)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: latestCursor,
            mappedPresentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.decodeFPS >= 1)
        #expect(telemetry.submitAttemptFPS >= 1)
        #expect(telemetry.layerEnqueueFPS >= 1)
        #expect(telemetry.uniqueLayerEnqueueFPS >= 1)
        #expect(telemetry.layerEnqueueFPS >= 1)
        #expect(telemetry.uniqueLayerEnqueueFPS >= 1)
        #expect(telemetry.pendingFrameCount == 2)
        #expect(telemetry.unsubmittedPendingFrameCount == 0)
        #expect(telemetry.retainedSubmittedFrameCount == 2)
        #expect(telemetry.overwrittenPendingFrames == 1)
        #expect(telemetry.displayLayerNotReadyCount == 1)
        #expect(telemetry.targetFPS == 60)

        let secondSnapshot = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(secondSnapshot.overwrittenPendingFrames == 0)
        #expect(secondSnapshot.displayLayerNotReadyCount == 0)
    }

    @Test("Render telemetry separates source and display cadence targets")
    func renderTelemetrySeparatesSourceAndDisplayCadenceTargets() {
        let streamID: StreamID = 309
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 30,
                displayFPS: 120,
                latencyMode: .lowestLatency
            )
        )
        for index in 0 ..< 30 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.sourceTargetFPS == 30)
        #expect(telemetry.displayTargetFPS == 120)
        #expect(telemetry.targetFPS == 30)
        #expect(telemetry.decodeHealthy)
    }

    @Test("Per-stream pending frames stay isolated")
    func perStreamIsolation() {
        let streamA: StreamID = 305
        let streamB: StreamID = 306
        MirageRenderStreamStore.shared.clear(for: streamA)
        MirageRenderStreamStore.shared.clear(for: streamB)
        defer {
            MirageRenderStreamStore.shared.clear(for: streamA)
            MirageRenderStreamStore.shared.clear(for: streamB)
        }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamA, latencyMode: .smoothest)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamB, latencyMode: .smoothest)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamA
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            for: streamA
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamB
        )

        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamA)?.cursor.sequence == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamB)?.cursor.sequence == 1)
    }

    @Test("Memory pressure clear removes only pending render frames")
    func memoryPressureClearRemovesOnlyPendingRenderFrames() {
        let streamID: StreamID = 308
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let generationBeforeTrim = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        var cursors: [MirageRenderCursor] = []
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 3 {
            let result = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + Double(index) * 0.001,
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
            cursors.append(result.cursor)
        }
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: cursors[1],
            mappedPresentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            for: streamID
        )

        let clearedCount = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)

        #expect(clearedCount == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
        #expect(snapshot.cursor.sequence == 2)
        #expect(snapshot.cursor.generation == generationBeforeTrim)
    }

    @Test("Submitted pending frame remains visible for peer presenters")
    func submittedPendingFrameRemainsVisibleForPeerPresenters() {
        let streamID: StreamID = 307
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let now = CFAbsoluteTimeGetCurrent()

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now,
            presentationTime: .zero,
            for: streamID
        )

        let firstPresenterFrame = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: firstPresenterFrame?.cursor ?? MirageRenderStreamStore.shared.baselineCursor(for: streamID),
            mappedPresentationTime: .zero,
            for: streamID
        )
        let secondPresenterFrame = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)
        let peerPresenterFrame = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        )

        #expect(firstPresenterFrame?.cursor.sequence == 1)
        #expect(secondPresenterFrame?.cursor.sequence == 1)
        #expect(peerPresenterFrame?.cursor.sequence == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
    }

    @Test("Stale-generation enqueue is rejected before assigning a render sequence")
    func staleGenerationEnqueueIsRejectedBeforeAssigningSequence() {
        let streamID: StreamID = 310
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let staleGeneration = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        MirageRenderStreamStore.shared.clear(for: streamID)

        let result = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            generation: staleGeneration,
            for: streamID
        )

        #expect(result.didEnqueue == false)
        #expect(result.cursor.sequence == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
    }

    @Test("Clear bumps render generation and newer generation progress can use lower sequence")
    func clearBumpsGenerationAndLowerSequenceCountsAsProgress() {
        let streamID: StreamID = 311
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let now = CFAbsoluteTimeGetCurrent()

        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now,
            presentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: first.cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )
        let oldCursor = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).cursor

        MirageRenderStreamStore.shared.clear(for: streamID)
        let second = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            for: streamID
        )
        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: oldCursor)

        #expect(second.cursor.sequence == 1)
        #expect(second.cursor.generation > oldCursor.generation)
        #expect(frame?.cursor == second.cursor)
    }

    @Test("Stale submitted cursor is ignored after generation bump")
    func staleSubmittedCursorIsIgnoredAfterGenerationBump() {
        let streamID: StreamID = 312
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let result = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )

        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: result.cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(snapshot.cursor.sequence == 0)
        #expect(snapshot.cursor.generation > result.cursor.generation)
    }

    @Test("Actionable pending count excludes retained submitted frames")
    func actionablePendingCountExcludesRetainedSubmittedFrames() {
        let streamID: StreamID = 313
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let now = CFAbsoluteTimeGetCurrent()

        let result = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: now,
            presentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: result.cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: result.cursor) == 0)
    }

    @Test("Display tick selection submits single pending frame and keeps one future frame")
    func displayTickSelectionSubmitsSinglePendingFrameAndKeepsOneFutureFrame() {
        let streamID: StreamID = 316
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        let baseline = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        let singlePendingSelection = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: baseline
        )
        #expect(singlePendingSelection?.cursor == first.cursor)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: first.cursor,
            mappedPresentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        let second = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )
        let future = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 3,
            presentationTime: CMTime(value: 3, timescale: 60),
            for: streamID
        )

        let backlogSelection = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: first.cursor
        )

        #expect(backlogSelection?.cursor == second.cursor)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: second.cursor) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor == second.cursor)
        #expect(future.cursor.isAfter(second.cursor))
    }

    @Test("Smoothest drains fresh upstream bursts in order")
    func smoothestDrainsFreshUpstreamBurstsInOrder() {
        let streamID: StreamID = 317
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: 60)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        let freshDecodeTime = CFAbsoluteTimeGetCurrent() + 1
        var cursors: [MirageRenderCursor] = []
        for index in 0 ..< 6 {
            let result = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: freshDecodeTime,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
            cursors.append(result.cursor)
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 6)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor == cursors.first)

        var submittedCursor = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        for cursor in cursors {
            let selected = MirageRenderStreamStore.shared.frameForPresentation(
                for: streamID,
                after: submittedCursor
            )
            #expect(selected?.cursor == cursor)
            MirageRenderStreamStore.shared.markSubmitted(
                cursor: cursor,
                mappedPresentationTime: CMTime(seconds: Double(cursor.sequence), preferredTimescale: 60),
                for: streamID
            )
            submittedCursor = cursor
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: submittedCursor) == 0)
    }

    @Test("Smoothest keeps one playout frame after decoded output gaps")
    func smoothestKeepsOnePlayoutFrameAfterDecodedOutputGaps() {
        let streamID: StreamID = 318
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: 60)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        let baseDecodeTime = CFAbsoluteTimeGetCurrent()
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: baseDecodeTime,
            presentationTime: .zero,
            for: streamID
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: baseDecodeTime + 0.105,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        #expect(timing.playoutDelayFrames == 1)

        for index in 2 ..< 10 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: baseDecodeTime + 0.105 + (Double(index - 1) / 60.0),
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
        }

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.playoutDelayFrames == 1)
        #expect(telemetry.pendingFrameCount <= 6)
    }

    @Test("Lowest latency ignores decoded output gaps and keeps latest only")
    func lowestLatencyIgnoresDecodedOutputGapsAndKeepsLatestOnly() {
        let streamID: StreamID = 319
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: 60)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .lowestLatency)

        let baseDecodeTime = CFAbsoluteTimeGetCurrent()
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: baseDecodeTime,
            presentationTime: .zero,
            for: streamID
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: baseDecodeTime + 0.105,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        let timing = MirageRenderStreamStore.shared.presentationTiming(for: streamID)
        #expect(timing.playoutDelayFrames == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor.sequence == 2)
    }

    @Test("Pending frame cursor fast path matches selection semantics")
    func pendingFrameCursorFastPathMatchesSelectionSemantics() {
        let streamID: StreamID = 315
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        let retainedFirst = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )
        let retainedSecond = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 3,
            presentationTime: CMTime(value: 3, timescale: 60),
            for: streamID
        )
        let baseline = MirageRenderStreamStore.shared.baselineCursor(for: streamID)

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)
        #expect(MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: baseline))
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: baseline) == 2)

        let firstSelected = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: baseline
        )
        #expect(firstSelected?.cursor == retainedFirst.cursor)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: firstSelected?.cursor ?? baseline) == 1)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: retainedFirst.cursor,
            mappedPresentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )
        #expect(MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: retainedFirst.cursor))

        let secondSelected = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: retainedFirst.cursor
        )
        #expect(secondSelected?.cursor == retainedSecond.cursor)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID, after: retainedSecond.cursor) == 0)
        #expect(!MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: retainedSecond.cursor))

        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        let newGenerationFrame = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 4,
            presentationTime: CMTime(value: 4, timescale: 60),
            for: streamID
        )

        #expect(newGenerationFrame.cursor.generation > retainedSecond.cursor.generation)
        #expect(MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: retainedSecond.cursor))
        #expect(
            MirageRenderStreamStore.shared.frameForPresentation(
                for: streamID,
                after: retainedSecond.cursor
            )?.cursor == newGenerationFrame.cursor
        )
    }

    @Test("Diagnostics retain cumulative render reset and recovery counters")
    func diagnosticsRetainCumulativeRenderResetAndRecoveryCounters() {
        final class Owner {}

        let streamID: StreamID = 314
        let owner = Owner()
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: owner) {}
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: owner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )
        _ = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        MirageRenderStreamStore.shared.recordPresenterTimingReset(
            for: streamID,
            reason: "render-generation-boundary"
        )
        MirageRenderStreamStore.shared.recordDisplayLayerLivenessReset(
            for: streamID,
            reason: "not-ready-pending-frame"
        )
        let handled = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
        _ = MirageRenderStreamStore.shared.bumpGeneration(for: streamID, reason: "host-epoch")
        MirageRenderStreamStore.shared.clear(for: streamID)

        let diagnostics = MirageRenderStreamStore.shared.diagnosticsSnapshot(for: streamID)
        #expect(handled == false)
        #expect(diagnostics.clearCount == 1)
        #expect(diagnostics.generationBumpCount == 2)
        #expect(diagnostics.memoryTrimClearCount == 1)
        #expect(diagnostics.presenterTimingResetCount == 1)
        #expect(diagnostics.presenterTimingResetReasons == "render-generation-boundary:1")
        #expect(diagnostics.displayLayerLivenessResetCount == 1)
        #expect(diagnostics.displayLayerLivenessResetReasons == "not-ready-pending-frame:1")
        #expect(diagnostics.presentationRecoveryRequestCount == 1)
        #expect(diagnostics.presentationRecoveryHandlerDispatchCount == 0)
        #expect(diagnostics.lastPresentationRecoveryOutcome == "noHandlers")
        #expect(diagnostics.lastGenerationBumpReason == "clear")
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        guard let buffer else {
            Issue.record("Failed to allocate CVPixelBuffer")
            fatalError("Unable to allocate CVPixelBuffer for test")
        }
        return buffer
    }
}
#endif
