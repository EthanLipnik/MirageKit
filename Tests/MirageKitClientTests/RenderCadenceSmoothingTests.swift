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
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor.sequence == 4)

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
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 3 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + Double(index) * 0.001,
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        #expect(frame?.cursor.sequence == 3)
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

    @Test("Repeated source frames do not create visible cadence")
    func repeatedSourceFramesDoNotCreateVisibleCadence() {
        let streamID: StreamID = 409
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }
        let generation = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        let firstCursor = MirageRenderCursor(generation: generation, sequence: 1)
        let secondCursor = MirageRenderCursor(generation: generation, sequence: 2)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: firstCursor,
            mappedPresentationTime: .zero,
            presentedFrameIdentity: MirageRenderStreamStore.PresentedFrameIdentity(
                cursor: firstCursor,
                hostEpoch: 1,
                dimensionToken: 1,
                frameNumber: 10
            ),
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: secondCursor,
            mappedPresentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            presentedFrameIdentity: MirageRenderStreamStore.PresentedFrameIdentity(
                cursor: secondCursor,
                hostEpoch: 1,
                dimensionToken: 1,
                frameNumber: 10
            ),
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.uniqueLayerEnqueueFPS >= 2)
        #expect(telemetry.visibleFrameCadenceKnown)
        #expect(telemetry.visibleFrameFPS == 1)
        #expect(telemetry.visibleFrameFPS < telemetry.uniqueLayerEnqueueFPS)
        #expect(telemetry.repeatedSourceFrameCount == 1)
    }

    @Test("Taking the only pending frame does not repeat on underflow")
    func underflowDoesNotRepeatPendingFrame() {
        let streamID: StreamID = 404
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        let first = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        let second = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)

        #expect(first?.cursor.sequence == 1)
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
        #expect(telemetry.tickNoEligibleFrameCount == 1)
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

    @Test("Render telemetry reports display worker and renderer readiness diagnostics")
    func renderTelemetryReportsDisplayWorkerAndRendererReadinessDiagnostics() {
        let streamID: StreamID = 408
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.noteDisplayLinkCallbacks(for: streamID, count: 3)
        MirageRenderStreamStore.shared.noteDisplayTickWorker(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickMainRelay(for: streamID, delayMs: 42)
        MirageRenderStreamStore.shared.noteRenderWorkerSubmitDelay(for: streamID, delayMs: 17)
        MirageRenderStreamStore.shared.noteSampleBufferRendererNotReady(for: streamID)
        MirageRenderStreamStore.shared.notePresentationPass(for: streamID, framesSubmitted: 2)
        MirageRenderStreamStore.shared.notePresentationEligibleFrame(for: streamID)
        MirageRenderStreamStore.shared.noteFrameArrivedAfterNoFrameTick(for: streamID, delayMs: 19)
        MirageRenderStreamStore.shared.noteFrameArrivalFallback(for: streamID)
        MirageRenderStreamStore.shared.noteFrameArrivalFallbackSubmitted(for: streamID)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.renderStoreEnqueueFPS == telemetry.decodeFPS)
        #expect(telemetry.displayLinkCallbackFPS == 3)
        #expect(telemetry.displayTickWorkerFPS == 1)
        #expect(telemetry.displayTickMainRelayFPS == 1)
        #expect(telemetry.presentationPassFPS == 1)
        #expect(telemetry.framesSubmittedPerPassAverage == 2)
        #expect(telemetry.framesSubmittedPerPassMax == 2)
        #expect(telemetry.presentationEligibleFPS == 1)
        #expect(telemetry.displayTickMainDelayMaxMs == 42)
        #expect(telemetry.renderWorkerSubmitDelayMaxMs == 17)
        #expect(telemetry.sampleBufferRendererNotReadyCount == 1)
        #expect(telemetry.frameArrivedAfterNoFrameTickCount == 1)
        #expect(telemetry.frameArrivalFallbackScheduledCount == 1)
        #expect(telemetry.frameArrivalFallbackSubmittedCount == 1)
        #expect(telemetry.noFrameTickToFrameArrivalMaxMs == 19)
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
