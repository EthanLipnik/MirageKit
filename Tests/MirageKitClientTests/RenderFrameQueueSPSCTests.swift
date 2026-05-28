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

        #expect(first == 0)
        #expect(second == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)
    }

    @Test("Smoothest retains pending frames until their playout target")
    func smoothestRetainsPendingFramesUntilPlayoutTarget() {
        let streamID: StreamID = 302
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        for index in 0 ..< 4 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.takePendingFrame(for: streamID) == nil)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 4)
    }

    @Test("Smoothest depth cap drops are tracked separately from overwritten frames")
    func smoothestDepthCapDropsAreTrackedSeparatelyFromOverwrittenFrames() {
        let streamID: StreamID = 310
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        for index in 0 ..< 40 {
            let overwritten = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
            #expect(overwritten == 0)
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 25)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 16)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 15)
        #expect(telemetry.smoothestDepthDrops == 15)
        #expect(telemetry.smoothestDisplayDebtDrops == 0)
        #expect(telemetry.smoothestFifoResetCount == 0)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
    }

    @Test("Submission snapshot does not regress on older sequence marks")
    func submissionSnapshotDoesNotRegress() {
        let streamID: StreamID = 303
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 3,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 2,
            for: streamID
        )

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(snapshot.sequence == 3)
    }

    @Test("Stale presenter cursor is ignored after render-store clear")
    func stalePresenterCursorIsIgnoredAfterRenderStoreClear() {
        let streamID: StreamID = 311
        MirageRenderStreamStore.shared.clear(for: streamID)
        let listenerOwner = NSObject()
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: listenerOwner) {}
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: listenerOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            for: streamID
        )
        let staleCursor = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor
        #expect(staleCursor != nil)

        MirageRenderStreamStore.shared.clear(for: streamID)
        if let staleCursor {
            MirageRenderStreamStore.shared.markSubmitted(cursor: staleCursor, for: streamID)
        }

        let staleSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(staleSnapshot.sequence == 0)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            for: streamID
        )
        let currentCursor = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor
        #expect(currentCursor != nil)

        guard let currentCursor else {
            Issue.record("Expected current cursor after render-store clear")
            return
        }
        MirageRenderStreamStore.shared.markSubmitted(cursor: currentCursor, for: streamID)

        let currentSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(currentSnapshot.sequence == currentCursor.sequence)
    }

    @Test("Stale decoded generation is ignored after render-store clear")
    func staleDecodedGenerationIsIgnoredAfterRenderStoreClear() {
        let streamID: StreamID = 312
        MirageRenderStreamStore.shared.clear(for: streamID)
        let listenerOwner = NSObject()
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: listenerOwner) {}
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: listenerOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        let staleGeneration = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        MirageRenderStreamStore.shared.clear(for: streamID)

        let staleResult = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            generation: staleGeneration,
            hostEpoch: nil,
            dimensionToken: nil,
            frameNumber: 1,
            queueEpoch: nil,
            timeline: nil,
            for: streamID
        )

        #expect(!staleResult.didEnqueue)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        let currentResult = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            generation: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
            hostEpoch: nil,
            dimensionToken: nil,
            frameNumber: 2,
            queueEpoch: nil,
            timeline: nil,
            for: streamID
        )

        #expect(currentResult.didEnqueue)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
    }

    @Test("Render telemetry reports submitted cadence and resets per-snapshot counters")
    func renderTelemetrySnapshot() {
        let streamID: StreamID = 304
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60)
        )
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        for index in 0 ..< 3 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }
        MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
        MirageRenderStreamStore.shared.noteSubmitAttempt(for: streamID)
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 3,
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.submitAttemptFPS >= 1)
        #expect(telemetry.layerAcceptedFPS >= 1)
        #expect(telemetry.visibleFrameFPS >= 1)
        #expect(telemetry.submittedFPS >= 1)
        #expect(telemetry.uniqueSubmittedFPS >= 1)
        #expect(telemetry.pendingFrameCount == 3)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.displayLayerNotReadyCount == 1)

        let secondSnapshot = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(secondSnapshot.overwrittenPendingFrames == 0)
        #expect(secondSnapshot.smoothestQueueDrops == 0)
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

        #expect(MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID).decodeHealthy)
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

        for index in 0 ..< 3 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 2,
            for: streamID
        )

        let clearedCount = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)

        #expect(clearedCount == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
        #expect(snapshot.sequence == 2)
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
            sequence: firstPresenterFrame?.sequence ?? 0,
            for: streamID
        )
        let secondPresenterFrame = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)
        let peerPresenterFrame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)

        #expect(firstPresenterFrame?.sequence == 1)
        #expect(secondPresenterFrame?.sequence == 1)
        #expect(peerPresenterFrame?.sequence == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
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
