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
    @Test("Freeze monitor uses tightened timeout and poll interval")
    func freezeMonitorUsesTightenedCadence() {
        #expect(StreamController.freezeTimeout == 1.25)
        #expect(StreamController.freezeCheckInterval == .milliseconds(250))
    }

    @Test("Recovery-mode first-frame watchdog is tighter than startup")
    func recoveryModeFirstFrameWatchdogIsTighterThanStartup() {
        #expect(
            StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .recovery) <
                StreamController.firstPresentedFrameBootstrapRecoveryGrace(for: .startup)
        )
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

    @Test("Background decode failures suppress recovery until foreground")
    func backgroundDecodeFailuresSuppressRecoveryUntilForeground() {
        #expect(
            StreamController.shouldSuppressDecodeFailureRecovery(
                isApplicationForeground: false
            )
        )
        #expect(
            StreamController.shouldSuppressDecodeFailureRecovery(
                isApplicationForeground: true
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

    @Test("Severe forward gap emits dedicated diagnostic without changing timeout handling")
    func severeForwardGapEmitsDedicatedDiagnostic() {
        let message = StreamController.frameLossDiagnosticMessage(
            streamID: 97,
            reason: .severeForwardGap
        )

        #expect(message?.contains("short gap-recovery dip") == true)
        #expect(
            StreamController.frameLossDiagnosticMessage(
                streamID: 97,
                reason: .timeout
            ) == nil
        )
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
        try await Task.sleep(for: .milliseconds(100))
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, mappedPresentationTime: .zero, for: streamID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
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

    @Test("Stale post-resize soft recovery follow-up is ignored after a newer resize episode starts")
    func stalePostResizeSoftRecoveryFollowUpIsIgnored() {
        #expect(
            StreamController.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: 1,
                currentEpisodeID: 2,
                awaitingFirstFrameAfterResize: true
            )
        )
        #expect(
            StreamController.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: 1,
                currentEpisodeID: 1,
                awaitingFirstFrameAfterResize: false
            )
        )
        #expect(
            !StreamController.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: 1,
                currentEpisodeID: 1,
                awaitingFirstFrameAfterResize: true
            )
        )
        #expect(
            !StreamController.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: nil,
                currentEpisodeID: 3,
                awaitingFirstFrameAfterResize: false
            )
        )
    }

    @Test("Decode enqueue signals render listeners through stream store")
    func decodeEnqueueSignalsRenderListeners() {
        let streamID: StreamID = 50
        let owner = NSObject()
        let signalCounter = LockedCounter()

        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: owner) {
            signalCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: owner)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: .zero,
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
        MirageRenderStreamStore.shared.clear(for: streamID)

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
        MirageRenderStreamStore.shared.clear(for: streamID)
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
        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, mappedPresentationTime: .zero, for: streamID)
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

    @Test("Bootstrap first-frame recovery avoids keyframes when packet-starved")
    func bootstrapFirstFrameRecoveryAvoidsKeyframesWhenPacketStarved() {
        #expect(
            StreamController.bootstrapFirstFrameRecoveryAction(
                hasPackets: false,
                awaitingKeyframe: true,
                latestSequence: 1,
                baselineSequence: 1
            ) == .hardRecovery
        )
        #expect(
            StreamController.bootstrapFirstFrameRecoveryAction(
                hasPackets: true,
                awaitingKeyframe: true,
                latestSequence: 1,
                baselineSequence: 1
            ) == .requestKeyframe
        )
        #expect(
            StreamController.bootstrapFirstFrameRecoveryAction(
                hasPackets: true,
                awaitingKeyframe: false,
                latestSequence: 1,
                baselineSequence: 1
            ) == .hardRecovery
        )
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

        MirageRenderStreamStore.shared.markSubmitted(sequence: 1, mappedPresentationTime: .zero, for: streamID)
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
            onFirstFramePresented: nil,
            onAdaptiveFallbackNeeded: nil
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
