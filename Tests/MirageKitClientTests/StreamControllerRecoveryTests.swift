//
//  StreamControllerRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Decode overload and recovery behavior coverage for StreamController.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreMedia
import CoreVideo
import Foundation
import Testing

#if os(macOS)
private extension StreamController {
    func testSeedResizeRecoveryState(
        startupHardRecoveryCount: Int,
        hasTriggeredTerminalStartupFailure: Bool
    ) {
        self.startupHardRecoveryCount = startupHardRecoveryCount
        self.hasTriggeredTerminalStartupFailure = hasTriggeredTerminalStartupFailure
    }
}

@Suite("Stream Controller Recovery", .serialized)
struct StreamControllerRecoveryTests {
    @Test("Receiver media feedback can be suspended during background pause")
    func receiverMediaFeedbackCanBeSuspendedDuringBackgroundPause() async {
        let controller = StreamController(streamID: 89, maxPayloadSize: 1200)

        #expect(await controller.mediaFeedbackSuspended == false)
        await controller.setMediaFeedbackSuspended(true)
        #expect(await controller.mediaFeedbackSuspended)
        await controller.setMediaFeedbackSuspended(false)
        #expect(await controller.mediaFeedbackSuspended == false)
        await controller.stop()
    }

    @Test("Post-resize first-frame watchdog arms in recovery mode")
    func postResizeFirstFrameWatchdogArmsInRecoveryMode() async {
        let controller = StreamController(streamID: 90, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()

        #expect(await controller.awaitingFirstFrameAfterResize)
        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(await controller.firstPresentedFrameAwaitMode == .recovery)

        await controller.stop()
    }

    @Test("Prepare-for-resize preserves presentation tier and clears post-resize gating")
    func prepareForResizePreservesPresentationTierAndClearsPostResizeGating() async {
        let controller = StreamController(streamID: 91, maxPayloadSize: 1200)

        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        await controller.beginPostResizeTransition()
        await controller.prepareForResize(
            codec: .hevc,
            streamDimensions: (width: 1920, height: 1080)
        )

        #expect(await controller.presentationTier == .passiveSnapshot)
        #expect(!(await controller.awaitingFirstFrameAfterResize))
        #expect(!(await controller.awaitingFirstPresentedFrame))
        #expect(await controller.hasPresentedFirstFrame == false)

        await controller.stop()
    }

    @Test("Prepare-for-resize invalidates pending render frames")
    func prepareForResizeInvalidatesPendingRenderFrames() async {
        let streamID: StreamID = 92
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)
        let initialGeneration = MirageRenderStreamStore.shared.currentGeneration(for: streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)

        await controller.prepareForResize(
            codec: .hevc,
            streamDimensions: (width: 1920, height: 1080)
        )

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)
        #expect(MirageRenderStreamStore.shared.currentGeneration(for: streamID) > initialGeneration)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Prepare-for-resize preserves recovery counters")
    func prepareForResizePreservesRecoveryCounters() async {
        let controller = StreamController(streamID: 93, maxPayloadSize: 1200)

        await controller.testSeedResizeRecoveryState(
            startupHardRecoveryCount: 3,
            hasTriggeredTerminalStartupFailure: true
        )
        await controller.prepareForResize(
            codec: .hevc,
            streamDimensions: (width: 2560, height: 1440)
        )

        #expect(await controller.startupHardRecoveryCount == 3)
        #expect(await controller.hasTriggeredTerminalStartupFailure)

        await controller.stop()
    }

    @Test("Active presentation tier never inherits passive one FPS target")
    func activePresentationTierNeverInheritsPassiveOneFPSTarget() async {
        let controller = StreamController(streamID: 94, maxPayloadSize: 1200)

        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)
        #expect(await controller.decodeSchedulerTargetFPS == 1)

        await controller.updatePresentationTier(.activeLive, targetFPS: 1)
        #expect(await controller.decodeSchedulerTargetFPS >= 20)

        await controller.stop()
    }

    @Test("Incoming resize priming fences packets before the full reset")
    func incomingResizePrimingFencesPacketsBeforeReset() async {
        let controller = StreamController(streamID: 94, maxPayloadSize: 1200)

        await controller.primeForIncomingResize(
            dimensionToken: 42,
            streamDimensions: (width: 1920, height: 1080)
        )

        let reassembler = await controller.getReassembler()
        #expect(reassembler.isAwaitingKeyframe())
        #expect(await controller.decoder.awaitingDimensionChange)
        #expect(await controller.decoder.expectedDimensions?.width == 1920)
        #expect(await controller.decoder.expectedDimensions?.height == 1080)

        await controller.stop()
    }

    @Test("Passive tier frame loss enters keyframe-only mode without requesting keyframe")
    func passiveTierFrameLossEntersKeyframeOnlyMode() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 96
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)
        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal()
        try await Task.sleep(for: .seconds(2))

        // Passive streams enter keyframe-only mode and wait for the next
        // natural keyframe rather than requesting one explicitly.
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Passive to active promotion forces keyframe recovery when keyframe-starved")
    func passiveToActiveTierPromotionForcesKeyframeWhenStarved() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 93
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()
        #expect(reassembler.isAwaitingKeyframe())

        await controller.updatePresentationTier(.passiveSnapshot)
        await controller.updatePresentationTier(.activeLive)
        try await waitUntil("tier promotion keyframe request (awaiting keyframe)") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
    }

    @Test("Tier-promotion probe requests single fallback keyframe without presentation progress")
    func tierPromotionProbeRequestsFallbackKeyframeWithoutProgress() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 94
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        primeKeyframeAnchor(for: reassembler, streamID: streamID)
        #expect(reassembler.hasKeyframeAnchor())
        #expect(!reassembler.isAwaitingKeyframe())

        await controller.updatePresentationTier(.passiveSnapshot)
        await controller.updatePresentationTier(.activeLive)
        try await waitUntil("tier promotion probe fallback keyframe", timeout: .seconds(6)) {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Reset re-arms first-frame callback for post-resize transitions")
    func resetRearmsFirstFrameCallbackForPostResizeTransition() async throws {
        let firstFrameCounter = LockedCounter()
        let controller = StreamController(streamID: 90, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: {
                firstFrameCounter.increment()
            }
        )

        await controller.markFirstFramePresented()
        try await waitUntil("initial first-frame callback") {
            firstFrameCounter.value == 1
        }
        #expect(await controller.hasPresentedFirstFrame)

        await controller.resetForNewSession()
        #expect(!(await controller.hasPresentedFirstFrame))
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        try await waitUntil("post-resize first-frame callback") {
            firstFrameCounter.value == 2
        }

        #expect(await controller.hasPresentedFirstFrame)
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.handleDecoderRecoverySignal()
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize transition stays armed until decoder recovery completes")
    func postResizeTransitionStaysArmedUntilDecoderRecoveryCompletes() async {
        let controller = StreamController(streamID: 190, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFrameDecoded()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.handleDecoderRecoverySignal()
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize decoder recovery signal does not clear recovery before presentation")
    func postResizeDecoderRecoverySignalDoesNotClearRecoveryBeforePresentation() async {
        let controller = StreamController(streamID: 191, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        await controller.handleDecoderRecoverySignal()

        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("New resize re-arms post-resize presentation gating while recovery is still active")
    func newResizeRearmsPostResizePresentationGating() async {
        let controller = StreamController(streamID: 192, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        await controller.markFirstFramePresented()

        #expect(!(await controller.awaitingFirstPresentedFrameAfterResize))
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.beginPostResizeTransition()

        #expect(await controller.awaitingFirstPresentedFrameAfterResize)
        #expect(await controller.awaitingFirstFrameAfterResize)
        #expect(await controller.postResizeDecodeRecoverySuccessCount == 0)

        await controller.stop()
    }

    @Test("Backpressure threshold keeps keyframe during freshness catch-up without recovery")
    func backpressureKeepsKeyframeDuringFreshnessCatchUpWithoutRecovery() async throws {
        let keyframeCounter = LockedCounter()
        let renderCapacityStallCounter = LockedCounter()
        let releasedFrameCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 1_000)
        let streamID: StreamID = 2
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onStallEvent: { event in
                if event == .clientRenderCapacity {
                    renderCapacityStallCounter.increment()
                }
            }
        )

        await controller.updatePresentationTier(.activeLive, targetFPS: 120)
        await controller.markFirstFramePresented()
        clock.advance(by: StreamController.startupBurstRecoveryEscalationHoldoff + 0.1)
        let reassembler = await controller.getReassembler()
        primeKeyframeAnchor(for: reassembler, streamID: streamID)
        #expect(!reassembler.isAwaitingKeyframe())

        for frameNumber in UInt32(1) ... UInt32(StreamController.decodeQueueRecoveryThreshold) {
            await controller.enqueueFrameForRecoveryTesting(
                frameNumber: frameNumber,
                releaseBuffer: {
                    releasedFrameCounter.increment()
                }
            )
        }

        let filledQueue = await controller.queuedFrameSnapshotForTesting()
        #expect(filledQueue.count == StreamController.decodeQueueRecoveryThreshold)

        await controller.enqueueFrameForRecoveryTesting(
            frameNumber: 99,
            isKeyframe: true,
            releaseBuffer: {
                releasedFrameCounter.increment()
            }
        )

        try await Task.sleep(for: .milliseconds(150))

        let caughtUpQueue = await controller.queuedFrameSnapshotForTesting()
        #expect(caughtUpQueue.count == 1)
        #expect(caughtUpQueue.firstFrameNumber == UInt32(99))
        #expect(caughtUpQueue.lastFrameNumber == UInt32(99))
        #expect(releasedFrameCounter.value == StreamController.decodeQueueRecoveryThreshold)
        #expect(keyframeCounter.value == 0)
        #expect(renderCapacityStallCounter.value == 0)
        #expect(!reassembler.isAwaitingKeyframe())
        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
    }

    @Test("Backpressure threshold drops dependent frame and requests keyframe recovery")
    func backpressureDropsDependentFrameAndRequestsKeyframeRecovery() async throws {
        let keyframeCounter = LockedCounter()
        let releasedFrameCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 2_000)
        let streamID: StreamID = 3
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.activeLive, targetFPS: 120)
        await controller.markFirstFramePresented()
        clock.advance(by: StreamController.startupBurstRecoveryEscalationHoldoff + 0.1)
        let reassembler = await controller.getReassembler()
        primeKeyframeAnchor(for: reassembler, streamID: streamID)
        #expect(!reassembler.isAwaitingKeyframe())

        for frameNumber in UInt32(1) ... UInt32(StreamController.decodeQueueRecoveryThreshold) {
            await controller.enqueueFrameForRecoveryTesting(
                frameNumber: frameNumber,
                releaseBuffer: {
                    releasedFrameCounter.increment()
                }
            )
        }

        let filledQueue = await controller.queuedFrameSnapshotForTesting()
        #expect(filledQueue.count == StreamController.decodeQueueRecoveryThreshold)

        await controller.enqueueFrameForRecoveryTesting(
            frameNumber: 99,
            releaseBuffer: {
                releasedFrameCounter.increment()
            }
        )

        try await waitUntil("backpressure dependent-frame keyframe request") {
            keyframeCounter.value == 1
        }

        let caughtUpQueue = await controller.queuedFrameSnapshotForTesting()
        #expect(caughtUpQueue.count == 0)
        #expect(releasedFrameCounter.value == StreamController.decodeQueueRecoveryThreshold + 1)
        #expect(keyframeCounter.value == 1)
        #expect(reassembler.isAwaitingKeyframe())
        #expect(await controller.clientRecoveryStatus == .keyframeRecovery)

        await controller.stop()
    }

    @Test("Decode threshold requests immediate keyframe")
    func decodeThresholdRequestsImmediateKeyframe() async throws {
        let streamID: StreamID = 44
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("decode-threshold immediate keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Smoothest startup burst uses expanded decode queue headroom")
    func smoothestStartupBurstUsesExpandedDecodeQueueHeadroom() async {
        let clock = ManualTimeProvider(start: 7_000)
        let controller = StreamController(
            streamID: 248,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive, targetFPS: 120)
        await controller.updateCadenceTarget(
            sourceFPS: 120,
            displayFPS: 120,
            latencyMode: .smoothest,
            reason: "test smoothest startup"
        )

        let limits = await controller.decodeQueueAdmissionLimits(now: clock.now)
        #expect(limits.recoveryThreshold == StreamController.smoothestStartupBurstDecodeQueueRecoveryThreshold)
        #expect(limits.hardLimit == StreamController.smoothestStartupBurstMaxQueuedFrames)

        await controller.stop()
    }

    @Test("Recovery stabilization keeps extra decode queue headroom after keyframe decode")
    func recoveryStabilizationKeepsExtraDecodeQueueHeadroom() async {
        let clock = ManualTimeProvider(start: 8_000)
        let controller = StreamController(
            streamID: 249,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive, targetFPS: 120)
        await controller.updateCadenceTarget(
            sourceFPS: 120,
            displayFPS: 120,
            latencyMode: .smoothest,
            reason: "test smoothest recovery"
        )
        await controller.markFirstFramePresented()
        clock.advance(by: StreamController.startupBurstRecoveryEscalationHoldoff + 0.1)
        await controller.setClientRecoveryStatus(.keyframeRecovery)

        let limits = await controller.decodeQueueAdmissionLimits(now: clock.now)
        #expect(limits.recoveryThreshold == StreamController.smoothestRecoveryStabilizationDecodeQueueRecoveryThreshold)
        #expect(limits.hardLimit == StreamController.smoothestRecoveryStabilizationMaxQueuedFrames)

        await controller.stop()
    }

    @Test("Decode threshold requests recovery after sustained freeze")
    func decodeThresholdRequestsRecoveryAfterSustainedFreeze() async throws {
        let streamID: StreamID = 144
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        primeKeyframeAnchor(for: reassembler, streamID: streamID)
        await controller.forcePresentationStallForTesting()

        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("decode-threshold keyframe request after freeze") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Decode threshold before first presented frame requests immediate startup recovery")
    func decodeThresholdBeforeFirstPresentedFrameRequestsImmediateStartupRecovery() async throws {
        let streamID: StreamID = 146
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )
        await controller.updatePresentationTier(.activeLive)

        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("startup decode-threshold recovery request") {
            keyframeCounter.value == 1
        }

        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(await controller.firstPresentedFrameWaitStartTime > 0)
        #expect(!(await controller.hasDecodedFirstFrame))
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Decode threshold while awaiting recovered presentation requests immediate keyframe")
    func decodeThresholdWhileAwaitingRecoveredPresentationRequestsImmediateKeyframe() async throws {
        let streamID: StreamID = 247
        let keyframeCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 4_000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .frameLoss,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )
        let baselineRequests = keyframeCounter.value
        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(baselineRequests >= 1)

        clock.advance(by: StreamController.recoveryRequestDispatchCooldown + 0.01)
        await controller.handleDecodeErrorThresholdSignal()

        try await waitUntil("decode-threshold keyframe while awaiting recovered presentation") {
            keyframeCounter.value > baselineRequests
        }
        #expect(await controller.awaitingFirstPresentedFrame)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Post-resize decode threshold waits through grace window before recovery")
    func postResizeDecodeThresholdWaitsThroughGraceWindowBeforeRecovery() async throws {
        let streamID: StreamID = 246
        let keyframeCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 2_000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.beginPostResizeTransition()

        clock.advance(by: 0.1)
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(keyframeCounter.value == 0)

        clock.advance(by: 1.3)
        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("post-resize decode-threshold recovery after grace") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Soft recovery cadence suppresses duplicate threshold recoveries within cooldown")
    func softRecoveryCadenceSuppressesDuplicateThresholdRecoveries() async throws {
        let keyframeCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 500)
        let controller = StreamController(
            streamID: 145,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )
        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)

        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("first decode-threshold keyframe request") {
            keyframeCounter.value == 1
        }

        clock.advance(by: 0.6)
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(keyframeCounter.value == 1)

        clock.advance(by: 0.5)
        await controller.handleDecodeErrorThresholdSignal()
        try await waitUntil("second decode-threshold keyframe request") {
            keyframeCounter.value >= 2
        }
        #expect(keyframeCounter.value >= 2)

        await controller.stop()
    }

    @Test("Frame-loss bootstrap requests keyframe before first decoded frame")
    func frameLossBootstrapRequestsKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 40, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.handleFrameLossSignal()
        try await waitUntil("bootstrap keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Freeze monitor requests recovery after real presentation progress stalls")
    func freezeMonitorRequestsRecoveryAfterPresentationStall() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 148
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        #expect(await controller.lastPresentedProgressTime > 0)

        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        try await waitUntil("freeze monitor keyframe request", timeout: .seconds(3)) {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Freeze monitor requests presenter recovery when render submission stalls with pending frames")
    func freezeMonitorRequestsPresenterRecoveryForRenderSubmissionStall() async throws {
        let keyframeCounter = LockedCounter()
        let presenterRecoveryCounter = LockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 149
        let clock = ManualTimeProvider(start: 8_000)
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
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        let submittedFrame = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: submittedFrame.cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )
        await controller.markFirstFramePresented()
        await controller.forcePresentationStallForTesting(now: clock.now)

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        try await waitUntil("render-submission presenter recovery", timeout: .seconds(3)) {
            presenterRecoveryCounter.value >= 1
        }
        #expect(keyframeCounter.value == 0)
        let reassembler = await controller.getReassembler()
        #expect(!reassembler.isAwaitingKeyframe())

        await controller.stop()
    }

    @Test("Freeze monitor does not treat retained submitted frame as presenter work")
    func freezeMonitorIgnoresRetainedSubmittedFrameForPresenterRecovery() async throws {
        let keyframeCounter = LockedCounter()
        let presenterRecoveryCounter = LockedCounter()
        let presenterOwner = NSObject()
        let streamID: StreamID = 150
        let clock = ManualTimeProvider(start: 8_500)
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
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.recordDecodedFrame()
        let submittedFrame = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: submittedFrame.cursor,
            mappedPresentationTime: .zero,
            for: streamID
        )
        await controller.markFirstFramePresented()
        await controller.forcePresentationStallForTesting(now: clock.now)

        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        try await waitUntil("stale retained frame keyframe recovery", timeout: .seconds(3)) {
            keyframeCounter.value >= 1
        }
        #expect(presenterRecoveryCounter.value == 0)

        await controller.stop()
    }

    @Test("First-frame watchdog uses hard recovery when startup is packet-starved")
    func firstFrameWatchdogUsesHardRecoveryWhenStartupIsPacketStarved() async throws {
        let clock = ManualTimeProvider(start: 1_000)
        let controller = StreamController(
            streamID: 140,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-stall")
        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .startup) + 0.1)

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

    @Test("Startup watchdog requests presenter recovery before keyframe recovery when decoded frame is pending")
    func startupWatchdogRequestsPresenterRecoveryBeforeKeyframeRecovery() async throws {
        let streamID: StreamID = 147
        let clock = ManualTimeProvider(start: 6_000)
        let keyframeCounter = LockedCounter()
        let presenterRecoveryCounter = LockedCounter()
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
            },
            onResizeEvent: nil
        )
        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-presentation")
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
            for: streamID
        )

        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .startup) + 0.1)
        try await waitUntil("startup presenter recovery request") {
            presenterRecoveryCounter.value == 1
        }

        #expect(keyframeCounter.value == 0)
        #expect(await controller.firstPresentedFrameRendererRecoveryAttemptCount == 1)
        #expect(await controller.lastHardRecoveryStartTime == 0)

        await controller.stop()
    }

    @Test("Manual recovery re-arms first-frame watchdog after prior presentation")
    func manualRecoveryRearmsFirstFrameWatchdogAfterPriorPresentation() async throws {
        let clock = ManualTimeProvider(start: 3_000)
        let controller = StreamController(
            streamID: 142,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()
        #expect(await controller.hasPresentedFirstFrame)
        #expect(!(await controller.awaitingFirstPresentedFrame))

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
        let clock = ManualTimeProvider(start: 7_000)
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

        markSubmitted(streamID: streamID)
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
        let keyframeCounter = LockedCounter()
        let thresholdCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 7_500)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
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

        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 1)
        let recoveredProgress = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        #expect(recoveredProgress)
        await controller.clearTransientRecoveryStateAfterPresentationProgress()
        #expect(await controller.clientRecoveryStatus == .hardRecovery)

        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 2)
        _ = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 3)
        _ = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
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

    @Test("Freeze monitor pauses while hard recovery waits for recovered frame")
    func freezeMonitorPausesWhileHardRecoveryWaitsForRecoveredFrame() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 153
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )
        await controller.updatePresentationTier(.activeLive)
        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )
        try await waitUntil("initial hard-recovery keyframe request") {
            keyframeCounter.value == 1
        }

        await controller.forcePresentationStallForTesting()
        try await Task.sleep(for: .milliseconds(700))

        #expect(keyframeCounter.value == 1)
        #expect(await controller.clientRecoveryStatus == .hardRecovery)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Startup hard recovery budget escalates to terminal failure")
    func startupHardRecoveryBudgetEscalatesToTerminalFailure() async throws {
        let clock = ManualTimeProvider(start: 4_000)
        let failures = LockedTerminalStartupFailure()
        let controller = StreamController(
            streamID: 144,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeEvent: nil,
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

        try await waitUntil("terminal startup failure callback") {
            failures.value != nil
        }

        let failure = try #require(failures.value)
        #expect(failure.reason == .startupKeyframeTimeout)
        #expect(failure.hardRecoveryAttempts == StreamController.startupHardRecoveryLimit)
        #expect(failure.waitReason == "initial-startup")

        await controller.stop()
    }

    @Test("Activation recovery requires stable decoded and presented frames before clearing")
    func activationRecoveryRequiresStableDecodedAndPresentedFramesBeforeClearing() async throws {
        let streamID: StreamID = 166
        let clock = ManualTimeProvider(start: 6_000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.updatePresentationTier(.activeLive)
        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "application-activation-recovery"
        )

        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 1)
        _ = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        await controller.clearTransientRecoveryStateAfterPresentationProgress()
        #expect(await controller.clientRecoveryStatus == .hardRecovery)

        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 2)
        _ = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        await controller.recordDecodedFrame()
        markSubmitted(streamID: streamID, sequence: 3)
        _ = await controller.syncPresentationProgressFromFrameStore(now: clock.now)
        await controller.clearTransientRecoveryStateAfterPresentationProgress()

        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Repeated established hard recovery holds topology and requests a keyframe")
    func repeatedEstablishedHardRecoveryHoldsTopologyAndRequestsKeyframe() async throws {
        let streamID: StreamID = 167
        let clock = ManualTimeProvider(start: 7_000)
        let failures = LockedTerminalLiveRecoveryFailure()
        let keyframes = LockedCounter()
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframes.increment()
            },
            onResizeEvent: nil,
            onTerminalLiveRecoveryFailure: { failure in
                failures.record(failure)
            }
        )
        await controller.updatePresentationTier(.activeLive)
        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .manualRecovery,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "application-activation-recovery"
        )
        markSubmitted(streamID: streamID, sequence: 2)
        await controller.markFirstFramePresented()

        clock.advance(by: StreamController.hardRecoveryMinimumInterval + 0.1)
        await controller.requestRecovery(
            reason: .decodeErrorThreshold,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "decode-error-hard-reset"
        )

        try await waitUntil("topology-held recovery keyframe") {
            keyframes.value > 0
        }

        #expect(failures.value == nil)
        #expect(!(await controller.hasTriggeredTerminalLiveRecoveryFailure))

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Partial keyframe recovery progress continues soft recovery instead of hard reset")
    func partialKeyframeRecoveryProgressContinuesSoftInsteadOfHardReset() async throws {
        let streamID: StreamID = 169
        let clock = ManualTimeProvider(start: 8_000)
        let keyframes = LockedCounter()
        let presentationRecoveryStalls = LockedCounter()
        let failures = LockedTerminalLiveRecoveryFailure()
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframes.increment()
            },
            onResizeEvent: nil,
            onStallEvent: { event in
                if event == .presentationRecovery {
                    presentationRecoveryStalls.increment()
                }
            },
            onTerminalLiveRecoveryFailure: { failure in
                failures.record(failure)
            }
        )
        await controller.updatePresentationTier(.activeLive)
        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        await controller.setClientRecoveryStatus(.keyframeRecovery)
        await controller.armRecoveryStabilizationTracking(
            baseline: MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).visibleCursor
        )
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()
        await controller.recordDecodedFrame()

        let didContinueSoftRecovery = await controller.continueSoftRecoveryAfterPartialProgress(elapsedMs: 1_500)

        #expect(didContinueSoftRecovery)
        #expect(await controller.lastHardRecoveryStartTime == 0)
        #expect(await controller.clientRecoveryStatus == .keyframeRecovery)
        #expect(keyframes.value == 1)
        #expect(presentationRecoveryStalls.value == 1)
        #expect(failures.value == nil)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("First-frame presentation clears startup hard recovery budget")
    func firstFramePresentationClearsStartupHardRecoveryBudget() async {
        let clock = ManualTimeProvider(start: 5_000)
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

        markSubmitted(streamID: streamID)
        await controller.markFirstFramePresented()

        #expect(await controller.startupHardRecoveryCount == 0)
        #expect(!(await controller.hasTriggeredTerminalStartupFailure))

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

        #expect(!(await controller.awaitingFirstPresentedFrame))
        #expect(await controller.firstPresentedFrameLastRecoveryRequestTime == 0)
    }

    @Test("Active tier updates do not re-arm first-frame awaiter while waiting")
    func activeTierUpdatesDoNotRearmFirstFrameAwaiterWhileWaiting() async {
        let clock = ManualTimeProvider(start: 2_000)
        let controller = StreamController(
            streamID: 141,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.updatePresentationTier(.activeLive)
        let initialWaitStart = await controller.firstPresentedFrameWaitStartTime
        #expect(initialWaitStart == 2_000)

        clock.advance(by: 0.25)
        await controller.updatePresentationTier(.activeLive)
        let waitStartAfterRepeatUpdate = await controller.firstPresentedFrameWaitStartTime
        #expect(waitStartAfterRepeatUpdate == initialWaitStart)

        await controller.stop()
    }

    @Test("Dependency frame loss after first decode enters keyframe repair")
    func dependencyFrameLossAfterFirstDecodeEntersKeyframeRepair() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 41, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal()
        try await waitUntil("frame-loss keyframe request") {
            keyframeCounter.value == 1
        }
        let reassembler = await controller.getReassembler()
        #expect(reassembler.isAwaitingKeyframe())
        #expect(keyframeCounter.value == 1)
        #expect(await controller.clientRecoveryStatus == .keyframeRecovery)

        await controller.stop()
    }

    @Test("Gap-related active-stream frame loss requests immediate keyframe")
    func gapRelatedFrameLossAfterFirstDecodeRequestsImmediateKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 149, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal(reason: .severeForwardGap)
        try await waitUntil("gap-related keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Startup keyframe recovery loop holds topology while keyframes never arrive")
    func startupKeyframeRecoveryLoopHoldsTopologyWhenKeyframesNeverArrive() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 151, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        await controller.startKeyframeRecoveryLoopIfNeeded()
        await controller.requestKeyframeRecovery(reason: .frameLoss)

        try await Task.sleep(for: .seconds(1))

        #expect(keyframeCounter.value >= 1)
        #expect(await controller.lastHardRecoveryStartTime == 0)
        #expect(await controller.clientRecoveryStatus == .keyframeRecovery)

        await controller.stop()
    }

    @Test("Memory-budget frame loss requests one delayed keyframe after pressure settles")
    func memoryBudgetFrameLossRequestsDelayedKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 150
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal(reason: .memoryBudget)
        try await Task.sleep(for: .milliseconds(250))
        #expect(keyframeCounter.value == 0)

        try await waitUntil("memory-budget delayed keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Frame-loss while keyframe-starved requests one recovery keyframe")
    func frameLossWhileKeyframeStarvedRequestsOneRecoveryKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 42, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        await controller.handleFrameLossSignal()
        try await waitUntil("starved frame-loss keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(reassembler.isAwaitingKeyframe())
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Present-stall while keyframe-starved does not burst keyframe requests")
    func presentStallWhileKeyframeStarvedDoesNotBurstKeyframeRequests() async throws {
        let streamID: StreamID = 5
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: nil
        )

        let pixelBuffer = makePixelBuffer()
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: pixelBuffer,
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 10,
            presentationTime: .zero,
            for: streamID
        )

        await controller.recordDecodedFrame()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        try await Task.sleep(for: .seconds(11))
        #expect(keyframeCounter.value == 1)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 0)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    private func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(20),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: pollInterval)
        }
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
            Issue.record("Failed to create CVPixelBuffer")
            fatalError("Failed to create CVPixelBuffer")
        }
        return buffer
    }

    private func primeKeyframeAnchor(
        for reassembler: FrameReassembler,
        streamID: StreamID,
        frameNumber: UInt32 = 1
    ) {
        let keyframePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        reassembler.processPacket(
            keyframePayload,
            header: makeVideoHeader(
                streamID: streamID,
                flags: [.keyframe, .endOfFrame],
                frameNumber: frameNumber,
                payload: keyframePayload
            )
        )
    }

    private func makeVideoHeader(
        streamID: StreamID,
        flags: FrameFlags,
        frameNumber: UInt32,
        payload: Data
    ) -> FrameHeader {
        FrameHeader(
            flags: flags,
            streamID: streamID,
            sequenceNumber: frameNumber,
            timestamp: UInt64(frameNumber),
            frameNumber: frameNumber,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count),
            checksum: crc32(payload),
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            dimensionToken: 0,
            epoch: 0
        )
    }

    private func crc32(_ data: Data) -> UInt32 {
        let polynomial: UInt32 = 0xEDB88320
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0 ..< 8 {
                if (current & 1) == 1 {
                    current = (current >> 1) ^ polynomial
                } else {
                    current >>= 1
                }
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xFFFFFFFF
    }

    private func markSubmitted(streamID: StreamID, sequence: UInt64 = 1) {
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: MirageRenderCursor(
                generation: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
                sequence: sequence
            ),
            mappedPresentationTime: .zero,
            for: streamID
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockedTerminalStartupFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: StreamController.TerminalStartupFailure?

    var value: StreamController.TerminalStartupFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ failure: StreamController.TerminalStartupFailure) {
        lock.lock()
        storage = failure
        lock.unlock()
    }
}

private final class LockedTerminalLiveRecoveryFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: StreamController.TerminalLiveRecoveryFailure?

    var value: StreamController.TerminalLiveRecoveryFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ failure: StreamController.TerminalLiveRecoveryFailure) {
        lock.lock()
        storage = failure
        lock.unlock()
    }
}

private final class ManualTimeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CFAbsoluteTime

    init(start: CFAbsoluteTime) {
        value = start
    }

    var now: CFAbsoluteTime {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: CFAbsoluteTime) {
        lock.lock()
        value += delta
        lock.unlock()
    }
}
#endif
