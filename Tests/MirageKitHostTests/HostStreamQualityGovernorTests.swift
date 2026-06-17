//
//  HostStreamQualityGovernorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreFoundation
import MirageKit
import Testing

@Suite("Host Stream Quality Governor")
struct HostStreamQualityGovernorTests {
    @Test("Proximity soft transport evidence observes runtime cuts")
    func proximitySoftTransportEvidenceObservesRuntimeCuts() {
        var governor = HostStreamQualityGovernor()
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.40,
                state: .pressured,
                reason: .transportBacklog
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                receiverAckLagMs: 180
            ),
            contract: makeContract(mediaPathProfile: .proximityWiredLike),
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        #expect(result.shouldApply == false)
        #expect(result.streamDecision.cause == .receiver)
        #expect(result.streamDecision.blockedLeverReason == "soft-local-transport-backlog")
    }

    @Test("Proximity motion oversize applies quality reduction to motion floor")
    func proximityMotionOversizeAppliesQualityReductionToMotionFloor() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let motionFloor = try #require(contract.motionFloorBitrateBps())
        let readabilityFloor = try #require(contract.readabilityFloorBitrateBps())
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps >= motionFloor)
        #expect(decision.targetBitrateBps == 75_000_000)
        #expect(decision.targetBitrateBps > readabilityFloor)
        #expect(abs(decision.quality - contract.localMotionQualityFloor) < 0.0001)
        #expect(result.streamDecision.cause == .motion)
        #expect(result.streamDecision.blockedLeverReason == "motion-floor")
    }

    @Test("Proximity motion floor survives collapsed runtime quality ceiling")
    func proximityMotionFloorSurvivesCollapsedRuntimeQualityCeiling() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(
            mediaPathProfile: .proximityWiredLike,
            qualityCeiling: 0.06,
            steadyQualityCeiling: 0.06
        )
        let motionFloor = try #require(contract.motionFloorBitrateBps())
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.06,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 12_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps >= motionFloor)
        #expect(abs(decision.quality - contract.localMotionQualityFloor) < 0.0001)
        #expect(decision.qualityCeiling >= contract.localMotionQualityFloor)
    }

    @Test("Proximity hard receiver evidence applies but preserves readability floor")
    func proximityHardReceiverEvidenceAppliesReadabilityFloor() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let floor = try #require(contract.readabilityFloorBitrateBps())
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.28,
                state: .severe,
                reason: .receiverBacklog
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                receiverState: .severe,
                receiverReassemblyBacklogFrames: 4
            ),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps >= floor)
        #expect(decision.quality >= 0.66)
        #expect(result.streamDecision.blockedLeverReason == "readability-floor")
    }

    @Test("Proximity sender deadline uses motion floor for recovery")
    func proximitySenderDeadlineUsesMotionFloorForRecovery() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let floor = try #require(contract.motionFloorBitrateBps())
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.24,
                state: .severe,
                reason: .senderDeadline
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                senderDropHoldActive: true
            ),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: true,
            now: 10
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps >= floor)
        #expect(abs(decision.quality - contract.localMotionQualityFloor) < 0.0001)
        #expect(result.streamDecision.evidenceClass == .hard)
        #expect(result.streamDecision.cause == .transport)
        #expect(result.streamDecision.blockedLeverReason == "motion-floor")
    }

    @Test("Dynamic SCK idle records capture diagnostic without bitrate starvation")
    func dynamicSCKIdleRecordsCaptureDiagnosticWithoutBitrateStarvation() {
        var governor = HostStreamQualityGovernor()
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.32,
                state: .pressured,
                reason: .clientRecovery
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                captureCadenceState: .dynamicIdle,
                captureCadenceSummary: "dynamic-idle:raw=20.0,observed=2.0,idle=45,gapP99=500.0ms",
                receiverState: .severe,
                receiverAckLagMs: 900
            ),
            contract: makeContract(mediaPathProfile: .proximityWiredLike),
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        #expect(result.shouldApply == false)
        #expect(result.streamDecision.evidenceClass == .diagnostic)
        #expect(result.streamDecision.cause == .capture)
        #expect(result.streamDecision.blockedLeverReason == "soft-local-client-recovery")
    }

    @Test("Dynamic SCK idle does not block explicit motion complexity cut")
    func dynamicSCKIdleDoesNotBlockExplicitMotionComplexityCut() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 16_000_000,
                quality: 0.30,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                captureCadenceState: .dynamicIdle,
                captureCadenceSummary: "dynamic-idle:raw=20.0,observed=2.0,idle=45,gapP99=500.0ms",
                receiverState: .severe,
                receiverAckLagMs: 900
            ),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 10
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps == 75_000_000)
        #expect(abs(decision.quality - contract.localMotionQualityFloor) < 0.0001)
        #expect(result.streamDecision.cause == .motion)
    }

    @Test("Startup warmup blocks soft pressure cuts")
    func startupWarmupBlocksSoftPressureCuts() {
        var governor = HostStreamQualityGovernor()
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 16_000_000,
                quality: 0.40,
                state: .pressured,
                reason: .pFrameLatency
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .vpnOrOverlay,
                receiverAckLagMs: 180
            ),
            contract: makeContract(
                mediaPathProfile: .vpnOrOverlay,
                startupBaseTime: 100,
                encodedFrameCount: 10
            ),
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 101
        )

        #expect(result.shouldApply == false)
        #expect(result.streamDecision.blockedLeverReason == "startup-warmup")
    }

    @Test("Startup warmup allows explicit motion quality cuts")
    func startupWarmupAllowsExplicitMotionQualityCuts() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(
            mediaPathProfile: .proximityWiredLike,
            startupBaseTime: 100,
            encodedFrameCount: 10
        )
        let result = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 16_000_000,
                quality: 0.30,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 101
        )

        let decision = try #require(result.decision)
        #expect(decision.targetBitrateBps == 75_000_000)
        #expect(abs(decision.quality - contract.localMotionQualityFloor) < 0.0001)
        #expect(result.streamDecision.cause == .motion)
    }

    @Test("Passive healthy promotion is capped to 25 percent every two seconds")
    func passiveHealthyPromotionIsCapped() throws {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let proposed = makeBudgetDecision(
            targetBitrateBps: 300_000_000,
            quality: 0.80,
            state: .observing,
            reason: .healthy
        )

        let initial = governor.evaluateRuntimeDecision(
            proposed,
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 100
        )
        let promoted = governor.evaluateRuntimeDecision(
            proposed,
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 104
        )

        #expect(try #require(initial.decision).targetBitrateBps == 75_000_000)
        #expect(try #require(promoted.decision).targetBitrateBps == 93_750_000)
    }

    @Test("Recent runtime reduction blocks immediate frame-intent quality raise")
    func recentRuntimeReductionBlocksImmediateFrameIntentRaise() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .vpnOrOverlay)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 32_000_000,
                quality: 0.42,
                state: .severe,
                reason: .encoderLag
            ),
            snapshot: makeSnapshot(mediaPathProfile: .vpnOrOverlay),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 20
        )

        let allowed = governor.allowsFrameIntentQualityWrite(
            targetQuality: 0.80,
            currentQuality: 0.42,
            contract: contract,
            now: 20.5
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.blockedLeverReason == "recent-runtime-reduction")
    }

    @Test("Recent proximity motion pressure blocks frame intent above motion target")
    func recentProximityMotionPressureBlocksFrameIntentAboveMotionTarget() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 20
        )

        let allowed = governor.allowsFrameIntentQualityWrite(
            targetQuality: 0.42,
            currentQuality: contract.localMotionQualityFloor,
            contract: contract,
            now: 20.2
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.blockedLeverReason == "motion-quality-raise-blocked")
    }

    @Test("Proximity motion pressure allows clarity raise after local hold")
    func proximityMotionPressureAllowsClarityRaiseAfterLocalHold() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 20
        )

        let allowed = governor.allowsFrameIntentQualityWrite(
            targetQuality: 0.66,
            currentQuality: contract.localMotionQualityFloor,
            contract: contract,
            now: 20.6
        )

        #expect(allowed)
    }

    @Test("Proximity soft evidence cannot start transport admission skips")
    func proximitySoftEvidenceCannotStartTransportAdmissionSkips() {
        var governor = HostStreamQualityGovernor()
        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                receiverAckLagMs: 220
            ),
            proposedMode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            evidenceLabel: "soft:transport-backlog",
            inputActive: true,
            contract: makeContract(mediaPathProfile: .proximityWiredLike),
            now: 30
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.blockedLeverReason == "soft-local-transport-admission")
    }

    @Test("Proximity input motion at floor protects admission skips")
    func proximityInputMotionAtFloorProtectsAdmissionSkips() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 30
        )

        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .pressured,
                realtimePressureReason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue
            ),
            proposedMode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue,
            evidenceLabel: "pre-encode:encoded-frame",
            inputActive: true,
            contract: contract,
            now: 30.1
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.selectedLever == .observe)
        #expect(governor.latestDecision.blockedLeverReason == "input-cadence-protected")
        #expect(governor.latestDecision.cause == .motion)
    }

    @Test("Proximity passive motion at floor can start admission skips")
    func proximityPassiveMotionAtFloorCanStartAdmissionSkips() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 30
        )

        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .pressured,
                realtimePressureReason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue
            ),
            proposedMode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue,
            evidenceLabel: "pre-encode:encoded-frame",
            inputActive: false,
            contract: contract,
            now: 30.1
        )

        #expect(allowed == true)
        #expect(governor.latestDecision.selectedLever == .admissionSkip)
        #expect(governor.latestDecision.cause == .motion)
    }

    @Test("Proximity input motion pressure blocks transport-named admission at floor")
    func proximityInputMotionPressureBlocksTransportNamedAdmissionAtFloor() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 30
        )

        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .pressured,
                realtimePressureReason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue
            ),
            proposedMode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            evidenceLabel: "soft:transport-backlog",
            inputActive: true,
            contract: contract,
            now: 30.1
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.selectedLever == .observe)
        #expect(governor.latestDecision.blockedLeverReason == "input-cadence-protected")
        #expect(governor.latestDecision.cause == .motion)
    }

    @Test("Proximity hard transport pressure can skip during input")
    func proximityHardTransportPressureCanSkipDuringInput() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)

        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                senderDropHoldActive: true,
                realtimePressureState: .severe,
                realtimePressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
            ),
            proposedMode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            evidenceLabel: "hard:sender-drop",
            inputActive: true,
            contract: contract,
            now: 35
        )

        #expect(allowed)
        #expect(governor.latestDecision.selectedLever == .admissionSkip)
        #expect(governor.latestDecision.cause == .transport)
    }

    @Test("Proximity proposed hard throttle can skip during input")
    func proximityProposedHardThrottleCanSkipDuringInput() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)

        let allowed = governor.allowsTransportAdmissionSkip(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .severe,
                realtimePressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
            ),
            proposedMode: .hardThrottle,
            reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            evidenceLabel: "hard:transport-backlog",
            inputActive: true,
            contract: contract,
            now: 36
        )

        #expect(allowed)
        #expect(governor.latestDecision.selectedLever == .admissionSkip)
        #expect(governor.latestDecision.cause == .transport)
    }

    @Test("Proximity input motion at floor protects cadence")
    func proximityInputMotionAtFloorProtectsCadence() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 40
        )

        let allowed = governor.allowsDynamicCadenceDemotion(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .pressured,
                realtimePressureReason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue
            ),
            inputActive: true,
            contract: contract,
            now: 40.2
        )

        #expect(allowed == false)
        #expect(governor.latestDecision.selectedLever == .observe)
        #expect(governor.latestDecision.blockedLeverReason == "input-cadence-protected")
        #expect(governor.latestDecision.cause == .motion)
    }

    @Test("Proximity passive motion at floor can demote cadence")
    func proximityPassiveMotionAtFloorCanDemoteCadence() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        _ = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.20,
                state: .pressured,
                reason: .encodedFrame
            ),
            snapshot: makeSnapshot(mediaPathProfile: .proximityWiredLike),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 40
        )

        let allowed = governor.allowsDynamicCadenceDemotion(
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                realtimePressureState: .pressured,
                realtimePressureReason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue
            ),
            inputActive: false,
            contract: contract,
            now: 40.2
        )

        #expect(allowed == true)
        #expect(governor.latestDecision.selectedLever == .reduceCadence)
        #expect(governor.latestDecision.cause == .motion)
    }

    @Test("Proximity sustained hard transport pressure can demote cadence during input")
    func proximitySustainedHardTransportPressureCanDemoteCadenceDuringInput() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let snapshot = makeSnapshot(
            mediaPathProfile: .proximityWiredLike,
            senderDropHoldActive: true,
            realtimePressureState: .severe,
            realtimePressureReason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue
        )

        _ = governor.allowsDynamicCadenceDemotion(
            snapshot: snapshot,
            inputActive: true,
            contract: contract,
            now: 50
        )
        let allowed = governor.allowsDynamicCadenceDemotion(
            snapshot: snapshot,
            inputActive: true,
            contract: contract,
            now: 51.1
        )

        #expect(allowed)
        #expect(governor.latestDecision.selectedLever == .reduceCadence)
        #expect(governor.latestDecision.cause == .transport)
    }

    @Test("Presentation-only freeze records recovery diagnostics without bitrate starvation")
    func presentationOnlyFreezeRecordsRecoveryDiagnosticsWithoutBitrateStarvation() {
        var governor = HostStreamQualityGovernor()
        let contract = makeContract(mediaPathProfile: .proximityWiredLike)
        let runtimeResult = governor.evaluateRuntimeDecision(
            makeBudgetDecision(
                targetBitrateBps: 12_000_000,
                quality: 0.32,
                state: .pressured,
                reason: .receiverFreshness
            ),
            snapshot: makeSnapshot(
                mediaPathProfile: .proximityWiredLike,
                receiverPresentationBacklogFrames: 2
            ),
            contract: contract,
            currentBitrateBps: 75_000_000,
            allowsLocalBulkReductionOverride: false,
            now: 40
        )

        #expect(runtimeResult.shouldApply == false)
        #expect(runtimeResult.streamDecision.evidenceClass == .diagnostic)
        #expect(runtimeResult.streamDecision.cause == .presentation)

        let recovery = governor.recordPresentationRecovery(
            contract: contract,
            summary: "presentation-only-freeze",
            now: 40.2
        )

        #expect(recovery.evidenceClass == .diagnostic)
        #expect(recovery.cause == .presentation)
        #expect(recovery.selectedLever == .presentationRecovery)
    }

    private func makeContract(
        mediaPathProfile: MirageMediaPathProfile,
        startupBaseTime: CFAbsoluteTime = 0,
        encodedFrameCount: UInt64 = 120,
        qualityCeiling: Float = 0.80,
        steadyQualityCeiling: Float = 0.80
    ) -> StreamQualityContract {
        StreamQualityContract(
            streamFamily: .desktop,
            encodedWidth: 2752,
            encodedHeight: 2064,
            targetFrameRate: 60,
            streamScale: 1.0,
            codec: .hevc,
            colorDepth: .standard,
            enteredBitrateBps: 300_000_000,
            targetBitrateBps: 75_000_000,
            maximumCeilingBps: 300_000_000,
            latencyMode: .lowestLatency,
            pathKind: mediaPathProfile == .vpnOrOverlay ? .vpn : .awdl,
            mediaPathProfile: mediaPathProfile,
            runtimeOwnership: .host,
            runtimeQualityAdjustmentEnabled: true,
            qualityCeiling: qualityCeiling,
            steadyQualityCeiling: steadyQualityCeiling,
            maxPayloadSize: 1_172,
            startupBaseTime: startupBaseTime,
            encodedFrameCount: encodedFrameCount
        )
    }

    private func makeBudgetDecision(
        targetBitrateBps: Int,
        quality: Float,
        state: HostAdaptivePFrameController.PressureState,
        reason: HostAdaptivePFrameController.Reason
    ) -> HostFrameBudgetDecision {
        let frameBytes = max(1, targetBitrateBps / 8 / 60)
        return HostFrameBudgetDecision(
            targetBitrateBps: targetBitrateBps,
            maxFrameBytes: frameBytes,
            maxWireBytes: frameBytes,
            maxPacketCount: max(1, (frameBytes + 1_171) / 1_172),
            quality: quality,
            qualityCeiling: max(quality, 0.50),
            keyframeQuality: max(quality, 0.50),
            sendDeadline: 10 + 1.0 / 60.0,
            state: state,
            reason: reason
        )
    }

    private func makeSnapshot(
        mediaPathProfile: MirageMediaPathProfile,
        captureCadenceState: HostAdaptiveFrameCoordinator.CaptureCadenceState = .unknown,
        captureCadenceSummary: String? = nil,
        receiverState: HostAdaptiveFrameCoordinator.ReceiverEvidenceState = .healthy,
        receiverReassemblyBacklogFrames: Int = 0,
        receiverReassemblyBacklogBytes: Int = 0,
        receiverDecodeBacklogFrames: Int = 0,
        receiverPresentationBacklogFrames: Int = 0,
        receiverLossHoldActive: Bool = false,
        receiverAckLagMs: Double? = nil,
        senderQueuedBytes: Int = 0,
        senderDropHoldActive: Bool = false,
        unstartedPFrameCount: Int = 0,
        queuedUnreliablePendingPackets: Int = 0,
        queuedUnreliableQueuedBytes: Int = 0,
        realtimePressureState: HostAdaptivePFrameController.PressureState = .observing,
        realtimePressureReason: String? = nil,
        transportAdmissionActiveDuration: CFAbsoluteTime = 0
    ) -> HostAdaptiveFrameCoordinator.TransportPressureSnapshot {
        HostAdaptiveFrameCoordinator.TransportPressureSnapshot(
            mediaPathProfile: mediaPathProfile,
            currentFrameRate: 60,
            captureCadenceState: captureCadenceState,
            captureCadenceSummary: captureCadenceSummary,
            receiverState: receiverState,
            receiverCapacityLearningQuarantineReason: nil,
            receiverReassemblyBacklogFrames: receiverReassemblyBacklogFrames,
            receiverReassemblyBacklogBytes: receiverReassemblyBacklogBytes,
            receiverDecodeBacklogFrames: receiverDecodeBacklogFrames,
            receiverPresentationBacklogFrames: receiverPresentationBacklogFrames,
            receiverLossHoldActive: receiverLossHoldActive,
            receiverAckLagMs: receiverAckLagMs,
            senderQueuedBytes: senderQueuedBytes,
            queuePressureBytes: 1_200_000,
            maxQueuedBytes: 2_000_000,
            senderDropHoldActive: senderDropHoldActive,
            unstartedPFrameCount: unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: 0,
            oldestUnstartedPFrameLatenessMs: 0,
            queuedUnreliablePendingPackets: queuedUnreliablePendingPackets,
            queuedUnreliableOutstandingPackets: 0,
            queuedUnreliableQueuedBytes: queuedUnreliableQueuedBytes,
            queuedUnreliableQueueDwellP99Ms: 0,
            queuedUnreliableSendGapP99Ms: 0,
            queuedUnreliableContentProcessedP99Ms: 0,
            startupProtectionActive: false,
            frameChainRepairActive: false,
            realtimePressureState: realtimePressureState,
            realtimePressureReason: realtimePressureReason,
            transportAdmissionActiveDuration: transportAdmissionActiveDuration
        )
    }
}
#endif
