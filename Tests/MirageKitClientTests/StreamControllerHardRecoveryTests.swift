//
//  StreamControllerHardRecoveryTests.swift
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
@Suite("Stream Controller Hard Recovery", .serialized)
struct StreamControllerHardRecoveryTests {
    @Test("Freeze monitor pauses while hard recovery waits for recovered frame")
    func freezeMonitorPausesWhileHardRecoveryWaitsForRecoveredFrame() async throws {
        let clock = StreamControllerManualTimeProvider(start: 1500)
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 153
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
        await controller.updatePresentationTier(.activeLive)
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )
        try await streamControllerWaitUntil("initial hard-recovery keyframe request") {
            keyframeCounter.value == 1
        }

        await controller.simulatePresentationStall(now: clock.now)
        try await Task.sleep(for: .milliseconds(700))

        #expect(keyframeCounter.value == 1)
        #expect(await controller.clientRecoveryStatus == .hardRecovery)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Startup hard recovery budget escalates to terminal failure")
    func startupHardRecoveryBudgetEscalatesToTerminalFailure() async throws {
        let clock = StreamControllerManualTimeProvider(start: 4000)
        let failures = StreamControllerLockedTerminalStartupFailure()
        let controller = StreamController(
            streamID: 144,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onTerminalStartupFailure: { failure in
                failures.record(failure)
            }
        )

        await controller.requestRecovery(
            reason: .startupKeyframeTimeout,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "initial-startup"
        )
        #expect(await controller.startupHardRecoveryCount == 1)

        clock.advance(by: StreamController.hardRecoveryMinimumInterval + 0.1)
        await controller.requestRecovery(
            reason: .startupKeyframeTimeout,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "initial-startup"
        )

        try await streamControllerWaitUntil("terminal startup failure callback") {
            failures.value != nil
        }

        let failure = try #require(failures.value)
        #expect(failure.reason == .startupKeyframeTimeout)
        #expect(failure.hardRecoveryAttempts == StreamController.startupHardRecoveryLimit)
        #expect(failure.waitReason == "initial-startup")

        await controller.stop()
    }

    @Test("First-frame presentation clears startup hard recovery budget")
    func firstFramePresentationClearsStartupHardRecoveryBudget() async {
        let clock = StreamControllerManualTimeProvider(start: 5000)
        let streamID: StreamID = 145
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.requestRecovery(
            reason: .startupKeyframeTimeout,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "initial-startup"
        )
        #expect(await controller.startupHardRecoveryCount == 1)

        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, for: streamID)
        await controller.markFirstFramePresented()

        #expect(await controller.startupHardRecoveryCount == 0)
        #expect(await !(controller.hasTriggeredTerminalStartupFailure))

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Recovery requests are ignored after the controller stops")
    func recoveryRequestsAreIgnoredAfterStop() async {
        let controller = StreamController(streamID: 143, maxPayloadSize: 1200)

        await controller.stop()
        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "post-stop"
        )

        #expect(await !(controller.awaitingFirstPresentedFrame))
        #expect(await controller.firstPresentedFrameLastRecoveryRequestTime == 0)
    }

    @Test("Active tier updates do not re-arm first-frame awaiter while waiting")
    func activeTierUpdatesDoNotRearmFirstFrameAwaiterWhileWaiting() async {
        let clock = StreamControllerManualTimeProvider(start: 2000)
        let controller = StreamController(
            streamID: 141,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive)
        let initialWaitStart = await controller.firstPresentedFrameWaitStartTime
        #expect(initialWaitStart == 2000)

        clock.advance(by: 0.25)
        await controller.updatePresentationTier(.activeLive)
        let waitStartAfterRepeatUpdate = await controller.firstPresentedFrameWaitStartTime
        #expect(waitStartAfterRepeatUpdate == initialWaitStart)

        await controller.stop()
    }

    @Test("Frame-loss after first decode without starvation does not request keyframe")
    func frameLossAfterFirstDecodeWithoutStarvationDoesNotRequestKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 41, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal()
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Gap-related active-stream frame loss requests immediate keyframe")
    func gapRelatedFrameLossAfterFirstDecodeRequestsImmediateKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 1149, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal(reason: .severeForwardGap)
        try await streamControllerWaitUntil("gap-related keyframe request") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
    }

    @Test("Remote keyframe recovery defers duplicate requests during grace window")
    func remoteKeyframeRecoveryDefersDuplicateRequestsDuringGraceWindow() async throws {
        let clock = StreamControllerManualTimeProvider(start: 7000)
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(
            streamID: 151,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.setTransportPathKind(.vpn)
        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        #expect(await controller.requestKeyframeRecovery(reason: .frameLoss))
        #expect(keyframeCounter.value == 1)

        clock.advance(by: 3.0)
        #expect(!(await controller.requestKeyframeRecovery(reason: .frameLoss)))
        #expect(keyframeCounter.value == 1)

        clock.advance(by: StreamController.remoteDuplicateKeyframeRequestGrace + 0.1)
        #expect(await controller.requestKeyframeRecovery(reason: .frameLoss))
        #expect(keyframeCounter.value == 2)
        #expect(await controller.clientRecoveryStatus != .hardRecovery)

        await controller.stop()
    }

    @Test("Memory-budget frame loss requests one delayed keyframe after pressure settles")
    func memoryBudgetFrameLossRequestsDelayedKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 150
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal(reason: .memoryBudget)
        try await Task.sleep(for: .milliseconds(250))
        #expect(keyframeCounter.value == 0)

        try await streamControllerWaitUntil("memory-budget delayed keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Frame-loss after first decode while keyframe-starved defers immediate keyframe request")
    func frameLossAfterFirstDecodeWithStarvationDefersImmediateKeyframeRequest() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 42, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        await controller.handleFrameLossSignal()
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Frame-loss timeout requests keyframe after useful progress stalls")
    func frameLossTimeoutRequestsKeyframeAfterUsefulProgressStalls() async throws {
        let streamID: StreamID = 156
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 9000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
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
        await controller.markFirstFramePresented()

        clock.advance(by: StreamController.localHardRecoveryNoProgressFloor - 0.1)
        await controller.handleFrameLossSignal()
        #expect(keyframeCounter.value == 0)

        clock.advance(by: 0.2)
        await controller.handleFrameLossSignal()

        #expect(keyframeCounter.value == 1)
        let reassembler = await controller.reassembler
        #expect(reassembler.isAwaitingKeyframe)

        await controller.stop()
    }

    @Test("Present-stall while keyframe-starved does not burst keyframe requests")
    func presentStallWhileKeyframeStarvedDoesNotBurstKeyframeRequests() async throws {
        let streamID: StreamID = 5
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            },
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: nil
        )

        let pixelBuffer = makeStreamControllerPixelBuffer()
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: pixelBuffer,
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 10,
            presentationTime: .zero,
            for: streamID
        )

        await controller.recordDecodedFrame()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        try await Task.sleep(for: .seconds(11))
        #expect(keyframeCounter.value == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }
}
#endif
