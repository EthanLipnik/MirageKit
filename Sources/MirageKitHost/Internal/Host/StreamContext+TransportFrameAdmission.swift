//
//  StreamContext+TransportFrameAdmission.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostTransportAdmissionPressureState: Sendable, Equatable {
    var mode: HostTransportFrameAdmissionPolicy.Mode = .normal
    var reason: String?
    var evidence: String?
    var firstSkipTime: CFAbsoluteTime = 0
    var lastSkipTime: CFAbsoluteTime = 0
    var activeUntil: CFAbsoluteTime = 0
    var skipBurstCount: UInt64 = 0
    var lastMinimumFrameIntervalMs: Double = 0
    var lastStructuralStepTime: CFAbsoluteTime = 0

    var isActive: Bool {
        activeUntil > CFAbsoluteTimeGetCurrent()
    }

    func isActive(now: CFAbsoluteTime) -> Bool {
        activeUntil > now
    }

    func activeHoldMs(now: CFAbsoluteTime) -> Double {
        max(0, (activeUntil - now) * 1_000)
    }

    func activeDuration(now: CFAbsoluteTime) -> CFAbsoluteTime {
        guard firstSkipTime > 0 else { return 0 }
        return max(0, now - firstSkipTime)
    }

    mutating func noteSkip(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        now: CFAbsoluteTime
    ) {
        if lastSkipTime <= 0 || now - lastSkipTime > 1.0 {
            firstSkipTime = now
            skipBurstCount = 0
        }
        skipBurstCount &+= 1
        lastSkipTime = now
        mode = decision.mode
        reason = decision.reason
        evidence = decision.evidence
        lastMinimumFrameIntervalMs = decision.minimumFrameIntervalMs

        if decision.mode == .hardThrottle || skipBurstCount >= 3 {
            activeUntil = max(activeUntil, now + 1.0)
        }
    }

    mutating func noteCadencePressure(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        holdSeconds: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) {
        if firstSkipTime <= 0 || now - lastSkipTime > 1.0 {
            firstSkipTime = now
        }
        lastSkipTime = now
        mode = decision.mode
        reason = decision.reason
        evidence = decision.evidence
        lastMinimumFrameIntervalMs = decision.minimumFrameIntervalMs
        activeUntil = max(activeUntil, now + max(0.1, holdSeconds))
    }

    mutating func noteAdmission(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        senderClean: Bool,
        receiverClean: Bool,
        now: CFAbsoluteTime
    ) {
        mode = decision.mode
        reason = decision.reason
        evidence = decision.evidence
        lastMinimumFrameIntervalMs = decision.minimumFrameIntervalMs

        guard decision.mode == .normal,
              senderClean,
              receiverClean,
              lastSkipTime > 0,
              now - lastSkipTime >= 0.75 else {
            return
        }
        reset()
    }

    mutating func reset() {
        mode = .normal
        reason = nil
        evidence = nil
        firstSkipTime = 0
        lastSkipTime = 0
        activeUntil = 0
        skipBurstCount = 0
        lastMinimumFrameIntervalMs = 0
        lastStructuralStepTime = 0
    }
}

extension StreamContext {
    func shouldSkipPFrameForTransportAdmission(
        forceKeyframe: Bool,
        admitsStillQualityProbe: Bool,
        now: CFAbsoluteTime
    ) async -> Bool {
        if forceKeyframe || admitsStillQualityProbe {
            transportFrameAdmissionState.lastAdmittedFrameTime = now
            return false
        }
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let pressureSnapshot = adaptiveTransportPressureSnapshot(
            senderTelemetry: senderTelemetry,
            now: now
        )
        let receiverFeedbackAgeMs = lastReceiverFeedbackTime > 0
            ? max(0, (now - lastReceiverFeedbackTime) * 1_000)
            : nil
        let signal = HostTransportFrameAdmissionPolicy.Signal(
            runtimeAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile,
            pressureState: realtimePressureState,
            pressureReason: realtimePressureReason,
            transportPressureIsActionable: adaptiveFrameCoordinator.allowsTransportAdmissionThrottle(pressureSnapshot),
            senderTelemetry: senderTelemetry,
            queuePressureBytes: queuePressureBytes,
            maxQueuedBytes: maxQueuedBytes,
            receiverReassemblyBacklogFrames: receiverReassemblyBacklogFrames,
            receiverReassemblyBacklogBytes: receiverReassemblyBacklogBytes,
            receiverLossHoldActive: receiverFrameBudgetLossHoldUntil > now,
            receiverAckLagMs: receiverAckLagMs,
            receiverFeedbackAgeMs: receiverFeedbackAgeMs,
            inputActive: inputActive,
            sourceStill: sourceStill
        )
        let decision = HostTransportFrameAdmissionPolicy.evaluate(
            state: &transportFrameAdmissionState,
            signal: signal,
            bypass: false,
            now: now
        )

        if !decision.admitsFrame,
           !streamQualityGovernor.allowsTransportAdmissionSkip(
               snapshot: pressureSnapshot,
               proposedMode: decision.mode,
               reason: decision.reason,
               evidenceLabel: decision.evidence,
               inputActive: inputActive,
               contract: currentStreamQualityContract(),
               now: now
           ) {
            transportAdmissionPressureState.reset()
            transportFrameAdmissionState.mode = .normal
            transportFrameAdmissionState.activeUntil = 0
            transportFrameAdmissionState.lastAdmittedFrameTime = now
            MirageLogger.metrics(
                "event=transport_frame_admission stream=\(streamID) action=governor-block " +
                    "mode=\(decision.mode.rawValue) evidence=\(decision.evidence ?? "none") " +
                    "reason=\(decision.reason ?? "transport-pressure") " +
                    "blocked=\(streamQualityGovernor.latestDecision.blockedLeverReason ?? "governor")"
            )
            return false
        }

        logTransportFrameAdmissionModeChangeIfNeeded(decision, now: now)
        updateTransportAdmissionPressureState(decision, signal: signal, now: now)
        guard !decision.admitsFrame else { return false }
        recordTransportAdmissionSkip(decision, now: now)
        return true
    }

    func sustainedTransportAdmissionPressureIsActive(now: CFAbsoluteTime) -> Bool {
        transportAdmissionPressureState.isActive(now: now)
    }

    private func recordTransportAdmissionSkip(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        now: CFAbsoluteTime
    ) {
        transportAdmissionSkippedIntervalCount += 1
        droppedFrameCount += 1

        guard MirageLogger.isEnabled(.metrics),
              now - transportFrameAdmissionState.lastSkipLogTime >= 1.0 else {
            return
        }
        transportFrameAdmissionState.lastSkipLogTime = now
        let intervalText = decision.minimumFrameIntervalMs.formatted(.number.precision(.fractionLength(1)))
        let activeHoldText = transportAdmissionPressureState.activeHoldMs(now: now)
            .formatted(.number.precision(.fractionLength(0)))
        MirageLogger.metrics(
            "event=transport_frame_admission stream=\(streamID) action=skip " +
                "mode=\(decision.mode.rawValue) minIntervalMs=\(intervalText) " +
                "activeHoldMs=\(activeHoldText) burst=\(transportAdmissionPressureState.skipBurstCount) " +
                "evidence=\(decision.evidence ?? "none") reason=\(decision.reason ?? "transport-pressure")"
        )
    }

    private func logTransportFrameAdmissionModeChangeIfNeeded(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        now: CFAbsoluteTime
    ) {
        guard transportFrameAdmissionState.lastLoggedMode != decision.mode else { return }
        transportFrameAdmissionState.lastLoggedMode = decision.mode
        let intervalText = decision.minimumFrameIntervalMs > 0
            ? decision.minimumFrameIntervalMs.formatted(.number.precision(.fractionLength(1)))
            : "0"
        MirageLogger.metrics(
            "event=transport_frame_admission stream=\(streamID) action=mode " +
                "mode=\(decision.mode.rawValue) minIntervalMs=\(intervalText) " +
                "activeUntilMs=\(Int(max(0, transportFrameAdmissionState.activeUntil - now) * 1_000)) " +
                "evidence=\(decision.evidence ?? "none") reason=\(decision.reason ?? "clear")"
        )
    }

    private func updateTransportAdmissionPressureState(
        _ decision: HostTransportFrameAdmissionPolicy.Decision,
        signal: HostTransportFrameAdmissionPolicy.Signal,
        now: CFAbsoluteTime
    ) {
        if decision.admitsFrame {
            transportAdmissionPressureState.noteAdmission(
                decision,
                senderClean: transportAdmissionSenderIsClean(signal),
                receiverClean: transportAdmissionReceiverIsClean(signal),
                now: now
            )
        } else {
            transportAdmissionPressureState.noteSkip(decision, now: now)
        }
    }

    private func transportAdmissionSenderIsClean(_ signal: HostTransportFrameAdmissionPolicy.Signal) -> Bool {
        signal.senderQueuedBytes <= signal.queuePressureBytes / 2 &&
            signal.unstartedPFrameCount == 0 &&
            signal.queuedUnreliableQueuedBytes <= signal.queuePressureBytes / 2 &&
            signal.queuedUnreliablePendingPackets == 0 &&
            signal.queuedUnreliableDeadlineExpiredDrops == 0 &&
            signal.queuedUnreliableQueueLimitDrops == 0
    }

    private func transportAdmissionReceiverIsClean(_ signal: HostTransportFrameAdmissionPolicy.Signal) -> Bool {
        signal.receiverReassemblyBacklogFrames == 0 &&
            signal.receiverReassemblyBacklogBytes == 0 &&
            !signal.receiverLossHoldActive
    }
}
#endif
