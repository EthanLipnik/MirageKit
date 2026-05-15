//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latency-mode render cadence behavior.
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
    @Test("Smoothest render store keeps an ordered bounded playout queue")
    func smoothestRenderStoreKeepsOrderedBoundedPlayoutQueue() {
        let streamID: StreamID = 401
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: .smoothest)

        for index in 0 ..< 9 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 8)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 8)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 1)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest ProMotion render store keeps a deeper time-bounded queue")
    func smoothestProMotionRenderStoreKeepsDeeperQueue() {
        let streamID: StreamID = 406
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 120,
                displayFPS: 120,
                latencyMode: .smoothest
            )
        )

        for index in 0 ..< 13 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 12)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 12)
        #expect(telemetry.smoothestQueueDrops == 1)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest presents one pending frame without queue-level playout delay")
    func smoothestPresentsOnePendingFrameWithoutQueueLevelPlayoutDelay() {
        let streamID: StreamID = 407
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        let first = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(first?.sequence == 1)
        if let first {
            MirageRenderStreamStore.shared.markSubmitted(cursor: first.cursor, for: streamID)
        }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        let next = MirageRenderStreamStore.shared.frameForPresentation(
            for: streamID,
            after: first?.cursor ?? .zero
        )
        #expect(next?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest drops stale backlog before presenting a fresh frame")
    func smoothestDropsStaleBacklogBeforePresentingFreshFrame() {
        let streamID: StreamID = 408
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(
                sourceFPS: 60,
                displayFPS: 60,
                latencyMode: .smoothest
            )
        )

        let now = CFAbsoluteTimeGetCurrent()
        for index in 0 ..< 3 {
            let age: CFAbsoluteTime = index < 2 ? 0.350 : 0.050
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame?.sequence == 3)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 2)
        #expect(telemetry.pendingFrameCount == 1)
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
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.lateFrameDrops == 0)
    }

    @Test("Repeated submission marks do not create unique forward progress")
    func repeatedSubmissionMarksDoNotRepeatUniqueProgress() {
        let streamID: StreamID = 403
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.submittedFPS >= 2)
        #expect(telemetry.uniqueSubmittedFPS >= 1)
        #expect(telemetry.uniqueSubmittedFPS < telemetry.submittedFPS)
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

        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60)
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            for: streamID
        )
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        Thread.sleep(forTimeInterval: 0.05)
        MirageRenderStreamStore.shared.noteDisplayTick(for: streamID)
        MirageRenderStreamStore.shared.noteRepeatedDisplayTick(for: streamID)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.displayTickFPS >= 2)
        #expect(telemetry.missedVSyncCount >= 1)
        #expect(telemetry.repeatedFrameCount == 1)
        #expect(telemetry.displayTickIntervalP99Ms >= 40)
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
