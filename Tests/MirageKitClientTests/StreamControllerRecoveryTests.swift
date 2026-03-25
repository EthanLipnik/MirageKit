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
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Stream Controller Recovery", .serialized)
struct StreamControllerRecoveryTests {
    @Test("Freeze monitor uses tightened timeout and poll interval")
    func freezeMonitorUsesTightenedCadence() {
        #expect(StreamController.freezeTimeout == 1.25)
        #expect(StreamController.freezeCheckInterval == .milliseconds(250))
    }

    @Test("Post-resize decode admission stays keyframe-only until first frame")
    func postResizeDecodeAdmissionStaysKeyframeOnlyUntilFirstFrame() {
        let dropDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: true,
            isKeyframe: false
        )
        let acceptKeyframeDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: true,
            isKeyframe: true
        )
        let acceptNormalDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: false,
            isKeyframe: false
        )

        #expect(dropDecision == .dropNonKeyframeWhileAwaitingFirstFrame)
        #expect(acceptKeyframeDecision == .accept)
        #expect(acceptNormalDecision == .accept)
    }

    @Test("Local-resize decode admission drops while paused")
    func localResizeDecodeAdmissionDropsWhilePaused() {
        let dropDecision = StreamController.localResizeDecodeAdmissionDecision(
            decodePausedForLocalResize: true
        )
        let acceptDecision = StreamController.localResizeDecodeAdmissionDecision(
            decodePausedForLocalResize: false
        )

        #expect(dropDecision == .dropWhileLocalResizePaused)
        #expect(acceptDecision == .accept)
    }

    @Test("Decode failure telemetry waits for actionable recovery state")
    func decodeFailureTelemetryWaitsForActionableRecoveryState() {
        #expect(
            StreamController.shouldElevateDecodeFailure(
                consecutiveDecodeErrors: 3,
                signature: "MirageKit.MirageError:2",
                previousSignature: nil,
                lastLogTime: 0,
                now: 10,
                recoveryActionable: false
            ) == false
        )
        #expect(
            StreamController.shouldElevateDecodeFailure(
                consecutiveDecodeErrors: 3,
                signature: "MirageKit.MirageError:2",
                previousSignature: nil,
                lastLogTime: 0,
                now: 10,
                recoveryActionable: true
            )
        )
        #expect(
            StreamController.shouldElevateDecodeFailure(
                consecutiveDecodeErrors: 8,
                signature: "MirageKit.MirageError:2",
                previousSignature: "MirageKit.MirageError:2",
                lastLogTime: 8,
                now: 10,
                recoveryActionable: true
            ) == false
        )
    }

    @Test("Decode failure log message includes wrapped underlying error details")
    func decodeFailureLogMessageIncludesWrappedUnderlyingErrorDetails() {
        let underlyingError = NSError(
            domain: NSOSStatusErrorDomain,
            code: -12909,
            userInfo: [NSLocalizedDescriptionKey: "Decoder callback bad data"]
        )
        let error = MirageError.decodingError(underlyingError)

        let message = StreamController.decodeFailureLogMessage(for: error, attempt: 29)

        #expect(message.contains("Decode error (attempt 29)"))
        #expect(message.contains("error{type=MirageKit.MirageError"))
        #expect(message.contains("error.underlying{type="))
        #expect(message.contains("domain=\(NSOSStatusErrorDomain)"))
        #expect(message.contains("code=-12909"))
        #expect(message.contains("Decoder callback bad data"))
    }

    @Test("Suspend and resume local-resize decode toggles pause state")
    func suspendAndResumeLocalResizeDecodeTogglesPauseState() async {
        let controller = StreamController(streamID: 91, maxPayloadSize: 1200)

        await controller.suspendDecodeForLocalResize()
        #expect(await controller.decodePausedForLocalResize)

        await controller.resumeDecodeAfterLocalResize(requestRecoveryKeyframe: false)
        #expect(!(await controller.decodePausedForLocalResize))

        await controller.stop()
    }

    @Test("Passive tier keeps decode submission limit fixed at one")
    func passiveTierKeepsDecodeSubmissionLimitFixed() async {
        let controller = StreamController(streamID: 95, maxPayloadSize: 1200)

        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)
        await controller.updateDecodeSubmissionLimit(targetFrameRate: 60)
        await controller.evaluateDecodeSubmissionLimit(decodedFPS: 0, receivedFPS: 0)
        await controller.evaluateDecodeSubmissionLimit(decodedFPS: 120, receivedFPS: 120)

        #expect(await controller.decodeSubmissionBaselineLimit == 1)
        #expect(await controller.currentDecodeSubmissionLimit == 1)

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

    @Test("Passive to active promotion keeps P-frame-first when context is healthy")
    func passiveToActiveTierPromotionUsesPFrameFirstWhenContextHealthy() async throws {
        let keyframeCounter = LockedCounter()
        let streamID: StreamID = 92
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

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
        try await Task.sleep(for: .milliseconds(100))
        MirageFrameCache.shared.markPresented(sequence: 1, for: streamID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
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
        MirageFrameCache.shared.clear(for: streamID)

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
        MirageFrameCache.shared.clear(for: streamID)
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
            },
            onAdaptiveFallbackNeeded: nil
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
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Decode enqueue signals render listeners through stream store")
    func decodeEnqueueSignalsRenderListeners() {
        let streamID: StreamID = 50
        let owner = NSObject()
        let signalCounter = LockedCounter()

        MirageFrameCache.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: owner) {
            signalCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: owner)
            MirageFrameCache.shared.clear(for: streamID)
        }

        MirageFrameCache.shared.store(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        #expect(signalCounter.value == 1)
    }

    @Test("Overload signal triggers adaptive fallback after queue drops and recovery requests")
    func overloadTriggersAdaptiveFallback() async throws {
        let keyframeCounter = LockedCounter()
        let fallbackCounter = LockedCounter()
        let controller = StreamController(streamID: 1, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: nil,
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        for _ in 0 ..< 12 {
            await controller.recordQueueDrop()
        }
        await controller.requestKeyframeRecovery(reason: .manualRecovery)
        try await Task.sleep(for: .milliseconds(550))
        await controller.requestKeyframeRecovery(reason: .manualRecovery)
        try await Task.sleep(for: .milliseconds(100))

        #expect(keyframeCounter.value == 2)
        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Backpressure threshold does not request keyframe recovery")
    func backpressureDoesNotRequestKeyframes() async throws {
        let keyframeCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 1_000)
        let controller = StreamController(
            streamID: 2,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        // Additional drops inside cooldown should remain no-op.
        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        clock.advance(by: 1.1)
        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Decode threshold storms trigger adaptive fallback without queue-drop threshold")
    func decodeThresholdStormTriggersAdaptiveFallback() async throws {
        let fallbackCounter = LockedCounter()
        let controller = StreamController(streamID: 3, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: nil,
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        await controller.recordDecodeThresholdEvent()
        try await Task.sleep(for: .milliseconds(50))
        await controller.recordDecodeThresholdEvent()
        try await waitUntil("decode threshold fallback trigger", timeout: .seconds(5)) {
            fallbackCounter.value == 1
        }

        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Decode threshold recovery is deferred until sustained freeze")
    func decodeThresholdRecoveryIsDeferredUntilSustainedFreeze() async throws {
        let streamID: StreamID = 44
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleDecodeErrorThresholdSignal()
        await controller.handleDecodeErrorThresholdSignal()
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(250))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Decode threshold requests recovery after sustained freeze")
    func decodeThresholdRequestsRecoveryAfterSustainedFreeze() async throws {
        let streamID: StreamID = 144
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

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
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Decode threshold before first presented frame requests immediate startup recovery")
    func decodeThresholdBeforeFirstPresentedFrameRequestsImmediateStartupRecovery() async throws {
        let streamID: StreamID = 146
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

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
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Recovery dispatch helper enforces minimum intervals")
    func recoveryDispatchHelperEnforcesMinimumIntervals() {
        #expect(
            StreamController.shouldDispatchRecovery(
                lastDispatchTime: nil,
                now: 10,
                minimumInterval: 1
            )
        )
        #expect(
            !StreamController.shouldDispatchRecovery(
                lastDispatchTime: 10,
                now: 10.5,
                minimumInterval: 1
            )
        )
        #expect(
            StreamController.shouldDispatchRecovery(
                lastDispatchTime: 10,
                now: 11.1,
                minimumInterval: 1
            )
        )
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

    @Test("First-frame watchdog requests bootstrap recovery when startup stalls")
    func firstFrameWatchdogRequestsBootstrapRecoveryWhenStartupStalls() async throws {
        let clock = ManualTimeProvider(start: 1_000)
        let controller = StreamController(
            streamID: 140,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.armFirstPresentedFrameAwaiter(reason: "test-startup-stall")
        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace + 0.1)

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

        clock.advance(by: StreamController.firstPresentedFrameBootstrapRecoveryGrace + 0.1)

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

    @Test("Frame-loss after first decode without starvation does not request keyframe")
    func frameLossAfterFirstDecodeWithoutStarvationDoesNotRequestKeyframe() async throws {
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Frame-loss after first decode while keyframe-starved defers immediate keyframe request")
    func frameLossAfterFirstDecodeWithStarvationDefersImmediateKeyframeRequest() async throws {
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Freeze recovery distinguishes packet-starved, keyframe-starved, and monitoring-only stalls")
    func freezeRecoveryDecisionDistinguishesStallKinds() {
        #expect(
            StreamController.freezeRecoveryDecision(
                keyframeStarved: false,
                packetStarved: true,
                consecutiveFreezeRecoveries: 1
            ) == .soft(.packetStarved)
        )
        #expect(
            StreamController.freezeRecoveryDecision(
                keyframeStarved: true,
                packetStarved: false,
                consecutiveFreezeRecoveries: 1
            ) == .soft(.keyframeStarved)
        )
        #expect(
            StreamController.freezeRecoveryDecision(
                keyframeStarved: false,
                packetStarved: false,
                consecutiveFreezeRecoveries: 1
            ) == .monitor(.monitoringOnly)
        )
    }

    @Test("Present-stall while keyframe-starved escalates from soft request to hard recovery")
    func presentStallWhileKeyframeStarvedEscalatesRecovery() async throws {
        let streamID: StreamID = 5
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: nil,
            onAdaptiveFallbackNeeded: nil
        )

        let pixelBuffer = makePixelBuffer()
        MirageFrameCache.shared.enqueue(
            pixelBuffer,
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 10,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        await controller.recordDecodedFrame()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        try await Task.sleep(for: .seconds(11))
        #expect(keyframeCounter.value >= 2)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Packet-starved stalls escalate from bounded recovery to hard recovery")
    func packetStarvedFreezeRecoveryEscalatesAfterRepeatedStalls() {
        #expect(
            StreamController.freezeRecoveryDecision(
                keyframeStarved: false,
                packetStarved: true,
                consecutiveFreezeRecoveries: StreamController.freezeRecoveryEscalationThreshold
            ) == .hard(.packetStarved)
        )
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
