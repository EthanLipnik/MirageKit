//
//  StreamContext+KeyframeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Explicit keyframe recovery requests.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
extension StreamContext {
    /// Request a keyframe from the encoder.
    func requestKeyframe(recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause = .none) async -> MirageWire.KeyframeRecoveryAckMessage {
        latestReceiverRecoveryCause = recoveryCause
        let accepted = await requestKeyframeRecovery(recoveryCause: recoveryCause)
        return keyframeRecoveryAck(accepted: accepted)
    }

    func requestKeyframeRecoveryIfPossible() async {
        let queued = queueKeyframeRecoveryRequest()
        guard queued else { return }
        await completeAcceptedKeyframeRecoveryRequest(now: CFAbsoluteTimeGetCurrent(), reason: "Keyframe request")
    }

    private func requestKeyframeRecovery(recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause) async -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let reason = "Keyframe request"
        let queued = queueKeyframeRecoveryRequest(recoveryCause: recoveryCause)
        guard queued else { return false }
        recordAcceptedExplicitKeyframeRequest(recoveryCause: recoveryCause, now: now)
        await completeAcceptedKeyframeRecoveryRequest(now: now, reason: reason, recoveryCause: recoveryCause)
        return true
    }

    private func queueKeyframeRecoveryRequest(recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause = .none) -> Bool {
        let reason = "Keyframe request"
        guard recoveryCause.allowsExplicitKeyframeRequest else {
            MirageLogger.stream(
                "\(reason) skipped for non-decode recovery cause \(recoveryCause.rawValue)"
            )
            return false
        }

        logFreshnessBurstKeyframeRecovery(reason: reason)

        let now = CFAbsoluteTimeGetCurrent()
        guard !shouldSuppressDuplicateExplicitKeyframeRequest(
            recoveryCause: recoveryCause,
            now: now
        ) else {
            MirageLogger.stream(
                "\(reason) skipped duplicate explicit request cause=\(recoveryCause.rawValue)"
            )
            return false
        }

        let requiresImmediateChainRepair = recoveryCauseRequiresImmediateChainRepair(recoveryCause)
        if shouldCoalesceAwdlRecoveryKeyframeRequest(
            recoveryCause: recoveryCause,
            requiresImmediateChainRepair: requiresImmediateChainRepair
        ) {
            MirageLogger.stream(
                "\(reason) skipped (AWDL recovery keyframe already pending, "
                    + "cause=\(recoveryCause.rawValue))"
            )
            return false
        }
        if !requiresImmediateChainRepair,
           !recoveryCauseBypassesAdaptiveKeyframeCooldown(recoveryCause),
           isRecoveryKeyframeCooldownActive(now: now) {
            logRecoveryKeyframeCooldownSuppression(reason: reason, now: now)
            return false
        }
        if requiresImmediateChainRepair {
            lastKeyframeRequestTime = 0
            if !usesConstrainedKeyframeInFlightWindow {
                keyframeSendDeadline = 0
                keyframeInFlightFrameNumber = nil
            }
        }

        return queueKeyframe(
            reason: reason,
            checkInFlight: !requiresImmediateChainRepair || usesConstrainedKeyframeInFlightWindow,
            requiresFlush: requiresImmediateChainRepair,
            requiresReset: requiresImmediateChainRepair,
            advanceEpochOnReset: requiresImmediateChainRepair,
            urgent: true
        )
    }

    private func shouldSuppressDuplicateExplicitKeyframeRequest(
        recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause,
        now: CFAbsoluteTime
    ) -> Bool {
        guard lastAcceptedExplicitKeyframeRequestTime > 0,
              recoveryCause == lastAcceptedExplicitKeyframeRequestCause else {
            return false
        }
        return now - lastAcceptedExplicitKeyframeRequestTime < explicitKeyframeRequestDuplicateWindow
    }

    private func recordAcceptedExplicitKeyframeRequest(
        recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause,
        now: CFAbsoluteTime
    ) {
        lastAcceptedExplicitKeyframeRequestCause = recoveryCause
        lastAcceptedExplicitKeyframeRequestTime = now
    }

    private func shouldCoalesceAwdlRecoveryKeyframeRequest(
        recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause,
        requiresImmediateChainRepair: Bool
    ) -> Bool {
        guard mediaPathProfile.usesAwdlRadioPolicy,
              requiresImmediateChainRepair else {
            return false
        }
        if pendingKeyframeReason != nil { return true }
        if pendingReceiverAcceptedKeyframeFrameNumber != nil { return true }
        if isKeyframeEncoding { return true }
        if case .emergencyKeyframePending = frameChainState { return true }
        return false
    }

    private func completeAcceptedKeyframeRecoveryRequest(
        now: CFAbsoluteTime,
        reason: String,
        recoveryCause: MirageMediaFeedbackRecoveryCause = .none
    ) async {
        softRecoveryCount += 1
        // A freeze-timeout request while the source is still and no receiver loss
        // is in flight is an idle-screen refresh, not a loss event: deliver the
        // keyframe without arming loss mode or P-frame FEC overhead.
        let isIdleRefresh = recoveryCause == .freezeTimeout &&
            receiverFrameBudgetLossHoldUntil <= now &&
            sourceIsStill(now: now)
        if isIdleRefresh {
            MirageLogger.stream(
                "Idle-refresh keyframe for stream \(streamID): loss mode and FEC skipped"
            )
            scheduleProcessingForPendingKeyframe(reason: reason, now: now)
            MirageLogger
                .stream(
                    "Recovery keyframe requests=\(softRecoveryCount)"
                )
            return
        } else {
            noteLossEvent(reason: reason, enablePFrameFEC: true)
        }
        startFrameChainRepair(
            reason: "client-keyframe-request",
            now: now
        )
        await noteEmergencyKeyframePrepared(using: nil)
        scheduleProcessingForPendingKeyframe(reason: reason, now: now)
        MirageLogger
            .stream(
                "Recovery keyframe requests=\(softRecoveryCount)"
            )
    }

    private func keyframeRecoveryAck(accepted: Bool) -> MirageWire.KeyframeRecoveryAckMessage {
        let now = CFAbsoluteTimeGetCurrent()
        let deadlineMs: Int
        let state: MirageWire.KeyframeRecoveryAckState
        if keyframeSendDeadline > now {
            deadlineMs = Int(((keyframeSendDeadline - now) * 1000).rounded(.up))
            state = accepted ? .accepted : .inFlight
        } else if isRecoveryKeyframeCooldownActive(now: now) {
            deadlineMs = Int((recoveryKeyframeCooldownRemaining(now: now) * 1000).rounded(.up))
            state = accepted ? .accepted : .cooldown
        } else {
            deadlineMs = Int((activeKeyframeRequestCooldown * 1000).rounded(.up))
            state = accepted ? .accepted : .cooldown
        }
        return MirageWire.KeyframeRecoveryAckMessage(
            streamID: streamID,
            deadlineMilliseconds: deadlineMs,
            accepted: accepted,
            state: state
        )
    }
}

private extension MirageWire.MirageMediaFeedbackRecoveryCause {
    var allowsExplicitKeyframeRequest: Bool {
        switch self {
        case .decodeError,
             .freezeTimeout,
             .manual,
             .startupTimeout,
             .none:
            true
        case .frameLoss,
             .memoryBudget:
            false
        }
    }
}
#endif
