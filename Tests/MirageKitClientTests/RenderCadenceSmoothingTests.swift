//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latest-frame cadence behavior.
//

@testable import MirageKitClient
import CoreMedia
import CoreVideo
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Render Cadence Smoothing")
struct RenderCadenceSmoothingTests {
    @Test("Active render store keeps a tiny bounded playout queue")
    func activeRenderStoreKeepsTinyBoundedPlayoutQueue() {
        let streamID: StreamID = 401
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

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 4)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 2)
        #expect(telemetry.overwrittenPendingFrames == 3)
        #expect(telemetry.coalescedBeforeSubmitCount == 3)
        #expect(telemetry.playoutDelayFrames == 1)
    }

    @Test("Render telemetry reports unsubmitted frame ages without dropping Smoothest playout")
    func renderTelemetryReportsUnsubmittedFrameAgesWithoutDroppingSmoothestPlayout() {
        let streamID: StreamID = 406
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 3,
            presentationTime: CMTime(seconds: 3, preferredTimescale: 600),
            for: streamID
        )
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 4,
            presentationTime: CMTime(seconds: 4, preferredTimescale: 600),
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID, now: 5)
        #expect(telemetry.pendingFrameCount == 2)
        #expect(telemetry.unsubmittedPendingFrameCount == 2)
        #expect(telemetry.oldestUnsubmittedAgeMs == 2_000)
        #expect(telemetry.newestUnsubmittedAgeMs == 1_000)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 2)
    }

    @Test("Lowest latency display tick takes the newest decoded frame")
    func lowestLatencyDisplayTickTakesNewestDecodedFrame() {
        let streamID: StreamID = 402
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .lowestLatency)

        for index in 0 ..< 3 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(frame?.sequence == 3)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 0)
        #expect(telemetry.overwrittenPendingFrames == 2)
        #expect(telemetry.lateFrameDrops == 0)
    }

    @Test("Repeated submission marks do not create unique forward progress")
    func repeatedSubmissionMarksDoNotRepeatUniqueProgress() {
        let streamID: StreamID = 403
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let cursor = MirageRenderCursor(
            generation: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
            sequence: 1
        )

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.layerEnqueueFPS >= 2)
        #expect(telemetry.uniqueLayerEnqueueFPS >= 1)
        #expect(telemetry.uniqueLayerEnqueueFPS < telemetry.layerEnqueueFPS)
    }

    @Test("Taking the only pending frame does not repeat on underflow")
    func underflowDoesNotRepeatPendingFrame() {
        let streamID: StreamID = 404
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )

        let first = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        let second = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)

        #expect(first?.sequence == 1)
        #expect(second == nil)
    }

    @Test("Display tick telemetry records missed vsync and repeated frames")
    func displayTickTelemetryRecordsMissedVSyncAndRepeatedFrames() {
        let streamID: StreamID = 405
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.setTargetFPS(for: streamID, targetFPS: 60)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(
                generation: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
                sequence: 1
            ),
            mappedPresentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        Thread.sleep(forTimeInterval: 0.05)
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.displayTickFPS >= 2)
        #expect(telemetry.missedVSyncCount >= 1)
        #expect(telemetry.repeatedFrameCount == 1)
        #expect(telemetry.displayTickNoFrameCount == 1)
        #expect(telemetry.displayTickIntervalP99Ms >= 40)
        #expect(telemetry.displayTickIntervalMaxMs >= telemetry.displayTickIntervalP99Ms)
    }

    @Test("Render telemetry reports max submitted frame interval")
    func renderTelemetryReportsMaxSubmittedFrameInterval() {
        let streamID: StreamID = 407
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let generation = MirageRenderStreamStore.shared.currentGeneration(for: streamID)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(generation: generation, sequence: 1),
            mappedPresentationTime: .zero,
            for: streamID
        )
        Thread.sleep(forTimeInterval: 0.02)
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(generation: generation, sequence: 2),
            mappedPresentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.frameIntervalMaxMs >= 15)
        #expect(telemetry.frameIntervalMaxMs >= telemetry.frameIntervalP99Ms)
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
