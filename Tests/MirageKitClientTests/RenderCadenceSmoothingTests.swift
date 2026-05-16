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
    @Test("Elastic smoothest controller requires health before live edge")
    func elasticSmoothestControllerRequiresHealthBeforeLiveEdge() {
        var controller = MirageSmoothestPlayoutController()
        let policy = MiragePresentationLatencyPolicy(
            latencyMode: .smoothest,
            sourceFPS: 60,
            displayFPS: 60
        )

        let initial = controller.presentationDecision(
            policy: policy,
            now: 10
        )
        #expect(initial.playoutDelayFrames == 0)
        #expect(initial.displaysImmediately)
        #expect(initial.queueTargetDepth == 2)
        #expect(initial.mode == .softCushion)

        controller.recordHealthSample(healthyForLiveEdge: true, at: 10.1)
        let firstHealthyWindow = controller.presentationDecision(
            policy: policy,
            now: 10.1
        )
        #expect(firstHealthyWindow.playoutDelayFrames == 0)
        #expect(firstHealthyWindow.displaysImmediately)
        #expect(firstHealthyWindow.queueTargetDepth == 1)
        #expect(firstHealthyWindow.mode == .liveEdge)

        controller.noteJitter(at: 10.2, severity: .hard)
        let cushioned = controller.presentationDecision(
            policy: policy,
            now: 10.5
        )
        #expect(cushioned.playoutDelayFrames == 0)
        #expect(cushioned.displaysImmediately)
        #expect(cushioned.queueTargetDepth == 4)
        #expect(cushioned.mode == .hardCushion)

        let stillCushioned = controller.presentationDecision(
            policy: policy,
        now: 10.7
        )
        #expect(stillCushioned.playoutDelayFrames == 0)
        #expect(stillCushioned.displaysImmediately)

        controller.recordHealthSample(healthyForLiveEdge: true, at: 11.0)
        controller.recordHealthSample(healthyForLiveEdge: true, at: 11.1)
        let recovered = controller.presentationDecision(
            policy: policy,
            now: 11.1
        )
        #expect(recovered.playoutDelayFrames == 0)
        #expect(recovered.displaysImmediately)
        #expect(recovered.queueTargetDepth == 1)
    }

    @Test("Smoothest render store keeps a bounded burst absorption queue")
    func smoothestRenderStoreKeepsBoundedBurstAbsorptionQueue() {
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

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 4)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 6)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 4)
        #expect(telemetry.overwrittenPendingFrames == 0)
        #expect(telemetry.smoothestQueueDrops == 5)
        #expect(telemetry.coalescedBeforeSubmitCount == 0)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest ProMotion render store keeps a bounded burst absorption queue")
    func smoothestProMotionRenderStoreKeepsBoundedBurstAbsorptionQueue() {
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

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 6)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 8)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 6)
        #expect(telemetry.smoothestQueueDrops == 7)
        #expect(telemetry.playoutDelayFrames == 0)
    }

    @Test("Smoothest uses immediate active playout after a jitter signal")
    func smoothestUsesImmediateActivePlayoutAfterJitterSignal() {
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
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)
        MirageRenderStreamStore.shared.noteDisplayTickWithoutFrame(for: streamID)

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
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.presentationMode == .hardCushion)
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

    @Test("Cushioned smoothest preserves normal 60Hz jitter FIFO")
    func cushionedSmoothestPreservesNormalSixtyHertzJitterFIFO() {
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
        #expect(frame?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 1)
        #expect(telemetry.pendingFrameCount == 2)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 2)
        #expect(telemetry.presentationMode == .softCushion)
    }

    @Test("Cushioned smoothest ProMotion preserves short jitter FIFO")
    func cushionedSmoothestProMotionPreservesShortJitterFIFO() {
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
        #expect(frame?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 1)
        #expect(telemetry.pendingFrameCount == 3)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 3)
        #expect(telemetry.presentationMode == .softCushion)
    }

    @Test("Healthy smoothest live edge catches up to newest")
    func healthySmoothestLiveEdgeCatchesUpToNewest() {
        let streamID: StreamID = 411
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
        MirageRenderStreamStore.shared.recordSmoothestStreamHealth(
            for: streamID,
            healthyForLiveEdge: true
        )
        MirageRenderStreamStore.shared.recordSmoothestStreamHealth(
            for: streamID,
            healthyForLiveEdge: true
        )

        for index in 0 ..< 4 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: CFAbsoluteTimeGetCurrent(),
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            )
        }

        let frame = MirageRenderStreamStore.shared.frameForPresentation(for: streamID, after: .zero)
        #expect(frame?.sequence == 4)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.smoothestQueueDrops == 3)
        #expect(telemetry.pendingFrameCount == 1)
        #expect(telemetry.playoutDelayFrames == 0)
        #expect(telemetry.displaysImmediately)
        #expect(telemetry.queueTargetDepth == 1)
        #expect(telemetry.presentationMode == .liveEdge)
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
        #expect(cadenceTarget.playoutDelayFrames == 1)

        let lowestLatencyTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            displaysImmediately: true
        )
        #expect(lowestLatencyTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(lowestLatencyTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)

        let healthySmoothestTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            displaysImmediately: true
        )
        #expect(healthySmoothestTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(healthySmoothestTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)

        let activeHardCushionTiming = MirageRenderPresentationTiming(
            targetFPS: 60,
            playoutDelayFrames: 0,
            displaysImmediately: true
        )
        #expect(activeHardCushionTiming.displaysImmediately)
        #expect(CMTimeGetSeconds(activeHardCushionTiming.presentationTime(
            referenceTime: referenceTime,
            timescale: timescale
        )) == referenceTime)
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
}
#endif
