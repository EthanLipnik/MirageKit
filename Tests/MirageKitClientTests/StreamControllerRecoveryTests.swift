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
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
import MirageCore
import MirageMedia
import MirageWire

#if os(macOS)
private extension StreamController {
    func testSeedResizeRecoveryState(
        startupHardRecoveryCount: Int,
        hasTriggeredTerminalStartupFailure: Bool
    ) {
        self.startupHardRecoveryCount = startupHardRecoveryCount
        self.hasTriggeredTerminalStartupFailure = hasTriggeredTerminalStartupFailure
    }

    func testSeedLastRecoveryRequestDispatchTime(_ time: CFAbsoluteTime) {
        lastRecoveryRequestDispatchTime = time
    }

    func testSeedRecoveryKeyframeDispatchTimes(_ times: [CFAbsoluteTime]) {
        recoveryKeyframeDispatchTimes = times
    }

    func testSeedClientRecoveryStatus(_ status: MirageStreamClientRecoveryStatus) {
        clientRecoveryStatus = status
    }

    func testSeedRecoveryProgress(
        decodedAt: CFAbsoluteTime = 0,
        presentedAt: CFAbsoluteTime = 0
    ) {
        lastDecodedProgressTime = decodedAt
        lastPresentedProgressTime = presentedAt
    }
}

@Suite("Stream Controller Recovery", .serialized)
struct StreamControllerRecoveryTests {
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
        #expect(await !(controller.awaitingFirstFrameAfterResize))
        #expect(await !(controller.awaitingFirstPresentedFrame))
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

        let reassembler = await controller.reassembler
        #expect(reassembler.isAwaitingKeyframe)
        #expect(await controller.decoder.awaitingDimensionChange)
        #expect(await controller.decoder.expectedDimensions?.width == 1920)
        #expect(await controller.decoder.expectedDimensions?.height == 1080)

        await controller.stop()
    }

    @Test("Passive tier frame loss waits for natural keyframe or decode error")
    func passiveTierFrameLossWaitsForNaturalKeyframeOrDecodeError() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 96
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.updatePresentationTier(.passiveSnapshot, targetFPS: 1)
        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal()
        try await Task.sleep(for: .milliseconds(300))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Passive to active promotion forces keyframe recovery when keyframe-starved")
    func passiveToActiveTierPromotionForcesKeyframeWhenStarved() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 93
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()
        #expect(reassembler.isAwaitingKeyframe)

        await controller.updatePresentationTier(.passiveSnapshot)
        await controller.updatePresentationTier(.activeLive)
        try await streamControllerWaitUntil("tier promotion keyframe request (awaiting keyframe)") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
    }

    @Test("Pending keyframe progress suppresses duplicate decode recovery requests")
    func pendingKeyframeProgressSuppressesDuplicateDecodeRecoveryRequests() async {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 97
        let controller = StreamController(streamID: streamID, maxPayloadSize: 4)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        let reassembler = await controller.reassembler
        let keyframeFragment = Data([0x00, 0x00, 0x00, 0x2A])
        reassembler.processPacket(
            keyframeFragment,
            header: makeHeader(
                flags: [.keyframe],
                frameNumber: 42,
                payload: keyframeFragment,
                fragmentIndex: 0,
                fragmentCount: 8,
                frameByteCount: 32
            )
        )

        let didDispatch = await controller.requestKeyframeRecovery(reason: .decodeErrorThreshold)

        #expect(didDispatch == false)
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Fresh non-keyframe traffic does not suppress recovery while awaiting keyframe")
    func freshNonKeyframeTrafficDoesNotSuppressAwaitingKeyframeRecovery() async {
        let clock = StreamControllerManualTimeProvider(start: 1000)
        let cases: [(MirageCore.MirageNetworkPathKind, MirageMedia.MirageMediaPathProfile)] = [
            (.awdl, .awdlRadio),
            (.wifi, .localWiFi),
            (.vpn, .vpnOrOverlay)
        ]

        for (index, testCase) in cases.enumerated() {
            let controller = StreamController(
                streamID: StreamID(98 + index),
                maxPayloadSize: 1200,
                nowProvider: { clock.now }
            )

            await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - 10)
            let snapshot = FrameReassembler.KeyframeWaitSnapshot(
                isAwaitingKeyframe: true,
                awaitingSince: clock.now - 1,
                latestPacketReceivedTime: clock.now - 0.05,
                latestPendingKeyframeProgress: nil,
                transportPathKind: testCase.0,
                mediaPathProfile: testCase.1,
                pendingFrameCount: 4,
                pendingKeyframeCount: 0,
                incompleteFrameTimeouts: 0,
                incompleteFrameNoProgressTimeouts: 0,
                incompleteFrameLifetimeTimeouts: 0,
                forwardGapTimeouts: 0
            )

            let decision = await controller.keyframeRequestDecision(
                now: clock.now,
                reason: .frameLoss,
                snapshot: snapshot
            )

            #expect(decision == .requestKeyframe)

            await controller.stop()
        }
    }

    @Test("Recovery gates defer only for accepted non-AWDL packet progress")
    func recoveryGatesDeferOnlyForAcceptedNonAwdlPacketProgress() async {
        let clock = StreamControllerManualTimeProvider(start: 1120)
        let controller = StreamController(
            streamID: 107,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - 10)

        let rejectedFlowSnapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: false,
            awaitingSince: 0,
            latestPacketReceivedTime: clock.now - 0.05,
            latestAcceptedPacketReceivedTime: 0,
            packetAcceptanceSnapshot: FrameReassembler.PacketAcceptanceSnapshot(
                rawPacketsReceived: 8,
                acceptedPacketsReceived: 0
            ),
            latestPendingKeyframeProgress: nil,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )
        let acceptedFlowSnapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: false,
            awaitingSince: 0,
            latestPacketReceivedTime: clock.now - 0.05,
            latestAcceptedPacketReceivedTime: clock.now - 0.05,
            packetAcceptanceSnapshot: FrameReassembler.PacketAcceptanceSnapshot(
                rawPacketsReceived: 8,
                acceptedPacketsReceived: 8
            ),
            latestPendingKeyframeProgress: nil,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let rejectedDecision = await controller.keyframeRequestDecision(
            now: clock.now,
            reason: .frameLoss,
            snapshot: rejectedFlowSnapshot
        )
        let acceptedDecision = await controller.keyframeRequestDecision(
            now: clock.now,
            reason: .frameLoss,
            snapshot: acceptedFlowSnapshot
        )

        #expect(rejectedDecision == .requestKeyframe)
        #expect(acceptedDecision == .deferPacketsFlowing)

        await controller.stop()
    }

    @Test("AWDL accepted packet flow requires decoded or display progress to defer recovery")
    func awdlAcceptedPacketFlowRequiresUsefulProgressToDeferRecovery() async {
        let clock = StreamControllerManualTimeProvider(start: 1130)
        let controller = StreamController(
            streamID: 117,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.testSeedLastRecoveryRequestDispatchTime(
            clock.now - StreamController.localDuplicateKeyframeRequestGrace - 0.1
        )

        let acceptedFlowSnapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: false,
            awaitingSince: 0,
            latestPacketReceivedTime: clock.now - 0.05,
            latestAcceptedPacketReceivedTime: clock.now - 0.05,
            packetAcceptanceSnapshot: FrameReassembler.PacketAcceptanceSnapshot(
                rawPacketsReceived: 8,
                acceptedPacketsReceived: 8
            ),
            latestPendingKeyframeProgress: nil,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let noUsefulProgressDecision = await controller.keyframeRequestDecision(
            now: clock.now,
            reason: .frameLoss,
            snapshot: acceptedFlowSnapshot
        )
        #expect(noUsefulProgressDecision == .requestKeyframe)

        await controller.testSeedRecoveryProgress(decodedAt: clock.now - 0.05)
        let decodedProgressDecision = await controller.keyframeRequestDecision(
            now: clock.now,
            reason: .frameLoss,
            snapshot: acceptedFlowSnapshot
        )
        #expect(decodedProgressDecision == .deferPacketsFlowing)

        await controller.testSeedRecoveryProgress(decodedAt: 0, presentedAt: clock.now - 0.05)
        let displayProgressDecision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: acceptedFlowSnapshot,
            pendingRenderFrameCount: 0,
            pendingRenderFrameAgeMs: 0
        )
        #expect(displayProgressDecision == .deferPacketsFlowing)

        await controller.stop()
    }

    @Test("AWDL path kind uses progress gate when media profile is stale")
    func awdlPathKindUsesProgressGateWhenMediaProfileIsStale() async {
        let clock = StreamControllerManualTimeProvider(start: 1140)
        let controller = StreamController(
            streamID: 118,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.testSeedLastRecoveryRequestDispatchTime(
            clock.now - StreamController.localDuplicateKeyframeRequestGrace - 0.1
        )

        let acceptedFlowSnapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: false,
            awaitingSince: 0,
            latestPacketReceivedTime: clock.now - 0.05,
            latestAcceptedPacketReceivedTime: clock.now - 0.05,
            packetAcceptanceSnapshot: FrameReassembler.PacketAcceptanceSnapshot(
                rawPacketsReceived: 12,
                acceptedPacketsReceived: 12
            ),
            latestPendingKeyframeProgress: nil,
            transportPathKind: .awdl,
            mediaPathProfile: .unknown,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let decision = await controller.keyframeRequestDecision(
            now: clock.now,
            reason: .frameLoss,
            snapshot: acceptedFlowSnapshot
        )

        #expect(decision == .requestKeyframe)

        await controller.stop()
    }

    @Test("AWDL recovery ignores useful progress older than last request")
    func awdlRecoveryIgnoresUsefulProgressOlderThanLastRequest() async {
        let clock = StreamControllerManualTimeProvider(start: 1150)
        let controller = StreamController(
            streamID: 119,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - 0.10)
        await controller.testSeedRecoveryProgress(decodedAt: clock.now - 0.20)

        let acceptedFlowSnapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: false,
            awaitingSince: 0,
            latestPacketReceivedTime: clock.now - 0.05,
            latestAcceptedPacketReceivedTime: clock.now - 0.05,
            packetAcceptanceSnapshot: FrameReassembler.PacketAcceptanceSnapshot(
                rawPacketsReceived: 12,
                acceptedPacketsReceived: 12
            ),
            latestPendingKeyframeProgress: nil,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let decision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: acceptedFlowSnapshot,
            pendingRenderFrameCount: 0,
            pendingRenderFrameAgeMs: 0
        )

        #expect(decision == .requestKeyframe)

        await controller.stop()
    }

    @Test("Awaiting keyframe with no progress retries on bounded local and overlay grace")
    func awaitingKeyframeWithoutProgressUsesBoundedRetryGrace() async {
        let clock = StreamControllerManualTimeProvider(start: 1200)
        let cases: [(MirageCore.MirageNetworkPathKind, MirageMedia.MirageMediaPathProfile, CFAbsoluteTime)] = [
            (.wifi, .localWiFi, StreamController.localAwaitingKeyframeNoProgressRetryGrace),
            (.vpn, .vpnOrOverlay, StreamController.remoteAwaitingKeyframeNoProgressRetryGrace)
        ]

        for (index, testCase) in cases.enumerated() {
            let controller = StreamController(
                streamID: StreamID(108 + index),
                maxPayloadSize: 1200,
                nowProvider: { clock.now }
            )
            let snapshot = FrameReassembler.KeyframeWaitSnapshot(
                isAwaitingKeyframe: true,
                awaitingSince: clock.now - 1,
                latestPacketReceivedTime: clock.now - 0.05,
                latestPendingKeyframeProgress: nil,
                transportPathKind: testCase.0,
                mediaPathProfile: testCase.1,
                pendingFrameCount: 2,
                pendingKeyframeCount: 0,
                incompleteFrameTimeouts: 0,
                incompleteFrameNoProgressTimeouts: 0,
                incompleteFrameLifetimeTimeouts: 0,
                forwardGapTimeouts: 0
            )

            await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - testCase.2 + 0.1)
            let deferredDecision = await controller.keyframeRequestDecision(
                now: clock.now,
                reason: .frameLoss,
                snapshot: snapshot
            )
            #expect(deferredDecision == .deferRetryGrace)

            await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - testCase.2 - 0.1)
            let retryDecision = await controller.keyframeRequestDecision(
                now: clock.now,
                reason: .frameLoss,
                snapshot: snapshot
            )
            #expect(retryDecision == .requestKeyframe)

            await controller.stop()
        }
    }

    @Test("Freeze recovery skips stale presenter frames while awaiting keyframe")
    func freezeRecoverySkipsStalePresenterFramesWhileAwaitingKeyframe() async {
        let clock = StreamControllerManualTimeProvider(start: 1400)
        let controller = StreamController(
            streamID: 118,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        let snapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: true,
            awaitingSince: clock.now - 1,
            latestPacketReceivedTime: clock.now - 0.05,
            latestPendingKeyframeProgress: nil,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            pendingFrameCount: 2,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let freshDecision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: snapshot,
            pendingRenderFrameCount: 1,
            pendingRenderFrameAgeMs: StreamController.stalePendingRenderFrameRecoveryAgeMs - 1
        )
        #expect(freshDecision == .presenterRecovery)

        let staleDecision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: snapshot,
            pendingRenderFrameCount: 1,
            pendingRenderFrameAgeMs: StreamController.stalePendingRenderFrameRecoveryAgeMs + 1
        )
        #expect(staleDecision == .requestKeyframe)

        await controller.stop()
    }

    @Test("Freeze recovery retries awaiting keyframe with no progress after bounded grace")
    func freezeRecoveryRetriesAwaitingKeyframeWithNoProgressAfterBoundedGrace() async {
        let clock = StreamControllerManualTimeProvider(start: 1500)
        let controller = StreamController(
            streamID: 121,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        let retryGrace = StreamController.localAwaitingKeyframeNoProgressRetryGrace
        let snapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: true,
            awaitingSince: clock.now - 1,
            latestPacketReceivedTime: clock.now - 0.05,
            latestPendingKeyframeProgress: nil,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            pendingFrameCount: 0,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        await controller.testSeedClientRecoveryStatus(.keyframeRecovery)
        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - retryGrace + 0.1)
        let deferredDecision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: snapshot,
            pendingRenderFrameCount: 0,
            pendingRenderFrameAgeMs: 0
        )
        #expect(deferredDecision == .deferRetryGrace)

        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - retryGrace - 0.1)
        let retryDecision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: snapshot,
            pendingRenderFrameCount: 0,
            pendingRenderFrameAgeMs: 0
        )
        #expect(retryDecision == .requestKeyframe)

        await controller.stop()
    }

    @Test("Freeze recovery hard-recovers after no-progress floor")
    func freezeRecoveryHardRecoversAfterNoProgressFloor() async {
        let clock = StreamControllerManualTimeProvider(start: 1600)
        let controller = StreamController(
            streamID: 119,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        let floor = await controller.hardRecoveryNoProgressFloor(for: .vpn)
        let snapshot = FrameReassembler.KeyframeWaitSnapshot(
            isAwaitingKeyframe: true,
            awaitingSince: clock.now - floor - 0.1,
            latestPacketReceivedTime: clock.now - 0.05,
            latestPendingKeyframeProgress: nil,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay,
            pendingFrameCount: 2,
            pendingKeyframeCount: 0,
            incompleteFrameTimeouts: 0,
            incompleteFrameNoProgressTimeouts: 0,
            incompleteFrameLifetimeTimeouts: 0,
            forwardGapTimeouts: 0
        )

        let decision = await controller.freezeRecoveryDecision(
            now: clock.now,
            snapshot: snapshot,
            pendingRenderFrameCount: 0,
            pendingRenderFrameAgeMs: 0
        )

        #expect(decision == .hardRecovery)

        await controller.stop()
    }

    @Test("Tier-promotion probe requests single fallback keyframe without presentation progress")
    func tierPromotionProbeRequestsFallbackKeyframeWithoutProgress() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let streamID: StreamID = 94
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        primeStreamControllerKeyframeAnchor(for: reassembler, streamID: streamID)
        #expect(reassembler.hasKeyframeAnchor)
        #expect(!reassembler.isAwaitingKeyframe)

        await controller.updatePresentationTier(.passiveSnapshot)
        await controller.updatePresentationTier(.activeLive)
        try await streamControllerWaitUntil("tier promotion probe fallback keyframe", timeout: .seconds(6)) {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Reset re-arms first-frame callback for post-resize transitions")
    func resetRearmsFirstFrameCallbackForPostResizeTransition() async throws {
        let firstFrameCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 90, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: {
                firstFrameCounter.increment()
            }
        )

        await controller.markFirstFramePresented()
        try await streamControllerWaitUntil("initial first-frame callback") {
            firstFrameCounter.value == 1
        }
        #expect(await controller.hasPresentedFirstFrame)

        await controller.resetForNewSession()
        #expect(await !(controller.hasPresentedFirstFrame))
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        try await streamControllerWaitUntil("post-resize first-frame callback") {
            firstFrameCounter.value == 2
        }

        #expect(await controller.hasPresentedFirstFrame)
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize transition clears after first presented frame")
    func postResizeTransitionClearsAfterFirstPresentedFrame() async {
        let controller = StreamController(streamID: 190, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFrameDecoded()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize decoder recovery signal does not clear recovery before presentation")
    func postResizeDecoderRecoverySignalDoesNotClearRecoveryBeforePresentation() async {
        let controller = StreamController(streamID: 191, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        await controller.handleDecoderRecoverySignal()

        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize decoded frame threshold does not clear recovery before presentation")
    func postResizeDecodedFrameThresholdDoesNotClearRecoveryBeforePresentation() async {
        let controller = StreamController(streamID: 193, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        for _ in 0 ..< StreamController.postResizeDecodeRecoverySuccessThreshold {
            await controller.recordDecodedFrame()
        }

        #expect(await controller.awaitingFirstFrameAfterResize)
        #expect(await controller.awaitingFirstPresentedFrameAfterResize)
        #expect(
            await controller.postResizeDecodeRecoverySuccessCount ==
                StreamController.postResizeDecodeRecoverySuccessThreshold
        )

        await controller.markFirstFramePresented()
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Post-resize first presentation accepts new render generation")
    func postResizeFirstPresentationAcceptsNewRenderGeneration() async throws {
        let streamID: StreamID = 194
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(sequence: 65049, for: streamID)
        let firstFrameCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: {
                firstFrameCounter.increment()
            }
        )

        await controller.beginPostResizeTransition()
        let baselineSnapshot = await controller.firstPresentedFrameBaselineSnapshot
        #expect(baselineSnapshot != nil)
        MirageRenderStreamStore.shared.clear(for: streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makeStreamControllerPixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        let currentCursor = MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.cursor
        #expect(currentCursor != nil)
        guard let currentCursor else {
            Issue.record("Expected current cursor after post-resize enqueue")
            await controller.stop()
            return
        }
        MirageRenderStreamStore.shared.markSubmitted(
            cursor: currentCursor,
            for: streamID
        )
        let submittedSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        if let baselineSnapshot {
            #expect(submittedSnapshot.hasSubmittedFrame(after: baselineSnapshot))
        }

        try await streamControllerWaitUntil("post-resize new-generation presentation") {
            firstFrameCounter.value == 1
        }
        #expect(await !(controller.awaitingFirstFrameAfterResize))
        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
    }

    @Test("Post-resize local timeout clears controller recovery")
    func postResizeLocalTimeoutClearsControllerRecovery() async {
        let controller = StreamController(streamID: 195, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)
        #expect(await controller.awaitingFirstPresentedFrameAfterResize)
        #expect(await controller.clientRecoveryStatus == .postResizeAwaitingFirstFrame)

        await controller.clearPostResizeRecoveryAfterLocalTimeout()

        #expect(await !(controller.awaitingFirstFrameAfterResize))
        #expect(await !(controller.awaitingFirstPresentedFrameAfterResize))
        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
    }

    @Test("New resize re-arms post-resize presentation gating after prior presentation")
    func newResizeRearmsPostResizePresentationGating() async {
        let controller = StreamController(streamID: 192, maxPayloadSize: 1200)

        await controller.beginPostResizeTransition()
        await controller.markFirstFramePresented()

        #expect(await !(controller.awaitingFirstPresentedFrameAfterResize))
        #expect(await !(controller.awaitingFirstFrameAfterResize))

        await controller.beginPostResizeTransition()

        #expect(await controller.awaitingFirstPresentedFrameAfterResize)
        #expect(await controller.awaitingFirstFrameAfterResize)
        #expect(await controller.postResizeDecodeRecoverySuccessCount == 0)

        await controller.stop()
    }

    @Test("Backpressure threshold does not request keyframe recovery")
    func backpressureDoesNotRequestKeyframes() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 1000)
        let controller = StreamController(
            streamID: 2,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
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

    @Test("Most Responsive decode queue dependency break waits for recovery keyframe")
    func mostResponsiveDecodeQueueDependencyBreakWaitsForRecoveryKeyframe() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let releaseCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 3, maxPayloadSize: 1200)
        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        let droppedFrame = StreamController.FrameData(
            data: Data([0x01]),
            presentationTime: .zero,
            isKeyframe: false,
            frameNumber: nil,
            contentRect: .zero,
            releaseBuffer: {
                releaseCounter.increment()
            }
        )

        await controller.handleDecodeQueueDependencyBreak(
            droppedFrame: droppedFrame,
            queueDepth: StreamController.maxQueuedFrames
        )

        #expect(await controller.decodeQueueRequiresKeyframe)
        #expect(await controller.reassembler.isAwaitingKeyframe)
        #expect(await controller.clientRecoveryStatus == .keyframeRecovery)
        #expect(await controller.clientRecoveryCause == .frameLoss)
        #expect(releaseCounter.value == 1)
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Balanced decode queue dependency break preserves existing continuity policy")
    func balancedDecodeQueueDependencyBreakPreservesExistingContinuityPolicy() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let releaseCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: 30, maxPayloadSize: 1200)
        await controller.updateCadenceTarget(sourceFPS: 60, latencyMode: .balanced)
        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )

        let droppedFrame = StreamController.FrameData(
            data: Data([0x01]),
            presentationTime: .zero,
            isKeyframe: false,
            frameNumber: nil,
            contentRect: .zero,
            releaseBuffer: {
                releaseCounter.increment()
            }
        )

        await controller.handleDecodeQueueDependencyBreak(
            droppedFrame: droppedFrame,
            queueDepth: StreamController.maxQueuedFrames
        )

        #expect(await controller.decodeQueueRequiresKeyframe == false)
        #expect(await controller.reassembler.isAwaitingKeyframe == false)
        #expect(await controller.clientRecoveryCause == .none)
        #expect(releaseCounter.value == 1)
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Keyframe-starved decode recovery bypasses dispatch suppression")
    func keyframeStarvedDecodeRecoveryBypassesDispatchSuppression() async throws {
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 5000)
        let controller = StreamController(
            streamID: 4,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.testSeedRecoveryKeyframeDispatchTimes([
            clock.now - 1.0,
            clock.now - 2.0,
            clock.now - 3.0
        ])
        let reassembler = await controller.reassembler
        reassembler.beginKeyframeWait()

        let requested = await controller.requestKeyframeRecovery(
            reason: .decodeErrorThreshold,
            bypassRetryGate: true
        )

        #expect(requested)
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Startup keyframe timeout bypasses generic dispatch suppression")
    func startupKeyframeTimeoutBypassesGenericDispatchSuppression() async {
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 5200)
        let controller = StreamController(
            streamID: 5,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - 0.01)
        await controller.testSeedRecoveryKeyframeDispatchTimes([
            clock.now - 1.0,
            clock.now - 2.0,
            clock.now - 3.0
        ])

        let requested = await controller.requestKeyframeRecovery(reason: .startupKeyframeTimeout)

        #expect(requested)
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Post-resize awaiting first frame bypasses generic dispatch suppression")
    func postResizeAwaitingFirstFrameBypassesGenericDispatchSuppression() async {
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 5400)
        let controller = StreamController(
            streamID: 6,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
                return true
            }
        )
        await controller.beginPostResizeTransition()
        await controller.testSeedLastRecoveryRequestDispatchTime(clock.now - 0.01)
        await controller.testSeedRecoveryKeyframeDispatchTimes([
            clock.now - 1.0,
            clock.now - 2.0,
            clock.now - 3.0
        ])

        let requested = await controller.requestKeyframeRecovery(reason: .manualRecovery)

        #expect(requested)
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("AWDL decode queue budget holds a bounded jitter window")
    func awdlDecodeQueueBudgetHoldsBoundedJitterWindow() {
        #expect(StreamController.awdlMaxQueuedFrames(targetFPS: 20) == 8)
        #expect(StreamController.awdlMaxQueuedFrames(targetFPS: 60) == 15)
        #expect(StreamController.awdlMaxQueuedFrames(targetFPS: 120) == 30)
    }

}

func streamControllerWaitUntil(
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

func makeStreamControllerPixelBuffer() -> CVPixelBuffer {
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

func primeStreamControllerKeyframeAnchor(
    for reassembler: FrameReassembler,
    streamID: StreamID,
    frameNumber: UInt32 = 1
) {
    let keyframePayload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
    reassembler.processPacket(
        keyframePayload,
        header: makeStreamControllerVideoHeader(
            streamID: streamID,
            flags: [.keyframe, .endOfFrame],
            frameNumber: frameNumber,
            payload: keyframePayload
        )
    )
}

func makeStreamControllerVideoHeader(
    streamID: StreamID,
    flags: MirageWire.FrameFlags,
    frameNumber: UInt32,
    payload: Data
) -> MirageWire.FrameHeader {
    MirageWire.FrameHeader(
        flags: flags,
        streamID: streamID,
        sequenceNumber: frameNumber,
        timestamp: UInt64(frameNumber),
        frameNumber: frameNumber,
        fragmentIndex: 0,
        fragmentCount: 1,
        payloadLength: UInt32(payload.count),
        frameByteCount: UInt32(payload.count),
        checksum: streamControllerCRC32(payload),
        contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        dimensionToken: 0,
        epoch: 0
    )
}

func streamControllerCRC32(_ data: Data) -> UInt32 {
    let polynomial: UInt32 = 0xEDB8_8320
    var crc: UInt32 = 0xFFFF_FFFF
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
    return crc ^ 0xFFFF_FFFF
}

final class StreamControllerLockedCounter: @unchecked Sendable {
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

final class StreamControllerLockedTerminalStartupFailure: @unchecked Sendable {
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

final class StreamControllerManualTimeProvider: @unchecked Sendable {
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
