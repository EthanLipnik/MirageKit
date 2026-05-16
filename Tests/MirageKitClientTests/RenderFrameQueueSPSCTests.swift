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
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)

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

    @Test("Cushioned smoothest drains retained FIFO backlog")
    func cushionedSmoothestDrainsRetainedFIFOBacklog() {
        let streamID: StreamID = 302
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)

        for index in 0 ..< 4 {
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
        #expect(firstFrame?.sequence == 1)
        #expect(secondFrame?.sequence == 2)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 4)
        #expect(telemetry.presentationMode == .hardCushion)
    }

    @Test("Cushioned smoothest preserves FIFO after jitter")
    func cushionedSmoothestPreservesFIFOAfterJitter() {
        let streamID: StreamID = 311
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)

        for index in 0 ..< 4 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let firstFrame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(firstFrame?.sequence == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 3)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 4)
        #expect(telemetry.presentationMode == .hardCushion)
    }

    @Test("Smoothest queue overflow is tracked separately from overwritten frames")
    func smoothestQueueOverflowIsTrackedSeparatelyFromOverwrittenFrames() {
        let streamID: StreamID = 310
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)

        for index in 0 ..< 10 {
            let overwritten = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
            #expect(overwritten == 0)
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 4)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 7)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 6)
        #expect(telemetry.smoothestCapacityDrops == 6)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 4)
        #expect(telemetry.presentationMode == .hardCushion)
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
        #expect(telemetry.presentedFPS >= 1)
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
