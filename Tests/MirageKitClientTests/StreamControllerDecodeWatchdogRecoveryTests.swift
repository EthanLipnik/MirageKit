//
//  StreamControllerDecodeWatchdogRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreMedia
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Stream Controller Decode Watchdog Recovery", .serialized)
struct StreamControllerDecodeWatchdogRecoveryTests {
    @Test("Post-resize decode threshold waits through grace window before recovery")
    func postResizeDecodeThresholdWaitsThroughGraceWindowBeforeRecovery() async throws {
        let streamID: StreamID = 246
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 2000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        await controller.beginPostResizeTransition()

        clock.advance(by: 0.1)
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(keyframeCounter.value == 0)

        clock.advance(by: 1.3)
        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("post-resize decode-threshold recovery after grace") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Soft recovery cadence suppresses duplicate threshold recoveries within cooldown")
    func softRecoveryCadenceSuppressesDuplicateThresholdRecoveries() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 500)
        let controller = StreamController(
            streamID: 145,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)

        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("first decode-threshold keyframe request") {
            keyframeCounter.value == 1
        }

        clock.advance(by: 0.6)
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(keyframeCounter.value == 1)

        clock.advance(by: StreamController.localDuplicateKeyframeRequestGrace)
        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("second decode-threshold keyframe request") {
            keyframeCounter.value >= 2
        }
        #expect(keyframeCounter.value >= 2)

        await controller.stop()
    }

    @Test("Frame-loss bootstrap requests keyframe before first decoded frame")
    func frameLossBootstrapRequestsKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 40, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.handleFrameLossSignal()
        try await streamControllerWaitUntil("bootstrap keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Freeze monitor requests recovery after real presentation progress stalls")
    func freezeMonitorRequestsRecoveryAfterPresentationStall() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 148
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()

        #expect(await controller.lastPresentedProgressTime > 0)

        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        try await streamControllerWaitUntil("freeze monitor keyframe request", timeout: .seconds(3)) {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Freeze monitor requests presenter recovery when render submission stalls with pending frames")
    func freezeMonitorRequestsPresenterRecoveryForRenderSubmissionStall() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 149
        let clock = StreamControllerManualTimeProvider(start: 8000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        await controller.simulatePresentationStall(now: clock.now)
        await controller.testSeedFrameRates(decodedFPS: 60, receivedFPS: 60, now: clock.now)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        await controller.evaluateFreezeState()
        #expect(keyframeCounter.value == 0)
        #expect(presenterRecoveryCounter.value == 1)
        let reassembler = await controller.reassembler
        #expect(!reassembler.isAwaitingKeyframe)

        await controller.stop()
    }

    @Test("Freeze monitor requests keyframe for stale pending frame without keyframe wait")
    func freezeMonitorRequestsKeyframeForStalePendingFrameWithoutKeyframeWait() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 157
        let clock = StreamControllerManualTimeProvider(start: 8600)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        await controller.simulatePresentationStall(now: clock.now)
        await controller.testSeedFrameRates(decodedFPS: 0, receivedFPS: 0, now: clock.now)

        let reassembler = await controller.reassembler
        #expect(!reassembler.isAwaitingKeyframe)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 1,
            presentationTime: .zero,
            for: streamID
        )

        await controller.evaluateFreezeState()

        #expect(keyframeCounter.value == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
        #expect(reassembler.isAwaitingKeyframe)

        await controller.stop()
    }

    @Test("Freeze monitor escalates after presenter recovery drops only pending frame")
    func freezeMonitorEscalatesAfterPresenterRecoveryDropsOnlyPendingFrame() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 158
        let clock = StreamControllerManualTimeProvider(start: 8700)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
            _ = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        await controller.simulatePresentationStall(now: clock.now)
        await controller.testSeedFrameRates(decodedFPS: 60, receivedFPS: 60, now: clock.now)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        await controller.evaluateFreezeState()
        #expect(presenterRecoveryCounter.value == 1)
        #expect(keyframeCounter.value == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        clock.advance(by: 1.0)
        await controller.testSeedFrameRates(decodedFPS: 0, receivedFPS: 0, now: clock.now)
        await controller.evaluateFreezeState()

        let reassembler = await controller.reassembler
        #expect(keyframeCounter.value == 1)
        #expect(reassembler.isAwaitingKeyframe)

        await controller.stop()
    }

    @Test("Frame-loss timeout routes pending render frames through presenter recovery")
    func frameLossTimeoutRoutesPendingRenderFramesThroughPresenterRecovery() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 155
        let clock = StreamControllerManualTimeProvider(start: 8400)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        await controller.handleFrameLossSignal()

        #expect(presenterRecoveryCounter.value == 1)
        #expect(keyframeCounter.value == 0)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)

        await controller.stop()
    }

    @Test("Frame-loss timeout clears stale pending render frames and requests keyframe")
    func frameLossTimeoutClearsStalePendingRenderFramesAndRequestsKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 156
        let clock = StreamControllerManualTimeProvider(start: 8500)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 1,
            presentationTime: .zero,
            for: streamID
        )

        await controller.handleFrameLossSignal()

        #expect(presenterRecoveryCounter.value == 0)
        #expect(keyframeCounter.value == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        await controller.stop()
    }

    @Test("Freeze monitor does not recover presentation while decode is stalled")
    func freezeMonitorDoesNotRecoverPresentationWhileDecodeIsStalled() async throws {
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 150
        let clock = StreamControllerManualTimeProvider(start: 8200)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()
        await controller.simulatePresentationStall(now: clock.now)
        await controller.testSeedFrameRates(decodedFPS: 0, receivedFPS: 60, now: clock.now)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        await controller.evaluateFreezeState()

        #expect(presenterRecoveryCounter.value == 0)

        await controller.stop()
    }

    @Test("First-frame watchdog uses hard recovery when startup is packet-starved")
    func firstFrameWatchdogUsesHardRecoveryWhenStartupIsPacketStarved() async throws {
        let clock = StreamControllerManualTimeProvider(start: 1000)
        let controller = StreamController(
            streamID: 140,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-stall")
        clock.advance(by: StreamController.firstPresentedFrameHardRecoveryGrace(for: .startup) + 0.1)

        var hardRecoveryTriggered = false
        let timeoutAt = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < timeoutAt {
            if await controller.lastHardRecoveryStartTime > 0 {
                hardRecoveryTriggered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hardRecoveryTriggered)

        await controller.stop()
    }

    @Test("First-frame watchdog requests keyframe before hard recovery when packets arrived")
    func firstFrameWatchdogRequestsKeyframeBeforeHardRecoveryWhenPacketsArrived() async throws {
        let clock = StreamControllerManualTimeProvider(start: 1200)
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(
            streamID: 141,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-packet-flow")

        let reassembler = await controller.reassembler
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            payload,
            header: makeStreamControllerVideoHeader(
                streamID: 141,
                flags: [.keyframe, .endOfFrame],
                frameNumber: 1,
                payload: payload
            )
        )

        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .startup) + 0.1)
        try await streamControllerWaitUntil("startup keyframe retry before hard recovery") {
            keyframeCounter.value == 1
        }

        #expect(await controller.lastHardRecoveryStartTime == 0)
        #expect(await controller.awaitingFirstPresentedFrame)

        await controller.stop()
    }

    @Test("Startup watchdog requests presenter recovery before keyframe recovery when decoded frame is pending")
    func startupWatchdogRequestsPresenterRecoveryBeforeKeyframeRecovery() async throws {
        let streamID: StreamID = 147
        let clock = StreamControllerManualTimeProvider(start: 6000)
        let keyframeCounter = StreamControllerLockedCounter()
        let presenterRecoveryCounter = StreamControllerLockedCounter()
        let presenterOwner = NSObject()
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerPresentationRecoveryHandler(for: streamID, owner: presenterOwner) {
            presenterRecoveryCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterPresentationRecoveryHandler(for: streamID, owner: presenterOwner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-presentation")
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .startup) + 0.1)
        try await streamControllerWaitUntil("startup presenter recovery request") {
            presenterRecoveryCounter.value == 1
        }

        #expect(keyframeCounter.value == 0)
        #expect(await controller.firstPresentedFrameRendererRecoveryAttemptCount == 1)
        #expect(await controller.lastHardRecoveryStartTime == 0)

        await controller.stop()
    }

    @Test("Manual recovery re-arms first-frame watchdog after prior presentation")
    func manualRecoveryRearmsFirstFrameWatchdogAfterPriorPresentation() async throws {
        let clock = StreamControllerManualTimeProvider(start: 3000)
        let controller = StreamController(
            streamID: 142,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()
        #expect(await controller.hasPresentedFirstFrame)
        #expect(await !(controller.awaitingFirstPresentedFrame))

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "application-activation-recovery"
        )

        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(await controller.firstPresentedFrameLastRecoveryRequestTime == 0)

        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .recovery) + 0.1)

        var watchdogTriggered = false
        let timeoutAt = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < timeoutAt {
            if await controller.firstPresentedFrameLastRecoveryRequestTime > 0 {
                watchdogTriggered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(watchdogTriggered)

        await controller.stop()
    }

    @Test("Hard recovery ignores stale first-frame presentation until sequence advances")
    func hardRecoveryIgnoresStaleFirstFramePresentationUntilSequenceAdvances() async {
        let streamID: StreamID = 152
        let clock = StreamControllerManualTimeProvider(start: 7000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()
        #expect(await controller.hasPresentedFirstFrame)

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )

        let staleProgress = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        #expect(!staleProgress)
        #expect(await controller.lastPresentedProgressTime == 0)
        #expect(await controller.clientRecoveryStatus == .hardRecovery)

        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        var recoveredProgress = false
        let timeoutAt = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < timeoutAt {
            let synced = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
            let progressTime = await controller.lastPresentedProgressTime
            if synced || progressTime > 0 {
                recoveredProgress = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(recoveredProgress)
        #expect(await controller.lastPresentedProgressTime > 0)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Throttled decode threshold after hard recovery progress keeps P-frame admission")
    func throttledDecodeThresholdAfterHardRecoveryProgressKeepsPFrameAdmission() async {
        let streamID: StreamID = 154
        let keyframeCounter = StreamControllerLockedCounter()
        let thresholdCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 7500)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.decoder.setErrorThresholdHandler {
            thresholdCounter.increment()
        }
        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )
        #expect(await controller.clientRecoveryStatus == .hardRecovery)
        #expect(keyframeCounter.value >= 1)

        guard let tracker = await controller.decoder.errorTracker else {
            Issue.record("Missing decoder error tracker")
            await controller.stop()
            MirageRenderStreamStore.shared.clear(for: streamID)
            return
        }
        #expect(!tracker.shouldDecodeFrame(isKeyframe: false))

        tracker.recordSuccess(isKeyframe: true)
        #expect(tracker.shouldDecodeFrame(isKeyframe: false))

        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        let recoveredProgress = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        #expect(recoveredProgress)
        await controller.clearTransientRecoveryStateAfterPresentationProgress()
        #expect(await controller.clientRecoveryStatus == .idle)

        let baselineThresholds = thresholdCounter.value
        let maxErrors = await controller.decoder.maxConsecutiveErrors
        tracker.lastThresholdTime = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< maxErrors {
            tracker.recordError(isKeyframe: false)
        }

        #expect(thresholdCounter.value == baselineThresholds)
        #expect(tracker.shouldDecodeFrame(isKeyframe: false))
        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }
}
#endif
