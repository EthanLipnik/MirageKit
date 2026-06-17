//
//  HostStreamQualityGovernor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

import CoreFoundation
import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
struct StreamQualityContract: Sendable, Equatable {
    enum StreamFamily: String, Sendable, Equatable {
        case window
        case desktop
        case custom
        case appAtlas = "app-atlas"
        case unknown
    }

    enum RuntimeOwnership: String, Sendable, Equatable {
        case host
        case clientLegacy = "client-legacy"
        case fixed
    }

    let streamFamily: StreamFamily
    let encodedWidth: Int
    let encodedHeight: Int
    let targetFrameRate: Int
    let streamScale: Double
    let codec: MirageVideoCodec
    let colorDepth: MirageStreamColorDepth
    let enteredBitrateBps: Int?
    let targetBitrateBps: Int?
    let maximumCeilingBps: Int?
    let latencyMode: MirageStreamLatencyMode
    let pathKind: MirageNetworkPathKind
    let mediaPathProfile: MirageMediaPathProfile
    let runtimeOwnership: RuntimeOwnership
    let runtimeQualityAdjustmentEnabled: Bool
    let qualityCeiling: Float
    let steadyQualityCeiling: Float
    let maxPayloadSize: Int
    let startupBaseTime: CFAbsoluteTime
    let encodedFrameCount: UInt64

    func startupWarmupActive(now: CFAbsoluteTime) -> Bool {
        guard startupBaseTime > 0 else { return encodedFrameCount < 90 }
        return now - startupBaseTime < 2.0 || encodedFrameCount < 90
    }

    var localReadabilityQualityFloor: Float {
        mediaPathProfile.usesLocalBulkTransportPolicy ? 0.66 : 0.0
    }

    var localMotionQualityFloor: Float {
        mediaPathProfile.usesLocalBulkTransportPolicy ? 0.35 : 0.0
    }

    func readabilityFloorBitrateBps() -> Int? {
        floorBitrateBps(forFrameQuality: localReadabilityQualityFloor)
    }

    func motionFloorBitrateBps() -> Int? {
        floorBitrateBps(forFrameQuality: localMotionQualityFloor)
    }

    private func floorBitrateBps(forFrameQuality quality: Float) -> Int? {
        guard quality > 0,
              encodedWidth > 0,
              encodedHeight > 0 else {
            return nil
        }
        let ceiling = maximumCeilingBps ?? 1_000_000_000
        return MirageBitrateQualityMapper.targetBitrateBps(
            forFrameQuality: quality,
            width: encodedWidth,
            height: encodedHeight,
            frameRate: targetFrameRate,
            maxBitrateBps: max(1, ceiling)
        )
    }

    static func family(for streamKind: VideoEncoder.StreamKind) -> StreamFamily {
        switch streamKind {
        case .window:
            return .window
        case .desktop:
            return .desktop
        case .custom:
            return .custom
        case .appAtlas:
            return .appAtlas
        }
    }
}

struct StreamQualityDecision: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case startupWarmup = "startup-warmup"
        case settling
        case normal
        case pressure
        case recovery
        case cooldown
    }

    enum EvidenceClass: String, Sendable, Equatable {
        case healthy
        case hard
        case soft
        case diagnostic
    }

    enum Cause: String, Sendable, Equatable {
        case healthy
        case startup
        case transport
        case receiver
        case encoder
        case presentation
        case motion
        case unknown
    }

    enum Lever: String, Sendable, Equatable {
        case observe
        case promoteBitrate = "promote-bitrate"
        case reduceBitrate = "reduce-bitrate"
        case reduceQuality = "reduce-quality"
        case admissionSkip = "admission-skip"
        case reduceCadence = "reduce-cadence"
        case reduceScale = "reduce-scale"
        case keyframeRecovery = "keyframe-recovery"
        case presentationRecovery = "presentation-recovery"
    }

    let id: UInt64
    let state: State
    let evidenceClass: EvidenceClass
    let cause: Cause
    let selectedLever: Lever
    let blockedLeverReason: String?
    let targetBitrateBps: Int?
    let qualityTarget: Float?
    let frameAdmissionMode: String?
    let targetFrameRate: Int?
    let streamScale: Double?
    let evidenceSummary: String

    static let initial = StreamQualityDecision(
        id: 0,
        state: .startupWarmup,
        evidenceClass: .healthy,
        cause: .startup,
        selectedLever: .observe,
        blockedLeverReason: nil,
        targetBitrateBps: nil,
        qualityTarget: nil,
        frameAdmissionMode: nil,
        targetFrameRate: nil,
        streamScale: nil,
        evidenceSummary: "initial"
    )
}

struct HostStreamQualityGovernor: Sendable, Equatable {
    private static let localMotionQualityRaiseHoldSeconds: CFAbsoluteTime = 0.50
    private static let localRuntimeReductionQualityRaiseHoldSeconds: CFAbsoluteTime = 0.50
    private static let remoteRuntimeReductionQualityRaiseHoldSeconds: CFAbsoluteTime = 1.00

    struct RuntimeDecisionResult: Sendable, Equatable {
        let decision: HostFrameBudgetDecision?
        let streamDecision: StreamQualityDecision

        var shouldApply: Bool {
            decision != nil
        }
    }

    private struct Evidence: Sendable, Equatable {
        let evidenceClass: StreamQualityDecision.EvidenceClass
        let cause: StreamQualityDecision.Cause
        let summary: String
        let hardTransport: Bool
        let hardReceiver: Bool
        let hardEncoder: Bool
        let softOnly: Bool
    }

    private var startedAt: CFAbsoluteTime = 0
    private var nextDecisionID: UInt64 = 1
    private var healthySince: CFAbsoluteTime = 0
    private var lastHardEvidenceTime: CFAbsoluteTime = 0
    private var hardEvidenceStartedAt: CFAbsoluteTime = 0
    private var senderOverLimitStartedAt: CFAbsoluteTime = 0
    private var senderOverLimitSampleCount = 0
    private var motionPressureStartedAt: CFAbsoluteTime = 0
    private var lastMotionPressureTime: CFAbsoluteTime = 0
    private var latestMotionQualityTarget: Float?
    private var lastPassivePromotionTime: CFAbsoluteTime = 0
    private var lastRuntimeReductionTime: CFAbsoluteTime = 0
    private(set) var latestDecision: StreamQualityDecision = .initial

    mutating func configureIfNeeded(contract: StreamQualityContract, now: CFAbsoluteTime) {
        guard startedAt <= 0 else { return }
        startedAt = now
        healthySince = now
        latestDecision = makeDecision(
            state: contract.startupWarmupActive(now: now) ? .startupWarmup : .settling,
            evidenceClass: .healthy,
            cause: .startup,
            selectedLever: .observe,
            blockedLeverReason: nil,
            targetBitrateBps: contract.targetBitrateBps,
            qualityTarget: nil,
            frameAdmissionMode: nil,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale,
            evidenceSummary: "configured",
            incrementsID: false
        )
    }

    mutating func evaluateRuntimeDecision(
        _ decision: HostFrameBudgetDecision,
        snapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        contract: StreamQualityContract,
        currentBitrateBps: Int?,
        allowsLocalBulkReductionOverride: Bool,
        now: CFAbsoluteTime
    ) -> RuntimeDecisionResult {
        configureIfNeeded(contract: contract, now: now)
        let evidence = classify(snapshot: snapshot, decision: decision, contract: contract, now: now)
        let state = governorState(
            for: decision.state,
            evidence: evidence,
            contract: contract,
            now: now
        )

        if decision.state == .observing {
            let adjusted = adjustedHealthyDecision(
                decision,
                evidence: evidence,
                contract: contract,
                currentBitrateBps: currentBitrateBps,
                now: now
            )
            let lever: StreamQualityDecision.Lever = adjusted.targetBitrateBps > (currentBitrateBps ?? 0)
                ? .promoteBitrate
                : .observe
            let streamDecision = recordDecision(
                state: state,
                evidence: evidence,
                selectedLever: lever,
                blockedLeverReason: nil,
                targetBitrateBps: adjusted.targetBitrateBps,
                qualityTarget: adjusted.quality,
                frameAdmissionMode: nil,
                targetFrameRate: contract.targetFrameRate,
                streamScale: contract.streamScale
            )
            return RuntimeDecisionResult(decision: adjusted, streamDecision: streamDecision)
        }

        if shouldObserveOnly(
            decision: decision,
            evidence: evidence,
            contract: contract,
            now: now,
            allowsLocalBulkReductionOverride: allowsLocalBulkReductionOverride
        ) {
            let streamDecision = recordDecision(
                state: state,
                evidence: evidence,
                selectedLever: .observe,
                blockedLeverReason: blockedReason(
                    decision: decision,
                    evidence: evidence,
                    contract: contract,
                    now: now
                ),
                targetBitrateBps: currentBitrateBps,
                qualityTarget: nil,
                frameAdmissionMode: nil,
                targetFrameRate: contract.targetFrameRate,
                streamScale: contract.streamScale
            )
            return RuntimeDecisionResult(decision: nil, streamDecision: streamDecision)
        }

        let adjusted = adjustedReductionDecision(
            decision,
            evidence: evidence,
            contract: contract,
            currentBitrateBps: currentBitrateBps
        )
        if adjusted.targetBitrateBps < (currentBitrateBps ?? adjusted.targetBitrateBps) ||
            adjusted.quality < contract.qualityCeiling ||
            evidence.cause == .motion {
            lastRuntimeReductionTime = now
        }
        if evidence.cause == .motion {
            latestMotionQualityTarget = adjusted.quality
        }
        let streamDecision = recordDecision(
            state: state,
            evidence: evidence,
            selectedLever: adjusted.targetBitrateBps < (currentBitrateBps ?? adjusted.targetBitrateBps)
                ? .reduceBitrate
                : .reduceQuality,
            blockedLeverReason: adjusted.targetBitrateBps > decision.targetBitrateBps
                ? (evidence.cause == .motion ? "motion-floor" : "readability-floor")
                : nil,
            targetBitrateBps: adjusted.targetBitrateBps,
            qualityTarget: adjusted.quality,
            frameAdmissionMode: nil,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale
        )
        return RuntimeDecisionResult(decision: adjusted, streamDecision: streamDecision)
    }

    mutating func allowsTransportAdmissionSkip(
        snapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        proposedMode: HostTransportFrameAdmissionPolicy.Mode,
        reason: String?,
        evidenceLabel: String?,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> Bool {
        configureIfNeeded(contract: contract, now: now)
        guard proposedMode != .normal else { return true }
        let evidence = classify(
            snapshot: snapshot,
            decision: nil,
            contract: contract,
            now: now,
            reason: reason ?? evidenceLabel
        )
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy || snapshot.frameChainRepairActive {
            recordAdmissionDecision(
                evidence: evidence,
                contract: contract,
                mode: proposedMode,
                reason: reason,
                evidenceLabel: evidenceLabel,
                blockedReason: nil,
                now: now
            )
            return true
        }
        let localMotionCadenceAllowed = snapshot.mediaPathProfile.usesLocalBulkTransportPolicy &&
            evidence.cause == .motion &&
            motionCadenceReliefAllowed(contract: contract, now: now)
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy &&
            !evidence.hardTransport &&
            !localMotionCadenceAllowed {
            recordAdmissionDecision(
                evidence: evidence,
                contract: contract,
                mode: proposedMode,
                reason: reason,
                evidenceLabel: evidenceLabel,
                blockedReason: "soft-local-transport-admission",
                now: now
            )
            return false
        }
        let allowed = evidence.evidenceClass == .hard ||
            proposedMode == .hardThrottle ||
            localMotionCadenceAllowed
        recordAdmissionDecision(
            evidence: evidence,
            contract: contract,
            mode: proposedMode,
            reason: reason,
            evidenceLabel: evidenceLabel,
            blockedReason: allowed ? nil : "soft-transport-admission",
            now: now
        )
        return allowed
    }

    mutating func allowsDynamicCadenceDemotion(
        snapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> Bool {
        configureIfNeeded(contract: contract, now: now)
        guard !snapshot.mediaPathProfile.usesAwdlRadioPolicy else { return true }
        let evidence = classify(snapshot: snapshot, decision: nil, contract: contract, now: now)
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            let motionAllowed = evidence.cause == .motion &&
                motionCadenceReliefAllowed(contract: contract, now: now)
            let allowed = (evidence.hardTransport && hardEvidenceDuration(now: now) >= 1.0) ||
                motionAllowed
            recordStructuralDecision(
                evidence: evidence,
                contract: contract,
                lever: .reduceCadence,
                blockedReason: allowed ? nil : "cadence-demotion-requires-hard-or-motion-floor",
                now: now
            )
            return allowed
        }
        return evidence.evidenceClass == .hard || evidence.evidenceClass == .soft
    }

    mutating func recordMotionFloorSaturation(
        contract: StreamQualityContract,
        summary: String,
        now: CFAbsoluteTime
    ) {
        configureIfNeeded(contract: contract, now: now)
        noteMotionPressure(now: now)
        latestMotionQualityTarget = contract.localMotionQualityFloor
        latestDecision = makeDecision(
            state: .pressure,
            evidenceClass: .soft,
            cause: .motion,
            selectedLever: .reduceCadence,
            blockedLeverReason: nil,
            targetBitrateBps: contract.targetBitrateBps,
            qualityTarget: contract.localMotionQualityFloor,
            frameAdmissionMode: HostTransportFrameAdmissionPolicy.Mode.softThrottle.rawValue,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale,
            evidenceSummary: summary
        )
    }

    mutating func allowsStructuralScaleDemotion(
        snapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> Bool {
        configureIfNeeded(contract: contract, now: now)
        guard !snapshot.mediaPathProfile.usesAwdlRadioPolicy else { return true }
        let evidence = classify(snapshot: snapshot, decision: nil, contract: contract, now: now)
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            let allowed = evidence.hardTransport && hardEvidenceDuration(now: now) >= 5.0
            recordStructuralDecision(
                evidence: evidence,
                contract: contract,
                lever: .reduceScale,
                blockedReason: allowed ? nil : "scale-demotion-requires-5s-hard-evidence",
                now: now
            )
            return allowed
        }
        return evidence.evidenceClass == .hard && hardEvidenceDuration(now: now) >= 2.0
    }

    mutating func allowsFrameIntentQualityWrite(
        targetQuality: Float,
        currentQuality: Float,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> Bool {
        configureIfNeeded(contract: contract, now: now)
        guard targetQuality > currentQuality else { return true }
        if contract.mediaPathProfile.usesLocalBulkTransportPolicy,
           lastMotionPressureTime > 0,
           now - lastMotionPressureTime < Self.localMotionQualityRaiseHoldSeconds,
           let latestMotionQualityTarget,
           targetQuality > max(latestMotionQualityTarget, contract.localMotionQualityFloor) + 0.001 {
            latestDecision = makeDecision(
                state: latestDecision.state,
                evidenceClass: latestDecision.evidenceClass,
                cause: latestDecision.cause,
                selectedLever: .observe,
                blockedLeverReason: "motion-quality-raise-blocked",
                targetBitrateBps: contract.targetBitrateBps,
                qualityTarget: currentQuality,
                frameAdmissionMode: nil,
                targetFrameRate: contract.targetFrameRate,
                streamScale: contract.streamScale,
                evidenceSummary: latestDecision.evidenceSummary
            )
            return false
        }
        let runtimeReductionHoldSeconds = contract.mediaPathProfile.usesLocalBulkTransportPolicy
            ? Self.localRuntimeReductionQualityRaiseHoldSeconds
            : Self.remoteRuntimeReductionQualityRaiseHoldSeconds
        guard now - lastRuntimeReductionTime >= runtimeReductionHoldSeconds else {
            latestDecision = makeDecision(
                state: latestDecision.state,
                evidenceClass: latestDecision.evidenceClass,
                cause: latestDecision.cause,
                selectedLever: .observe,
                blockedLeverReason: "recent-runtime-reduction",
                targetBitrateBps: contract.targetBitrateBps,
                qualityTarget: currentQuality,
                frameAdmissionMode: nil,
                targetFrameRate: contract.targetFrameRate,
                streamScale: contract.streamScale,
                evidenceSummary: latestDecision.evidenceSummary
            )
            return false
        }
        if latestDecision.state == .pressure || latestDecision.state == .recovery {
            latestDecision = makeDecision(
                state: latestDecision.state,
                evidenceClass: latestDecision.evidenceClass,
                cause: latestDecision.cause,
                selectedLever: .observe,
                blockedLeverReason: "pressure-quality-raise-blocked",
                targetBitrateBps: contract.targetBitrateBps,
                qualityTarget: currentQuality,
                frameAdmissionMode: nil,
                targetFrameRate: contract.targetFrameRate,
                streamScale: contract.streamScale,
                evidenceSummary: latestDecision.evidenceSummary
            )
            return false
        }
        return true
    }

    @discardableResult
    mutating func recordPresentationRecovery(
        contract: StreamQualityContract,
        summary: String,
        now: CFAbsoluteTime
    ) -> StreamQualityDecision {
        configureIfNeeded(contract: contract, now: now)
        latestDecision = makeDecision(
            state: latestDecision.state,
            evidenceClass: .diagnostic,
            cause: .presentation,
            selectedLever: .presentationRecovery,
            blockedLeverReason: nil,
            targetBitrateBps: contract.targetBitrateBps,
            qualityTarget: nil,
            frameAdmissionMode: nil,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale,
            evidenceSummary: summary
        )
        return latestDecision
    }

    private mutating func adjustedHealthyDecision(
        _ decision: HostFrameBudgetDecision,
        evidence: Evidence,
        contract: StreamQualityContract,
        currentBitrateBps: Int?,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        guard decision.reason == .healthy,
              evidence.evidenceClass != .hard,
              let currentBitrateBps,
              decision.targetBitrateBps > currentBitrateBps else {
            return decision
        }
        guard now - healthySince >= 3.0,
              now - lastPassivePromotionTime >= 2.0,
              (lastMotionPressureTime <= 0 || now - lastMotionPressureTime >= 2.0) else {
            return replacingBudget(
                decision,
                targetBitrateBps: currentBitrateBps,
                quality: decision.quality,
                qualityCeiling: decision.qualityCeiling,
                keyframeQuality: decision.keyframeQuality,
                contract: contract
            )
        }
        let ceiling = contract.maximumCeilingBps ?? decision.targetBitrateBps
        let promoted = min(
            decision.targetBitrateBps,
            ceiling,
            max(currentBitrateBps + 1, Int((Double(currentBitrateBps) * 1.25).rounded(.up)))
        )
        if promoted > currentBitrateBps {
            lastPassivePromotionTime = now
        }
        return replacingBudget(
            decision,
            targetBitrateBps: promoted,
            quality: decision.quality,
            qualityCeiling: decision.qualityCeiling,
            keyframeQuality: decision.keyframeQuality,
            contract: contract
        )
    }

    private func adjustedReductionDecision(
        _ decision: HostFrameBudgetDecision,
        evidence: Evidence,
        contract: StreamQualityContract,
        currentBitrateBps: Int?
    ) -> HostFrameBudgetDecision {
        guard contract.mediaPathProfile.usesLocalBulkTransportPolicy else {
            return decision
        }
        let floorQuality = localQualityFloor(evidence: evidence, contract: contract)
        guard floorQuality > 0 else { return decision }
        let floorBitrate = localFloorBitrateBps(evidence: evidence, contract: contract)
        let targetBitrateBps = if evidence.cause == .motion,
                                  evidence.softOnly,
                                  !evidence.hardTransport,
                                  !evidence.hardReceiver,
                                  !evidence.hardEncoder,
                                  let currentBitrateBps {
            max(currentBitrateBps, floorBitrate ?? currentBitrateBps)
        } else {
            max(decision.targetBitrateBps, floorBitrate ?? decision.targetBitrateBps)
        }
        let effectiveSteadyCeiling = max(contract.steadyQualityCeiling, floorQuality)
        let adjustedQuality = min(
            effectiveSteadyCeiling,
            max(floorQuality, decision.quality)
        )
        let qualityCeiling = max(decision.qualityCeiling, adjustedQuality)
        guard targetBitrateBps != decision.targetBitrateBps ||
            adjustedQuality != decision.quality ||
            qualityCeiling != decision.qualityCeiling ||
            decision.keyframeQuality < adjustedQuality else {
            return decision
        }
        return replacingBudget(
            decision,
            targetBitrateBps: targetBitrateBps,
            quality: min(qualityCeiling, adjustedQuality),
            qualityCeiling: qualityCeiling,
            keyframeQuality: max(decision.keyframeQuality, adjustedQuality),
            contract: contract
        )
    }

    private func shouldObserveOnly(
        decision: HostFrameBudgetDecision,
        evidence: Evidence,
        contract: StreamQualityContract,
        now: CFAbsoluteTime,
        allowsLocalBulkReductionOverride: Bool
    ) -> Bool {
        if decision.state == .observing { return false }
        if allowsLocalBulkReductionOverride { return false }
        if contract.codec == .proRes4444 { return false }
        if contract.startupWarmupActive(now: now) && evidence.evidenceClass != .hard {
            return true
        }
        guard contract.mediaPathProfile.usesLocalBulkTransportPolicy else {
            return false
        }
        if decision.reason == .encoderLag && (evidence.hardEncoder || evidence.evidenceClass == .hard) {
            return false
        }
        if evidence.cause == .motion {
            return false
        }
        return !evidence.hardTransport && !evidence.hardReceiver && !evidence.hardEncoder
    }

    private func blockedReason(
        decision: HostFrameBudgetDecision,
        evidence: Evidence,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> String {
        if contract.startupWarmupActive(now: now) && evidence.evidenceClass != .hard {
            return "startup-warmup"
        }
        if contract.mediaPathProfile.usesLocalBulkTransportPolicy {
            return "soft-local-\(decision.reason.rawValue)"
        }
        return "observe-only-\(decision.reason.rawValue)"
    }

    private mutating func classify(
        snapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        decision: HostFrameBudgetDecision?,
        contract: StreamQualityContract,
        now: CFAbsoluteTime,
        reason: String? = nil
    ) -> Evidence {
        let senderOverLimit = snapshot.senderQueuedBytes >= snapshot.maxQueuedBytes
        if senderOverLimit {
            if senderOverLimitStartedAt <= 0 { senderOverLimitStartedAt = now }
            senderOverLimitSampleCount += 1
        } else {
            senderOverLimitStartedAt = 0
            senderOverLimitSampleCount = 0
        }

        let senderOverLimitHard = senderOverLimit &&
            (senderOverLimitSampleCount >= 2 || now - senderOverLimitStartedAt >= 0.5)
        let hardSender = snapshot.senderDropHoldActive ||
            senderOverLimitHard ||
            snapshot.queuedUnreliableQueuedBytes >= snapshot.queuePressureBytes ||
            snapshot.queuedUnreliablePendingPackets >= 32 ||
            snapshot.packetPacerFrameMaxSleepMs >= max(
                250,
                1_000.0 / Double(max(1, snapshot.currentFrameRate)) * 8.0
            )
        let hardReceiver = snapshot.receiverLossHoldActive ||
            snapshot.receiverReassemblyBacklogFrames >= 4 ||
            snapshot.receiverReassemblyBacklogBytes >= 2_000_000
        let hardEncoder = decision?.reason == .encoderLag &&
            (decision?.state == .severe || decision?.state == .recovery)
        if hardSender || hardReceiver || hardEncoder {
            noteHardEvidence(now: now)
            if hardSender {
                return Evidence(
                    evidenceClass: .hard,
                    cause: .transport,
                    summary: "hard-sender",
                    hardTransport: true,
                    hardReceiver: hardReceiver,
                    hardEncoder: hardEncoder,
                    softOnly: false
                )
            }
            return Evidence(
                evidenceClass: .hard,
                cause: hardEncoder ? .encoder : .receiver,
                summary: hardEncoder ? "hard-encoder" : "hard-receiver",
                hardTransport: false,
                hardReceiver: hardReceiver,
                hardEncoder: hardEncoder,
                softOnly: false
            )
        }

        let explicitMotionComplexity = decision?.reason == .encodedFrame ||
            decision?.reason == .motionOnset ||
            reasonIndicatesMotionComplexity(reason ?? snapshot.realtimePressureReason)
        let presentationOnly = !explicitMotionComplexity &&
            snapshot.receiverPresentationBacklogFrames > 0 &&
            snapshot.receiverReassemblyBacklogFrames == 0 &&
            snapshot.receiverReassemblyBacklogBytes == 0 &&
            !snapshot.receiverLossHoldActive &&
            !snapshot.senderDropHoldActive &&
            snapshot.senderQueuedBytes < snapshot.queuePressureBytes
        if presentationOnly {
            noteSoftOrHealthy(now: now)
            return Evidence(
                evidenceClass: .diagnostic,
                cause: .presentation,
                summary: "presentation-only",
                hardTransport: false,
                hardReceiver: false,
                hardEncoder: false,
                softOnly: true
            )
        }

        let softSenderTransport = snapshot.unstartedPFrameCount >= 2 ||
            snapshot.oldestUnstartedPFrameAgeMs >= 1_000.0 / Double(max(1, snapshot.currentFrameRate)) * 2.0 ||
            snapshot.queuedUnreliablePendingPackets >= 8 ||
            snapshot.queuedUnreliableQueueDwellP99Ms >= 120 ||
            decision?.reason == .transportBacklog ||
            decision?.reason == .senderDeadline
        let softReceiver = (snapshot.receiverAckLagMs ?? 0) >= 120 ||
            snapshot.receiverDecodeBacklogFrames > 0 ||
            snapshot.receiverReassemblyBacklogFrames > 0 ||
            snapshot.receiverReassemblyBacklogBytes > 0 ||
            decision?.reason == .pFrameLatency ||
            decision?.reason == .receiverFreshness ||
            decision?.reason == .receiverBacklog
        let softPresentation = snapshot.receiverPresentationBacklogFrames > 0
        if softSenderTransport || softReceiver || softPresentation || explicitMotionComplexity {
            if explicitMotionComplexity {
                noteMotionPressure(now: now)
            } else {
                noteSoftOrHealthy(now: now)
            }
            let cause: StreamQualityDecision.Cause = if explicitMotionComplexity {
                .motion
            } else if softReceiver {
                .receiver
            } else if softPresentation {
                .presentation
            } else {
                .transport
            }
            let summaryReason = decision?.reason.rawValue ??
                reason ??
                snapshot.realtimePressureReason ??
                cause.rawValue
            return Evidence(
                evidenceClass: .soft,
                cause: cause,
                summary: "soft-\(summaryReason)",
                hardTransport: false,
                hardReceiver: false,
                hardEncoder: false,
                softOnly: true
            )
        }

        noteSoftOrHealthy(now: now)
        return Evidence(
            evidenceClass: .healthy,
            cause: contract.startupWarmupActive(now: now) ? .startup : .healthy,
            summary: "healthy",
            hardTransport: false,
            hardReceiver: false,
            hardEncoder: false,
            softOnly: false
        )
    }

    private mutating func noteHardEvidence(now: CFAbsoluteTime) {
        lastHardEvidenceTime = now
        healthySince = 0
        if hardEvidenceStartedAt <= 0 {
            hardEvidenceStartedAt = now
        }
    }

    private func localQualityFloor(
        evidence: Evidence,
        contract: StreamQualityContract
    ) -> Float {
        evidence.cause == .motion
            ? contract.localMotionQualityFloor
            : contract.localReadabilityQualityFloor
    }

    private func localFloorBitrateBps(
        evidence: Evidence,
        contract: StreamQualityContract
    ) -> Int? {
        evidence.cause == .motion
            ? contract.motionFloorBitrateBps()
            : contract.readabilityFloorBitrateBps()
    }

    private func motionCadenceReliefAllowed(
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> Bool {
        guard contract.localMotionQualityFloor > 0,
              lastMotionPressureTime > 0,
              now - lastMotionPressureTime <= 2.0 else {
            return false
        }
        let latestQuality = latestMotionQualityTarget ?? latestDecision.qualityTarget ?? contract.qualityCeiling
        return latestQuality <= contract.localMotionQualityFloor + 0.03
    }

    private func reasonIndicatesMotionComplexity(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == HostAdaptivePFrameController.Reason.encodedFrame.rawValue ||
            reason == HostAdaptivePFrameController.Reason.motionOnset.rawValue ||
            reason.contains("encoded-frame") ||
            reason.contains("motion-onset")
    }

    private mutating func noteSoftOrHealthy(now: CFAbsoluteTime) {
        if healthySince <= 0 {
            healthySince = now
        }
        if lastHardEvidenceTime <= 0 || now - lastHardEvidenceTime > 1.0 {
            hardEvidenceStartedAt = 0
        }
    }

    private mutating func noteMotionPressure(now: CFAbsoluteTime) {
        if motionPressureStartedAt <= 0 || now - lastMotionPressureTime > 2.0 {
            motionPressureStartedAt = now
        }
        lastMotionPressureTime = now
        noteSoftOrHealthy(now: now)
    }

    private func hardEvidenceDuration(now: CFAbsoluteTime) -> CFAbsoluteTime {
        guard hardEvidenceStartedAt > 0 else { return 0 }
        return max(0, now - hardEvidenceStartedAt)
    }

    private func governorState(
        for pressureState: HostAdaptivePFrameController.PressureState,
        evidence: Evidence,
        contract: StreamQualityContract,
        now: CFAbsoluteTime
    ) -> StreamQualityDecision.State {
        if contract.startupWarmupActive(now: now) { return .startupWarmup }
        if now - startedAt < 5.0 { return .settling }
        if pressureState == .recovery { return .recovery }
        if evidence.evidenceClass == .hard || pressureState == .severe || pressureState == .pressured {
            return .pressure
        }
        if lastHardEvidenceTime > 0 && now - lastHardEvidenceTime < 3.0 {
            return .cooldown
        }
        return .normal
    }

    private func replacingBudget(
        _ decision: HostFrameBudgetDecision,
        targetBitrateBps: Int,
        quality: Float,
        qualityCeiling: Float,
        keyframeQuality: Float,
        contract: StreamQualityContract
    ) -> HostFrameBudgetDecision {
        let wireBytes = max(
            1,
            Int((Double(max(1, targetBitrateBps)) / 8.0 / Double(max(1, contract.targetFrameRate))).rounded(.down))
        )
        let packetCount = max(1, Int(ceil(Double(wireBytes) / Double(max(1, contract.maxPayloadSize)))))
        return HostFrameBudgetDecision(
            targetBitrateBps: targetBitrateBps,
            maxFrameBytes: wireBytes,
            maxWireBytes: wireBytes,
            maxPacketCount: packetCount,
            quality: quality,
            qualityCeiling: qualityCeiling,
            keyframeQuality: keyframeQuality,
            sendDeadline: decision.sendDeadline,
            state: decision.state,
            reason: decision.reason
        )
    }

    @discardableResult
    private mutating func recordAdmissionDecision(
        evidence: Evidence,
        contract: StreamQualityContract,
        mode: HostTransportFrameAdmissionPolicy.Mode,
        reason: String?,
        evidenceLabel: String?,
        blockedReason: String?,
        now _: CFAbsoluteTime
    ) -> StreamQualityDecision {
        recordDecision(
            state: latestDecision.state,
            evidence: evidence,
            selectedLever: blockedReason == nil ? .admissionSkip : .observe,
            blockedLeverReason: blockedReason,
            targetBitrateBps: contract.targetBitrateBps,
            qualityTarget: nil,
            frameAdmissionMode: mode.rawValue,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale,
            evidenceSummary: evidenceLabel ?? reason ?? evidence.summary
        )
    }

    @discardableResult
    private mutating func recordStructuralDecision(
        evidence: Evidence,
        contract: StreamQualityContract,
        lever: StreamQualityDecision.Lever,
        blockedReason: String?,
        now _: CFAbsoluteTime
    ) -> StreamQualityDecision {
        recordDecision(
            state: latestDecision.state,
            evidence: evidence,
            selectedLever: blockedReason == nil ? lever : .observe,
            blockedLeverReason: blockedReason,
            targetBitrateBps: contract.targetBitrateBps,
            qualityTarget: nil,
            frameAdmissionMode: nil,
            targetFrameRate: contract.targetFrameRate,
            streamScale: contract.streamScale
        )
    }

    @discardableResult
    private mutating func recordDecision(
        state: StreamQualityDecision.State,
        evidence: Evidence,
        selectedLever: StreamQualityDecision.Lever,
        blockedLeverReason: String?,
        targetBitrateBps: Int?,
        qualityTarget: Float?,
        frameAdmissionMode: String?,
        targetFrameRate: Int?,
        streamScale: Double?,
        evidenceSummary: String? = nil
    ) -> StreamQualityDecision {
        latestDecision = makeDecision(
            state: state,
            evidenceClass: evidence.evidenceClass,
            cause: evidence.cause,
            selectedLever: selectedLever,
            blockedLeverReason: blockedLeverReason,
            targetBitrateBps: targetBitrateBps,
            qualityTarget: qualityTarget,
            frameAdmissionMode: frameAdmissionMode,
            targetFrameRate: targetFrameRate,
            streamScale: streamScale,
            evidenceSummary: evidenceSummary ?? evidence.summary
        )
        return latestDecision
    }

    private mutating func makeDecision(
        state: StreamQualityDecision.State,
        evidenceClass: StreamQualityDecision.EvidenceClass,
        cause: StreamQualityDecision.Cause,
        selectedLever: StreamQualityDecision.Lever,
        blockedLeverReason: String?,
        targetBitrateBps: Int?,
        qualityTarget: Float?,
        frameAdmissionMode: String?,
        targetFrameRate: Int?,
        streamScale: Double?,
        evidenceSummary: String,
        incrementsID: Bool = true
    ) -> StreamQualityDecision {
        let id = incrementsID ? nextDecisionID : 0
        if incrementsID {
            nextDecisionID &+= 1
        }
        return StreamQualityDecision(
            id: id,
            state: state,
            evidenceClass: evidenceClass,
            cause: cause,
            selectedLever: selectedLever,
            blockedLeverReason: blockedLeverReason,
            targetBitrateBps: targetBitrateBps,
            qualityTarget: qualityTarget,
            frameAdmissionMode: frameAdmissionMode,
            targetFrameRate: targetFrameRate,
            streamScale: streamScale,
            evidenceSummary: evidenceSummary
        )
    }
}
#endif
