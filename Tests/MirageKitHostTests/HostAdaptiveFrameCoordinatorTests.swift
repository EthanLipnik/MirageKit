//
//  HostAdaptiveFrameCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/16/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Adaptive Frame Coordinator")
struct HostAdaptiveFrameCoordinatorTests {
    @Test("Input and motion classify as realtime motion")
    func inputAndMotionClassifyAsRealtimeMotion() {
        var coordinator = HostAdaptiveFrameCoordinator()

        let decision = coordinator.evaluateFrame(makeInput(
            dirtyPercentage: 12,
            inputActive: true
        ))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.realtimeMotion)
        #expect(decision.action == HostAdaptiveFrameCoordinator.FrameAction.encodePFrame)
        #expect(decision.lane == HostAdaptiveFrameCoordinator.Lane.realtime)
        #expect(decision.deadlineClass == HostAdaptiveFrameCoordinator.DeadlineClass.realtime)
    }

    @Test("Still quality opportunity classifies as clarity refresh")
    func stillQualityOpportunityClassifiesAsClarityRefresh() {
        var coordinator = HostAdaptiveFrameCoordinator()

        let decision = coordinator.evaluateFrame(makeInput(
            isIdleFrame: true,
            sourceStill: true,
            inputActive: false,
            admitsStillQualityProbe: true
        ))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.clarityRefresh)
        #expect(decision.action == HostAdaptiveFrameCoordinator.FrameAction.encodePFrame)
        #expect(decision.lane == HostAdaptiveFrameCoordinator.Lane.clarity)
        #expect(decision.deadlineClass == HostAdaptiveFrameCoordinator.DeadlineClass.relaxed)
    }

    @Test("Idle frame without probe classifies as idle skip")
    func idleFrameWithoutProbeClassifiesAsIdleSkip() {
        var coordinator = HostAdaptiveFrameCoordinator()

        let decision = coordinator.evaluateFrame(makeInput(
            isIdleFrame: true,
            sourceStill: true,
            inputActive: false,
            admitsStillQualityProbe: false
        ))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.idleSkip)
        #expect(decision.action == HostAdaptiveFrameCoordinator.FrameAction.skip)
    }

    @Test("Pending bootstrap barrier suppresses dependent P-frames")
    func pendingBootstrapBarrierSuppressesDependentPFrames() {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 10)

        let decision = coordinator.evaluateFrame(makeInput(now: 10.01))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.bootstrapKeyframe)
        #expect(decision.action == HostAdaptiveFrameCoordinator.FrameAction.skip)
        #expect(decision.lane == HostAdaptiveFrameCoordinator.Lane.bootstrap)
    }

    @Test("Startup keyframe uses high-compression bootstrap quality")
    func startupKeyframeUsesHighCompressionBootstrapQuality() {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 20)

        let decision = coordinator.evaluateFrame(makeInput(
            forceKeyframe: true,
            hasSentKeyframe: false,
            qualityCeiling: 0.90,
            now: 20.01
        ))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.bootstrapKeyframe)
        #expect(decision.action == HostAdaptiveFrameCoordinator.FrameAction.encodeKeyframe)
        #expect(decision.targetQuality == HostAdaptiveFrameCoordinator.automaticStartupKeyframeQuality)
    }

    @Test("Startup barrier releases on clean local keyframe completion")
    func startupBarrierReleasesOnCleanLocalKeyframeCompletion() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 30)
        coordinator.bindKeyframeFrameNumber(42, now: 30.01)

        let optionalRelease = coordinator.noteKeyframeTransportCompletion(
            frameNumber: 42,
            didSend: true,
            allowsStartupLocalRelease: true,
            now: 30.03
        )
        let release = try #require(optionalRelease)

        #expect(release.kind == HostAdaptiveFrameCoordinator.KeyframeBarrierKind.bootstrap)
        #expect(release.evidence == "local-send-completion")
        #expect(!coordinator.hasActiveKeyframeBarrier)
    }

    @Test("Constrained startup waits for receiver acceptance")
    func constrainedStartupWaitsForReceiverAcceptance() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 40)
        coordinator.bindKeyframeFrameNumber(7, now: 40.01)

        let localRelease = coordinator.noteKeyframeTransportCompletion(
            frameNumber: 7,
            didSend: true,
            allowsStartupLocalRelease: false,
            now: 40.02
        )
        let optionalReceiverRelease = coordinator.noteReceiverAcceptedKeyframe(
            frameNumber: 7,
            now: 40.20
        )
        let receiverRelease = try #require(optionalReceiverRelease)

        #expect(localRelease == nil)
        #expect(receiverRelease.evidence == "receiver-accepted")
        #expect(!coordinator.hasActiveKeyframeBarrier)
    }

    @Test("Recovery barrier releases on receiver acceptance timeout")
    func recoveryBarrierReleasesOnReceiverAcceptanceTimeout() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .recovery, reason: "decode-error", now: 45)
        coordinator.bindKeyframeFrameNumber(9, now: 45.01)

        let localRelease = coordinator.noteKeyframeTransportCompletion(
            frameNumber: 9,
            didSend: true,
            allowsStartupLocalRelease: true,
            now: 45.02
        )
        let optionalTimeoutRelease = coordinator.releaseKeyframeBarrierAfterReceiverAcceptanceTimeout(
            frameNumber: 9,
            now: 46
        )
        let timeoutRelease = try #require(optionalTimeoutRelease)

        #expect(localRelease == nil)
        #expect(timeoutRelease.kind == HostAdaptiveFrameCoordinator.KeyframeBarrierKind.recovery)
        #expect(timeoutRelease.evidence == "receiver-acceptance-timeout")
        #expect(!coordinator.hasActiveKeyframeBarrier)
    }

    @Test("Recovery barrier ends bootstrap probe window")
    func recoveryBarrierEndsBootstrapProbeWindow() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 47)
        coordinator.bindKeyframeFrameNumber(10, now: 47.01)
        let optionalStartupRelease = coordinator.noteKeyframeTransportCompletion(
            frameNumber: 10,
            didSend: true,
            allowsStartupLocalRelease: true,
            now: 47.02
        )
        _ = try #require(optionalStartupRelease)

        let startupProbe = coordinator.evaluateFrame(makeInput(
            dirtyPercentage: 12,
            now: 47.03
        ))
        coordinator.startKeyframeBarrier(kind: .recovery, reason: "freeze", now: 47.04)
        coordinator.bindKeyframeFrameNumber(11, now: 47.05)
        let optionalRecoveryRelease = coordinator.noteReceiverAcceptedKeyframe(frameNumber: 11, now: 47.06)
        _ = try #require(optionalRecoveryRelease)
        let postRecovery = coordinator.evaluateFrame(makeInput(
            dirtyPercentage: 12,
            now: 47.07
        ))

        #expect(startupProbe.intent == HostAdaptiveFrameCoordinator.FrameIntent.probe)
        #expect(postRecovery.intent == HostAdaptiveFrameCoordinator.FrameIntent.realtimeMotion)
    }

    @Test("Startup realtime probe raises target quality immediately")
    func startupRealtimeProbeRaisesTargetQualityImmediately() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 48)
        coordinator.bindKeyframeFrameNumber(10, now: 48.01)
        let optionalRelease = coordinator.noteKeyframeTransportCompletion(
            frameNumber: 10,
            didSend: true,
            allowsStartupLocalRelease: true,
            now: 48.02
        )
        _ = try #require(optionalRelease)

        let decision = coordinator.evaluateFrame(makeInput(
            dirtyPercentage: 12,
            currentQuality: 0.20,
            qualityFloor: 0.10,
            qualityCeiling: 0.90,
            now: 48.03
        ))

        #expect(decision.intent == HostAdaptiveFrameCoordinator.FrameIntent.probe)
        #expect((decision.targetQuality ?? 0) > 0.20)
    }

    @Test("Startup fallback releases without receiver feedback")
    func startupFallbackReleasesWithoutReceiverFeedback() throws {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.startKeyframeBarrier(kind: .bootstrap, reason: "startup", now: 50)

        let early = coordinator.releaseStartupBarrierIfTimedOut(
            senderQueuedBytes: 0,
            queuePressureBytes: 1_200_000,
            now: 50.10
        )
        let optionalRelease = coordinator.releaseStartupBarrierIfTimedOut(
            senderQueuedBytes: 0,
            queuePressureBytes: 1_200_000,
            now: 50.16
        )
        let release = try #require(optionalRelease)

        #expect(early == nil)
        #expect(release.evidence == "startup-clean-fallback")
    }

    @Test("Clarity failure does not collapse realtime lane")
    func clarityFailureDoesNotCollapseRealtimeLane() {
        var coordinator = HostAdaptiveFrameCoordinator()
        coordinator.noteFrameReserved(
            frameNumber: 1,
            intent: HostAdaptiveFrameCoordinator.FrameIntent.realtimeMotion,
            wireBytes: 64_000,
            quality: 0.50,
            now: 60
        )
        coordinator.noteFrameTransportCompletion(
            frameNumber: 1,
            didSend: true,
            queuedUnreliableDropCount: 0,
            now: 60.02
        )
        coordinator.noteFrameReserved(
            frameNumber: 2,
            intent: HostAdaptiveFrameCoordinator.FrameIntent.clarityRefresh,
            wireBytes: 512_000,
            quality: 0.82,
            now: 61
        )
        coordinator.noteFrameTransportCompletion(
            frameNumber: 2,
            didSend: false,
            queuedUnreliableDropCount: 1,
            now: 61.10
        )

        let snapshot = coordinator.currentLaneSnapshot
        #expect(snapshot.realtimeWireBytes == 64_000)
        #expect(snapshot.realtimeFailedProbes == 0)
        #expect(snapshot.clarityFailedProbes == 1)
    }

    @Test("Structural scale demotion is last resort after severe receiver pressure")
    func structuralScaleDemotionIsLastResortAfterSevereReceiverPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()

        #expect(!coordinator.allowsStructuralScaleDemotion(
            receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState.pressured,
            transportAdmissionActiveDuration: 3
        ))
        #expect(!coordinator.allowsStructuralScaleDemotion(
            receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState.severe,
            transportAdmissionActiveDuration: 1.5
        ))
        #expect(coordinator.allowsStructuralScaleDemotion(
            receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState.severe,
            transportAdmissionActiveDuration: 2.1
        ))
    }

    @Test("Startup receiver quarantine is observe-only without live pressure")
    func startupReceiverQuarantineIsObserveOnlyWithoutLivePressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            receiverState: .unknown,
            receiverCapacityLearningQuarantineReason: "startup",
            realtimePressureState: .pressured,
            realtimePressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.receiverPressureIsActionable(snapshot))
        #expect(!coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Receiver ack lag quarantine is observe-only without live pressure")
    func receiverAckLagQuarantineIsObserveOnlyWithoutLivePressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            receiverState: .severe,
            receiverCapacityLearningQuarantineReason: "receiver-ack-lag",
            receiverAckLagMs: 900,
            realtimePressureState: .severe,
            realtimePressureReason: HostAdaptivePFrameController.Reason.pFrameLatency.rawValue
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.receiverPressureIsActionable(snapshot))
        #expect(!coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Presentation underflow quarantine is observe-only without live pressure")
    func presentationUnderflowQuarantineIsObserveOnlyWithoutLivePressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            receiverState: .pressured,
            receiverCapacityLearningQuarantineReason: "presentation-underflow",
            realtimePressureState: .pressured,
            realtimePressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.receiverPressureIsActionable(snapshot))
        #expect(!coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Soft queued bytes alone are not actionable transport pressure")
    func softQueuedBytesAloneAreNotActionableTransportPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            senderQueuedBytes: 1_300_000,
            queuePressureBytes: 1_200_000
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Sender queue saturation is actionable transport pressure")
    func senderQueueSaturationIsActionableTransportPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            senderQueuedBytes: 2_100_000,
            queuePressureBytes: 1_200_000,
            maxQueuedBytes: 2_000_000
        )

        #expect(coordinator.transportPressureIsActionable(snapshot))
        #expect(coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Packet pacer debt is actionable sender pressure")
    func packetPacerDebtIsActionableSenderPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            mediaPathProfile: .vpnOrOverlay,
            packetPacerFrameMaxSleepMs: 80
        )

        #expect(coordinator.transportPressureIsActionable(snapshot))
        #expect(coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Local bulk path ignores transient pacer debt")
    func localBulkPathIgnoresTransientPacerDebt() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            mediaPathProfile: .proximityWiredLike,
            packetPacerFrameMaxSleepMs: 80
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.allowsPreEncodeBudgetReduction(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Local bulk frame budget applies motion-size cuts")
    func localBulkFrameBudgetAppliesMotionSizeCuts() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(mediaPathProfile: .proximityWiredLike)
        let decision = makeBudgetDecision(
            state: .pressured,
            reason: .encodedFrame
        )

        #expect(coordinator.frameBudgetDecisionIsActionable(decision, snapshot: snapshot))
    }

    @Test("Local bulk client recovery observes without hard pressure")
    func localBulkClientRecoveryObservesWithoutHardPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(mediaPathProfile: .proximityWiredLike)
        let decision = makeBudgetDecision(
            state: .severe,
            reason: .clientRecovery
        )

        #expect(!coordinator.frameBudgetDecisionIsActionable(decision, snapshot: snapshot))
    }

    @Test("Local bulk receiver reassembly backlog needs hard threshold")
    func localBulkReceiverReassemblyBacklogNeedsHardThreshold() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let softSnapshot = makePressureSnapshot(
            mediaPathProfile: .proximityWiredLike,
            receiverReassemblyBacklogFrames: 1,
            receiverReassemblyBacklogBytes: 64 * 1024
        )
        let hardSnapshot = makePressureSnapshot(
            mediaPathProfile: .proximityWiredLike,
            receiverReassemblyBacklogFrames: 4,
            receiverReassemblyBacklogBytes: 64 * 1024
        )
        let decision = makeBudgetDecision(
            state: .severe,
            reason: .receiverBacklog
        )

        #expect(!coordinator.receiverPressureIsActionable(softSnapshot))
        #expect(!coordinator.frameBudgetDecisionIsActionable(decision, snapshot: softSnapshot))
        #expect(coordinator.receiverPressureIsActionable(hardSnapshot))
        #expect(coordinator.frameBudgetDecisionIsActionable(decision, snapshot: hardSnapshot))
    }

    @Test("Local bulk sender saturation makes frame budget actionable")
    func localBulkSenderSaturationMakesFrameBudgetActionable() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            mediaPathProfile: .proximityWiredLike,
            senderQueuedBytes: 2_200_000,
            maxQueuedBytes: 2_000_000
        )
        let decision = makeBudgetDecision(
            state: .severe,
            reason: .transportBacklog
        )

        #expect(coordinator.frameBudgetDecisionIsActionable(decision, snapshot: snapshot))
    }

    @Test("Local bulk encoder lag remains actionable")
    func localBulkEncoderLagRemainsActionable() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(mediaPathProfile: .proximityWiredLike)
        let decision = makeBudgetDecision(
            state: .pressured,
            reason: .encoderLag
        )

        #expect(coordinator.frameBudgetDecisionIsActionable(decision, snapshot: snapshot))
    }

    @Test("Clean queued-unreliable occupancy is not actionable transport pressure")
    func cleanQueuedUnreliableOccupancyIsNotActionableTransportPressure() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            queuedUnreliablePendingPackets: 10,
            queuedUnreliableOutstandingPackets: 64,
            queuedUnreliableQueuedBytes: 96 * 1024,
            queuedUnreliableQueueDwellP99Ms: 0,
            queuedUnreliableSendGapP99Ms: 35,
            queuedUnreliableContentProcessedP99Ms: 1
        )

        #expect(!coordinator.transportPressureIsActionable(snapshot))
        #expect(!coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    @Test("Queued-unreliable backlog with timing pressure is actionable")
    func queuedUnreliableBacklogWithTimingPressureIsActionable() {
        let coordinator = HostAdaptiveFrameCoordinator()
        let snapshot = makePressureSnapshot(
            mediaPathProfile: .vpnOrOverlay,
            queuedUnreliablePendingPackets: 10,
            queuedUnreliableQueuedBytes: 96 * 1024,
            queuedUnreliableQueueDwellP99Ms: 180
        )

        #expect(coordinator.transportPressureIsActionable(snapshot))
        #expect(coordinator.allowsTransportAdmissionThrottle(snapshot))
    }

    private func makeInput(
        forceKeyframe: Bool = false,
        hasSentKeyframe: Bool = true,
        pendingKeyframeReason: String? = nil,
        frameChainRepairActive: Bool = false,
        isIdleFrame: Bool = false,
        dirtyPercentage: Float = 0,
        sourceStill: Bool = false,
        inputActive: Bool = false,
        admitsStillQualityProbe: Bool = false,
        senderQueuedBytes: Int = 0,
        receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState = .healthy,
        currentQuality: Float = 0.50,
        qualityFloor: Float = 0.42,
        qualityCeiling: Float = 0.90,
        now: Double = 1
    ) -> HostAdaptiveFrameCoordinator.FrameInput {
        HostAdaptiveFrameCoordinator.FrameInput(
            forceKeyframe: forceKeyframe,
            hasSentKeyframe: hasSentKeyframe,
            pendingKeyframeReason: pendingKeyframeReason,
            frameChainRepairActive: frameChainRepairActive,
            isIdleFrame: isIdleFrame,
            dirtyPercentage: dirtyPercentage,
            sourceStill: sourceStill,
            inputActive: inputActive,
            admitsStillQualityProbe: admitsStillQualityProbe,
            senderQueuedBytes: senderQueuedBytes,
            queuePressureBytes: 1_200_000,
            maxQueuedBytes: 2_000_000,
            receiverState: receiverState,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            qualityCeiling: qualityCeiling,
            mediaPathProfile: .localWiFi,
            now: now
        )
    }

    private func makePressureSnapshot(
        mediaPathProfile: MirageMediaPathProfile = .localWiFi,
        receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState = .healthy,
        receiverCapacityLearningQuarantineReason: String? = nil,
        receiverReassemblyBacklogFrames: Int = 0,
        receiverReassemblyBacklogBytes: Int = 0,
        receiverDecodeBacklogFrames: Int = 0,
        receiverPresentationBacklogFrames: Int = 0,
        receiverLossHoldActive: Bool = false,
        receiverAckLagMs: Double? = nil,
        senderQueuedBytes: Int = 0,
        queuePressureBytes: Int = 1_200_000,
        maxQueuedBytes: Int = 2_000_000,
        senderDropHoldActive: Bool = false,
        unstartedPFrameCount: Int = 0,
        oldestUnstartedPFrameAgeMs: Double = 0,
        oldestUnstartedPFrameLatenessMs: Double = 0,
        queuedUnreliablePendingPackets: Int = 0,
        queuedUnreliableOutstandingPackets: Int = 0,
        queuedUnreliableQueuedBytes: Int = 0,
        queuedUnreliableQueueDwellP99Ms: Double = 0,
        queuedUnreliableSendGapP99Ms: Double = 0,
        queuedUnreliableContentProcessedP99Ms: Double = 0,
        packetPacerFrameMaxSleepMs: Double = 0,
        startupProtectionActive: Bool = false,
        frameChainRepairActive: Bool = false,
        realtimePressureState: HostAdaptivePFrameController.PressureState = .observing,
        realtimePressureReason: String? = nil,
        transportAdmissionActiveDuration: Double = 0
    ) -> HostAdaptiveFrameCoordinator.TransportPressureSnapshot {
        HostAdaptiveFrameCoordinator.TransportPressureSnapshot(
            mediaPathProfile: mediaPathProfile,
            currentFrameRate: 60,
            receiverState: receiverState,
            receiverCapacityLearningQuarantineReason: receiverCapacityLearningQuarantineReason,
            receiverReassemblyBacklogFrames: receiverReassemblyBacklogFrames,
            receiverReassemblyBacklogBytes: receiverReassemblyBacklogBytes,
            receiverDecodeBacklogFrames: receiverDecodeBacklogFrames,
            receiverPresentationBacklogFrames: receiverPresentationBacklogFrames,
            receiverLossHoldActive: receiverLossHoldActive,
            receiverAckLagMs: receiverAckLagMs,
            senderQueuedBytes: senderQueuedBytes,
            queuePressureBytes: queuePressureBytes,
            maxQueuedBytes: maxQueuedBytes,
            senderDropHoldActive: senderDropHoldActive,
            unstartedPFrameCount: unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: oldestUnstartedPFrameAgeMs,
            oldestUnstartedPFrameLatenessMs: oldestUnstartedPFrameLatenessMs,
            queuedUnreliablePendingPackets: queuedUnreliablePendingPackets,
            queuedUnreliableOutstandingPackets: queuedUnreliableOutstandingPackets,
            queuedUnreliableQueuedBytes: queuedUnreliableQueuedBytes,
            queuedUnreliableQueueDwellP99Ms: queuedUnreliableQueueDwellP99Ms,
            queuedUnreliableSendGapP99Ms: queuedUnreliableSendGapP99Ms,
            queuedUnreliableContentProcessedP99Ms: queuedUnreliableContentProcessedP99Ms,
            packetPacerFrameMaxSleepMs: packetPacerFrameMaxSleepMs,
            startupProtectionActive: startupProtectionActive,
            frameChainRepairActive: frameChainRepairActive,
            realtimePressureState: realtimePressureState,
            realtimePressureReason: realtimePressureReason,
            transportAdmissionActiveDuration: transportAdmissionActiveDuration
        )
    }

    private func makeBudgetDecision(
        state: HostAdaptivePFrameController.PressureState,
        reason: HostAdaptivePFrameController.Reason
    ) -> HostFrameBudgetDecision {
        HostFrameBudgetDecision(
            targetBitrateBps: 64_000_000,
            maxFrameBytes: 128 * 1024,
            maxWireBytes: 128 * 1024,
            maxPacketCount: 110,
            quality: 0.32,
            qualityCeiling: 0.32,
            keyframeQuality: 0.34,
            sendDeadline: 2,
            state: state,
            reason: reason
        )
    }
}
#endif
