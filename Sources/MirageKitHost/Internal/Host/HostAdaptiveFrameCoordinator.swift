//
//  HostAdaptiveFrameCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/16/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostAdaptiveFrameCoordinator: Sendable, Equatable {
    enum FrameIntent: String, Sendable, Equatable {
        case bootstrapKeyframe = "bootstrap-keyframe"
        case recoveryKeyframe = "recovery-keyframe"
        case realtimeMotion = "realtime-motion"
        case clarityRefresh = "clarity-refresh"
        case probe
        case idleSkip = "idle-skip"
    }

    enum FrameAction: String, Sendable, Equatable {
        case skip
        case encodePFrame = "encode-p-frame"
        case encodeKeyframe = "encode-keyframe"
    }

    enum ReceiverEvidenceState: String, Sendable, Equatable {
        case healthy
        case pressured
        case severe
        case unknown
    }

    enum Lane: String, Sendable, Equatable {
        case realtime
        case clarity
        case recovery
        case bootstrap
    }

    enum DeadlineClass: String, Sendable, Equatable {
        case realtime
        case relaxed
        case recovery
        case none
    }

    enum KeyframeBarrierKind: String, Sendable, Equatable {
        case bootstrap
        case recovery
        case reconfiguration
    }

    struct FrameInput: Sendable, Equatable {
        let forceKeyframe: Bool
        let hasSentKeyframe: Bool
        let pendingKeyframeReason: String?
        let frameChainRepairActive: Bool
        let isIdleFrame: Bool
        let dirtyPercentage: Float
        let sourceStill: Bool
        let inputActive: Bool
        let admitsStillQualityProbe: Bool
        let senderQueuedBytes: Int
        let queuePressureBytes: Int
        let maxQueuedBytes: Int
        let receiverState: ReceiverEvidenceState
        let currentQuality: Float
        let qualityFloor: Float
        let qualityCeiling: Float
        let mediaPathProfile: MirageMediaPathProfile
        let now: CFAbsoluteTime

        init(
            forceKeyframe: Bool,
            hasSentKeyframe: Bool,
            pendingKeyframeReason: String?,
            frameChainRepairActive: Bool,
            isIdleFrame: Bool,
            dirtyPercentage: Float,
            sourceStill: Bool,
            inputActive: Bool,
            admitsStillQualityProbe: Bool,
            senderQueuedBytes: Int,
            queuePressureBytes: Int,
            maxQueuedBytes: Int,
            receiverState: ReceiverEvidenceState,
            currentQuality: Float,
            qualityFloor: Float,
            qualityCeiling: Float,
            mediaPathProfile: MirageMediaPathProfile,
            now: CFAbsoluteTime
        ) {
            self.forceKeyframe = forceKeyframe
            self.hasSentKeyframe = hasSentKeyframe
            self.pendingKeyframeReason = pendingKeyframeReason
            self.frameChainRepairActive = frameChainRepairActive
            self.isIdleFrame = isIdleFrame
            self.dirtyPercentage = max(0, dirtyPercentage)
            self.sourceStill = sourceStill
            self.inputActive = inputActive
            self.admitsStillQualityProbe = admitsStillQualityProbe
            self.senderQueuedBytes = max(0, senderQueuedBytes)
            self.queuePressureBytes = max(1, queuePressureBytes)
            self.maxQueuedBytes = max(self.queuePressureBytes, maxQueuedBytes)
            self.receiverState = receiverState
            self.currentQuality = max(0, currentQuality)
            self.qualityFloor = max(0, qualityFloor)
            self.qualityCeiling = max(0, qualityCeiling)
            self.mediaPathProfile = mediaPathProfile
            self.now = now
        }
    }

    struct FrameDecision: Sendable, Equatable {
        let intent: FrameIntent
        let action: FrameAction
        let lane: Lane
        let deadlineClass: DeadlineClass
        let targetQuality: Float?
        let reason: String
    }

    struct KeyframeBarrierRelease: Sendable, Equatable {
        let kind: KeyframeBarrierKind
        let reason: String
        let evidence: String
        let suppressedPFrameCount: UInt64
    }

    struct LaneSnapshot: Sendable, Equatable {
        let realtimeWireBytes: Int?
        let clarityWireBytes: Int?
        let realtimeSuccessfulProbes: UInt64
        let claritySuccessfulProbes: UInt64
        let realtimeFailedProbes: UInt64
        let clarityFailedProbes: UInt64
    }

    private struct KeyframeBarrier: Sendable, Equatable {
        let kind: KeyframeBarrierKind
        let reason: String
        let startedAt: CFAbsoluteTime
        var frameNumber: UInt32?
        var suppressedPFrameCount: UInt64 = 0
    }

    private struct InFlightFrame: Sendable, Equatable {
        let intent: FrameIntent
        let lane: Lane
        let wireBytes: Int
        let quality: Float
        let enqueuedAt: CFAbsoluteTime
    }

    private struct LaneEnvelope: Sendable, Equatable {
        var wireBytes: Int?
        var rememberedQuality: Float = 0
        var raiseSuppressedUntil: CFAbsoluteTime = 0
        var successfulProbeCount: UInt64 = 0
        var failedProbeCount: UInt64 = 0

        mutating func noteSuccess(wireBytes: Int, quality: Float) {
            self.wireBytes = max(self.wireBytes ?? 0, wireBytes)
            rememberedQuality = max(rememberedQuality, quality)
            successfulProbeCount &+= 1
        }

        mutating func noteFailure(now: CFAbsoluteTime, suppressFor seconds: CFAbsoluteTime) {
            failedProbeCount &+= 1
            raiseSuppressedUntil = max(raiseSuppressedUntil, now + seconds)
            if let wireBytes {
                self.wireBytes = max(1, Int((Double(wireBytes) * 0.75).rounded(.down)))
            }
        }
    }

    private static let stillDirtyPercentage: Float = 0.5
    private static let lowMotionDirtyPercentage: Float = 3.0
    private static let startupProbeWindowSeconds: CFAbsoluteTime = 3.0
    private static let startupCleanFallbackSeconds: CFAbsoluteTime = 0.150
    private static let startupHardFallbackSeconds: CFAbsoluteTime = 0.350
    static let automaticStartupKeyframeQuality: Float = 0.34
    static let awdlStartupKeyframeQuality: Float = 0.28

    private var keyframeBarrier: KeyframeBarrier?
    private var startupBarrierReleasedAt: CFAbsoluteTime = 0
    private var realtimeEnvelope = LaneEnvelope()
    private var clarityEnvelope = LaneEnvelope()
    private var recoveryEnvelope = LaneEnvelope()
    private var inFlightFrames: [UInt32: InFlightFrame] = [:]
    private var lastDecisionLogKey: String?
    private var lastDecisionLogTime: CFAbsoluteTime = 0
    private(set) var lastFrameIntent: FrameIntent = .idleSkip

    var activeKeyframeBarrierKind: KeyframeBarrierKind? {
        keyframeBarrier?.kind
    }

    var activeKeyframeBarrierReason: String? {
        keyframeBarrier?.reason
    }

    var hasActiveKeyframeBarrier: Bool {
        keyframeBarrier != nil
    }

    var currentLaneSnapshot: LaneSnapshot {
        LaneSnapshot(
            realtimeWireBytes: realtimeEnvelope.wireBytes,
            clarityWireBytes: clarityEnvelope.wireBytes,
            realtimeSuccessfulProbes: realtimeEnvelope.successfulProbeCount,
            claritySuccessfulProbes: clarityEnvelope.successfulProbeCount,
            realtimeFailedProbes: realtimeEnvelope.failedProbeCount,
            clarityFailedProbes: clarityEnvelope.failedProbeCount
        )
    }

    mutating func reset() {
        self = HostAdaptiveFrameCoordinator()
    }

    mutating func startKeyframeBarrier(
        kind: KeyframeBarrierKind,
        reason: String,
        now: CFAbsoluteTime
    ) {
        if kind != .bootstrap {
            startupBarrierReleasedAt = 0
        }
        keyframeBarrier = KeyframeBarrier(kind: kind, reason: reason, startedAt: now)
    }

    mutating func bindKeyframeFrameNumber(_ frameNumber: UInt32, now: CFAbsoluteTime) {
        guard keyframeBarrier != nil else { return }
        keyframeBarrier?.frameNumber = frameNumber
        lastDecisionLogTime = min(lastDecisionLogTime, now)
    }

    mutating func evaluateFrame(_ input: FrameInput) -> FrameDecision {
        let decision: FrameDecision
        if let barrier = keyframeBarrier, !input.forceKeyframe {
            keyframeBarrier?.suppressedPFrameCount &+= 1
            decision = FrameDecision(
                intent: intent(for: barrier.kind),
                action: .skip,
                lane: lane(for: barrier.kind),
                deadlineClass: .none,
                targetQuality: nil,
                reason: "keyframe-barrier-\(barrier.kind.rawValue)"
            )
        } else if input.forceKeyframe {
            let intent = keyframeIntent(for: input)
            decision = FrameDecision(
                intent: intent,
                action: .encodeKeyframe,
                lane: lane(for: intent),
                deadlineClass: intent == .bootstrapKeyframe ? .realtime : .recovery,
                targetQuality: keyframeQuality(for: intent, mediaPathProfile: input.mediaPathProfile, ceiling: input.qualityCeiling),
                reason: input.pendingKeyframeReason ?? intent.rawValue
            )
        } else if input.isIdleFrame, !input.admitsStillQualityProbe {
            decision = FrameDecision(
                intent: .idleSkip,
                action: .skip,
                lane: .clarity,
                deadlineClass: .none,
                targetQuality: nil,
                reason: "idle-no-clarity-probe"
            )
        } else {
            let intent = pFrameIntent(for: input)
            decision = FrameDecision(
                intent: intent,
                action: .encodePFrame,
                lane: lane(for: intent),
                deadlineClass: deadlineClass(for: intent),
                targetQuality: qualityTarget(for: intent, input: input),
                reason: reason(for: intent, input: input)
            )
        }
        lastFrameIntent = decision.intent
        return decision
    }

    mutating func releaseStartupBarrierIfTimedOut(
        senderQueuedBytes: Int,
        queuePressureBytes: Int,
        now: CFAbsoluteTime
    ) -> KeyframeBarrierRelease? {
        guard let barrier = keyframeBarrier, barrier.kind == .bootstrap else { return nil }
        let elapsed = now - barrier.startedAt
        let cleanQueue = senderQueuedBytes <= max(1, queuePressureBytes) / 2
        guard elapsed >= Self.startupHardFallbackSeconds ||
            (cleanQueue && elapsed >= Self.startupCleanFallbackSeconds) else {
            return nil
        }
        return releaseBarrier(evidence: cleanQueue ? "startup-clean-fallback" : "startup-hard-fallback", now: now)
    }

    mutating func noteKeyframeTransportCompletion(
        frameNumber: UInt32,
        didSend: Bool,
        allowsStartupLocalRelease: Bool,
        now: CFAbsoluteTime
    ) -> KeyframeBarrierRelease? {
        guard let barrier = keyframeBarrier else { return nil }
        if let barrierFrame = barrier.frameNumber, barrierFrame != frameNumber { return nil }
        if didSend, barrier.kind == .bootstrap, allowsStartupLocalRelease {
            return releaseBarrier(evidence: "local-send-completion", now: now)
        }
        if !didSend {
            guard barrier.kind == .bootstrap else { return nil }
            return releaseBarrier(evidence: "transport-failed", now: now)
        }
        keyframeBarrier?.frameNumber = frameNumber
        return nil
    }

    mutating func noteReceiverAcceptedKeyframe(
        frameNumber: UInt32,
        now: CFAbsoluteTime
    ) -> KeyframeBarrierRelease? {
        guard let barrier = keyframeBarrier else { return nil }
        if let barrierFrame = barrier.frameNumber, barrierFrame != frameNumber { return nil }
        return releaseBarrier(evidence: "receiver-accepted", now: now)
    }

    mutating func releaseKeyframeBarrierAfterReceiverAcceptanceTimeout(
        frameNumber: UInt32,
        now: CFAbsoluteTime
    ) -> KeyframeBarrierRelease? {
        guard let barrier = keyframeBarrier else { return nil }
        if let barrierFrame = barrier.frameNumber, barrierFrame != frameNumber { return nil }
        return releaseBarrier(evidence: "receiver-acceptance-timeout", now: now)
    }

    mutating func noteFrameReserved(
        frameNumber: UInt32,
        intent: FrameIntent,
        wireBytes: Int,
        quality: Float,
        now: CFAbsoluteTime
    ) {
        inFlightFrames[frameNumber] = InFlightFrame(
            intent: intent,
            lane: lane(for: intent),
            wireBytes: max(0, wireBytes),
            quality: max(0, quality),
            enqueuedAt: now
        )
        if inFlightFrames.count > 240 {
            let sortedKeys = inFlightFrames
                .sorted { $0.value.enqueuedAt < $1.value.enqueuedAt }
                .prefix(max(0, inFlightFrames.count - 240))
                .map(\.key)
            for key in sortedKeys {
                inFlightFrames.removeValue(forKey: key)
            }
        }
    }

    mutating func noteFrameTransportCompletion(
        frameNumber: UInt32,
        didSend: Bool,
        queuedUnreliableDropCount: UInt64,
        now: CFAbsoluteTime
    ) {
        guard let frame = inFlightFrames.removeValue(forKey: frameNumber) else { return }
        let failed = !didSend || queuedUnreliableDropCount > 0
        switch frame.lane {
        case .realtime:
            if failed {
                realtimeEnvelope.noteFailure(now: now, suppressFor: 0.300)
            } else {
                realtimeEnvelope.noteSuccess(wireBytes: frame.wireBytes, quality: frame.quality)
            }
        case .clarity:
            if failed {
                clarityEnvelope.noteFailure(now: now, suppressFor: 1.000)
            } else {
                clarityEnvelope.noteSuccess(wireBytes: frame.wireBytes, quality: frame.quality)
            }
        case .recovery,
             .bootstrap:
            if !failed {
                recoveryEnvelope.noteSuccess(wireBytes: frame.wireBytes, quality: frame.quality)
            }
        }
    }

    func allowsDynamicCadenceDemotion(
        pressureState: HostAdaptivePFrameController.PressureState,
        activeQuality: Float,
        qualityFloor: Float,
        sourceStill: Bool,
        inputActive: Bool,
        receiverState: ReceiverEvidenceState,
        transportPressureActionable: Bool,
        transportAdmissionActiveDuration: CFAbsoluteTime
    ) -> Bool {
        guard pressureState == .pressured || pressureState == .severe else { return false }
        guard transportPressureActionable else { return false }
        if receiverState == .severe, transportAdmissionActiveDuration >= 1.0 {
            return true
        }
        if pressureState == .severe, transportAdmissionActiveDuration >= 1.0 {
            return true
        }
        if !sourceStill,
           activeQuality <= qualityFloor + 0.04,
           transportAdmissionActiveDuration >= 0.5 {
            return true
        }
        if sourceStill, !inputActive, transportAdmissionActiveDuration >= 2.0 {
            return true
        }
        return activeQuality <= qualityFloor + 0.04 && transportAdmissionActiveDuration >= 2.0
    }

    func allowsStructuralScaleDemotion(
        receiverState: ReceiverEvidenceState,
        transportAdmissionActiveDuration: CFAbsoluteTime
    ) -> Bool {
        transportAdmissionActiveDuration >= 2.0 && receiverState == .severe
    }

    mutating func shouldLogDecision(_ decision: FrameDecision, now: CFAbsoluteTime) -> Bool {
        let key = [
            decision.intent.rawValue,
            decision.action.rawValue,
            decision.lane.rawValue,
            decision.deadlineClass.rawValue,
            decision.reason
        ].joined(separator: "|")
        guard key != lastDecisionLogKey || now - lastDecisionLogTime >= 1.0 else {
            return false
        }
        lastDecisionLogKey = key
        lastDecisionLogTime = now
        return true
    }

    func keyframeQuality(
        for intent: FrameIntent,
        mediaPathProfile: MirageMediaPathProfile,
        ceiling: Float
    ) -> Float? {
        guard intent == .bootstrapKeyframe else { return nil }
        let target = mediaPathProfile.usesAwdlRadioPolicy
            ? Self.awdlStartupKeyframeQuality
            : Self.automaticStartupKeyframeQuality
        return min(max(0, ceiling), target)
    }

    private mutating func releaseBarrier(
        evidence: String,
        now: CFAbsoluteTime
    ) -> KeyframeBarrierRelease? {
        guard let barrier = keyframeBarrier else { return nil }
        keyframeBarrier = nil
        if barrier.kind == .bootstrap {
            startupBarrierReleasedAt = now
        }
        return KeyframeBarrierRelease(
            kind: barrier.kind,
            reason: barrier.reason,
            evidence: evidence,
            suppressedPFrameCount: barrier.suppressedPFrameCount
        )
    }

    private func keyframeIntent(for input: FrameInput) -> FrameIntent {
        if let barrier = keyframeBarrier {
            return intent(for: barrier.kind)
        }
        if input.frameChainRepairActive {
            return .recoveryKeyframe
        }
        if !input.hasSentKeyframe {
            return .bootstrapKeyframe
        }
        return .recoveryKeyframe
    }

    private func pFrameIntent(for input: FrameInput) -> FrameIntent {
        if canUseStartupProbe(input.now) {
            return input.sourceStill && !input.inputActive ? .clarityRefresh : .probe
        }
        if input.inputActive || input.dirtyPercentage > Self.lowMotionDirtyPercentage {
            return .realtimeMotion
        }
        if input.admitsStillQualityProbe,
           input.sourceStill,
           input.receiverState == .healthy {
            return .clarityRefresh
        }
        if input.sourceStill && !input.inputActive && input.dirtyPercentage <= Self.stillDirtyPercentage {
            return .clarityRefresh
        }
        if input.dirtyPercentage <= Self.stillDirtyPercentage {
            return .clarityRefresh
        }
        return .realtimeMotion
    }

    private func reason(for intent: FrameIntent, input: FrameInput) -> String {
        switch intent {
        case .bootstrapKeyframe:
            "bootstrap"
        case .recoveryKeyframe:
            "recovery"
        case .realtimeMotion:
            input.inputActive ? "input-active" : "motion"
        case .clarityRefresh:
            input.admitsStillQualityProbe ? "clarity-probe" : "still-clarity"
        case .probe:
            "startup-probe"
        case .idleSkip:
            "idle"
        }
    }

    private func qualityTarget(for intent: FrameIntent, input: FrameInput) -> Float? {
        switch intent {
        case .clarityRefresh:
            let remembered = max(input.currentQuality, input.qualityFloor, clarityEnvelope.rememberedQuality)
            let raiseMultiplier: Float = canUseStartupProbe(input.now) ? 1.75 : 1.25
            return min(input.qualityCeiling, remembered * raiseMultiplier)
        case .probe where canUseStartupProbe(input.now):
            let remembered = max(input.currentQuality, input.qualityFloor, realtimeEnvelope.rememberedQuality)
            return min(input.qualityCeiling, remembered * 1.35)
        case .realtimeMotion:
            if canUseStartupProbe(input.now), input.receiverState != .severe {
                let remembered = max(input.currentQuality, input.qualityFloor, realtimeEnvelope.rememberedQuality)
                return min(input.qualityCeiling, remembered * 1.35)
            }
            return min(input.qualityCeiling, max(input.qualityFloor, input.currentQuality))
        case .bootstrapKeyframe,
             .recoveryKeyframe,
             .probe,
             .idleSkip:
            return nil
        }
    }

    private func canUseStartupProbe(_ now: CFAbsoluteTime) -> Bool {
        startupBarrierReleasedAt > 0 && now - startupBarrierReleasedAt <= Self.startupProbeWindowSeconds
    }

    private func intent(for kind: KeyframeBarrierKind) -> FrameIntent {
        switch kind {
        case .bootstrap:
            .bootstrapKeyframe
        case .recovery,
             .reconfiguration:
            .recoveryKeyframe
        }
    }

    private func lane(for kind: KeyframeBarrierKind) -> Lane {
        switch kind {
        case .bootstrap:
            .bootstrap
        case .recovery,
             .reconfiguration:
            .recovery
        }
    }

    private func lane(for intent: FrameIntent) -> Lane {
        switch intent {
        case .bootstrapKeyframe:
            .bootstrap
        case .recoveryKeyframe:
            .recovery
        case .realtimeMotion,
             .probe:
            .realtime
        case .clarityRefresh,
             .idleSkip:
            .clarity
        }
    }

    private func deadlineClass(for intent: FrameIntent) -> DeadlineClass {
        switch intent {
        case .realtimeMotion,
             .probe:
            .realtime
        case .clarityRefresh:
            .relaxed
        case .bootstrapKeyframe,
             .recoveryKeyframe:
            .recovery
        case .idleSkip:
            .none
        }
    }
}
#endif
