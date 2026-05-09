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
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)
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
        #expect(firstFrame?.sequence == 4)
        #expect(secondFrame?.sequence == 5)
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
        #expect(snapshot.sequence == 3)
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

        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamA)?.sequence == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamB)?.sequence == 1)
    }

    @Test("Memory pressure clear removes only pending render frames")
    func memoryPressureClearRemovesOnlyPendingRenderFrames() {
        let streamID: StreamID = 308
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let generationBeforeTrim = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        var cursors: [MirageRenderCursor] = []

        for index in 0 ..< 3 {
            let result = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
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
        #expect(snapshot.sequence == 2)
        #expect(snapshot.generation == generationBeforeTrim)
    }

    @Test("Submitted pending frame remains visible for peer presenters")
    func submittedPendingFrameRemainsVisibleForPeerPresenters() {
        let streamID: StreamID = 307
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
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

        #expect(firstPresenterFrame?.sequence == 1)
        #expect(secondPresenterFrame?.sequence == 1)
        #expect(peerPresenterFrame?.sequence == 1)
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
        #expect(result.sequence == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
    }

    @Test("Clear bumps render generation and newer generation progress can use lower sequence")
    func clearBumpsGenerationAndLowerSequenceCountsAsProgress() {
        let streamID: StreamID = 311
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
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
            decodeTime: 2,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            for: streamID
        )
        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: oldCursor)

        #expect(second.sequence == 1)
        #expect(second.generation > oldCursor.generation)
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
        #expect(snapshot.sequence == 0)
        #expect(snapshot.generation > result.generation)
    }

    @Test("Actionable pending count excludes retained submitted frames")
    func actionablePendingCountExcludesRetainedSubmittedFrames() {
        let streamID: StreamID = 313
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let result = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
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
