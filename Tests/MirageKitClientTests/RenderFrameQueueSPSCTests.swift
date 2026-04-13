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
import Testing

#if os(macOS)
@Suite("Render Stream Store")
struct RenderFrameQueueSPSCTests {
    @Test("Newest pending frame overwrites older unsent frame")
    func newestPendingFrameOverwritesOlderFrame() {
        let streamID: StreamID = 301
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

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
        #expect(second.overwrittenPendingFrames == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 2)
    }

    @Test("Taking a pending frame returns only the newest frame")
    func takePendingFrameReturnsNewestOnly() {
        let streamID: StreamID = 302
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        for index in 0 ..< 5 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(frame?.sequence == 5)
        #expect(MirageRenderStreamStore.shared.takePendingFrame(for: streamID) == nil)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
    }

    @Test("Submission snapshot does not regress on older sequence marks")
    func submissionSnapshotDoesNotRegress() {
        let streamID: StreamID = 303
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 3,
            mappedPresentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 2,
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
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 3,
            mappedPresentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.decodeFPS >= 1)
        #expect(telemetry.submittedFPS >= 1)
        #expect(telemetry.uniqueSubmittedFPS >= 1)
        #expect(telemetry.pendingFrameCount == 1)
        #expect(telemetry.overwrittenPendingFrames == 2)
        #expect(telemetry.displayLayerNotReadyCount == 1)
        #expect(telemetry.targetFPS == 60)

        let secondSnapshot = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(secondSnapshot.overwrittenPendingFrames == 0)
        #expect(secondSnapshot.displayLayerNotReadyCount == 0)
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

        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamA)?.sequence == 2)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamB)?.sequence == 1)
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
