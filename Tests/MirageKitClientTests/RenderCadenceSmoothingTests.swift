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

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 9)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 9)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest ProMotion render store keeps a bounded FIFO playout queue")
    func smoothestProMotionRenderStoreKeepsBoundedFIFOQueue() {
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

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 13)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 13)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest uses timed playout without queue-level hold")
    func smoothestUsesTimedPlayoutWithoutQueueLevelHold() {
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

    @Test("Smoothest keeps normal 60Hz jitter instead of dropping it")
    func smoothestKeepsNormalSixtyHertzJitter() {
        let streamID: StreamID = 409
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
        for age in [0.035, 0.030, 0.025] {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(seconds: age, preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.pendingFrameCount == 3)
    }

    @Test("Smoothest uses tighter debt cap during recent input")
    func smoothestUsesTighterDebtCapDuringRecentInput() {
        let streamID: StreamID = 412
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
        MirageRenderStreamStore.shared.noteInteraction(for: streamID)

        for index in 0 ..< 20 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 7)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 14)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestDisplayDebtCapMs == 100)
        #expect(telemetry.smoothestDisplayDebtMs <= 100.1)
        #expect(telemetry.smoothestFifoResetCount == 0)
    }

    @Test("Smoothest recent input cap expires after idle window")
    func smoothestRecentInputCapExpiresAfterIdleWindow() {
        let streamID: StreamID = 413
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
        MirageRenderStreamStore.shared.noteInteraction(for: streamID, now: CFAbsoluteTimeGetCurrent() - 1.0)

        for index in 0 ..< 20 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestDisplayDebtCapMs == 150)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 10)
    }

    @Test("Smoothest hard resets only beyond three hundred milliseconds")
    func smoothestHardResetsOnlyBeyondThreeHundredMilliseconds() {
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60
        )
        let now = CFAbsoluteTimeGetCurrent()
        var softFrames = makeRenderFrames(count: 10, decodeTime: now - 0.299)
        let softSelection = MirageFramePlayoutQueue.selectFrame(
            frames: &softFrames,
            after: .zero,
            policy: policy,
            now: now
        )
        #expect(softSelection.frame?.sequence == 10)
        #expect(softSelection.trimResult.smoothestFifoResetCount == 0)

        var hardFrames = makeRenderFrames(count: 10, decodeTime: now - 0.301)
        let hardSelection = MirageFramePlayoutQueue.selectFrame(
            frames: &hardFrames,
            after: .zero,
            policy: policy,
            now: now
        )
        #expect(hardSelection.frame?.sequence == 10)
        #expect(hardSelection.trimResult.smoothestFifoResetCount == 1)
        #expect(hardFrames.count == 1)
    }

    @Test("Smoothest ProMotion tolerates short jitter without mass drops")
    func smoothestProMotionToleratesShortJitter() {
        let streamID: StreamID = 410
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

        let now = CFAbsoluteTimeGetCurrent()
        for age in [0.035, 0.028, 0.020, 0.012] {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - age,
                presentationTime: CMTime(seconds: age, preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame?.sequence == 1)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 0)
        #expect(telemetry.pendingFrameCount == 4)
    }

    @Test("Presentation timing separates immediate and scheduled modes")
    func presentationTimingSeparatesImmediateAndScheduledModes() {
        let referenceTime: CFTimeInterval = 100
        let timescale: CMTimeScale = 1_000_000_000
        let cadenceTarget = MirageStreamCadenceTarget(
            sourceFPS: 60,
            displayFPS: 60,
            latencyMode: .smoothest
        )
        #expect(cadenceTarget.playoutDelayFrames == 0)

        let lowestLatencyTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .lowestLatency
        )
        #expect(lowestLatencyTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(lowestLatencyTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)

        let smoothestTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            latencyMode: .smoothest
        )
        #expect(smoothestTiming.displaysImmediately)
        let smoothestPresentationSeconds = CMTimeGetSeconds(smoothestTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        ))
        #expect(abs(smoothestPresentationSeconds - referenceTime) < 0.000_001)
    }

    @Test("Explicit transport playout delay can raise smoothest to two frames")
    func explicitTransportPlayoutDelayCanRaiseSmoothestToTwoFrames() {
        let streamID: StreamID = 411
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let target = MirageStreamCadenceTarget(
            sourceFPS: 60,
            displayFPS: 60,
            latencyMode: .smoothest,
            playoutDelayFrames: 2
        )
        #expect(target.playoutDelayFrames == 2)

        MirageRenderStreamStore.shared.setCadenceTarget(for: streamID, target: target)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.playoutDelayFrames == 2)
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
        #expect(telemetry.coalescedBeforeSubmitCount == 2)
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

    private func makeRenderFrames(count: Int, decodeTime: CFAbsoluteTime) -> [MirageRenderFrame] {
        (0 ..< count).map { index in
            MirageRenderFrame(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                sequence: UInt64(index + 1),
                decodeTime: decodeTime,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                remotePresentationTime: .invalid
            )
        }
    }
}
#endif
