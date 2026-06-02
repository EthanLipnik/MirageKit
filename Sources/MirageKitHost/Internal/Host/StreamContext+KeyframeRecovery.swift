//
//  StreamContext+KeyframeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Explicit keyframe recovery requests.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Request a keyframe from the encoder.
    func requestKeyframe(recoveryCause: MirageMediaFeedbackRecoveryCause = .none) async -> KeyframeRecoveryAckMessage {
        latestReceiverRecoveryCause = recoveryCause
        let accepted = await requestKeyframeRecovery(recoveryCause: recoveryCause)
        return keyframeRecoveryAck(accepted: accepted)
    }

    func requestKeyframeRecoveryIfPossible() async {
        let queued = queueKeyframeRecoveryRequest()
        guard queued else { return }
        await completeAcceptedKeyframeRecoveryRequest(now: CFAbsoluteTimeGetCurrent(), reason: "Keyframe request")
    }

    private func requestKeyframeRecovery(recoveryCause: MirageMediaFeedbackRecoveryCause) async -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let reason = "Keyframe request"
        let queued = queueKeyframeRecoveryRequest(recoveryCause: recoveryCause)
        guard queued else { return false }
        recordAcceptedExplicitKeyframeRequest(recoveryCause: recoveryCause, now: now)
        await completeAcceptedKeyframeRecoveryRequest(now: now, reason: reason)
        return true
    }

    private func queueKeyframeRecoveryRequest(recoveryCause: MirageMediaFeedbackRecoveryCause = .none) -> Bool {
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
        recoveryCause: MirageMediaFeedbackRecoveryCause,
        now: CFAbsoluteTime
    ) -> Bool {
        guard lastAcceptedExplicitKeyframeRequestTime > 0,
              recoveryCause == lastAcceptedExplicitKeyframeRequestCause else {
            return false
        }
        return now - lastAcceptedExplicitKeyframeRequestTime < explicitKeyframeRequestDuplicateWindow
    }

    private func recordAcceptedExplicitKeyframeRequest(
        recoveryCause: MirageMediaFeedbackRecoveryCause,
        now: CFAbsoluteTime
    ) {
        lastAcceptedExplicitKeyframeRequestCause = recoveryCause
        lastAcceptedExplicitKeyframeRequestTime = now
    }

    private func completeAcceptedKeyframeRecoveryRequest(now: CFAbsoluteTime, reason: String) async {
        softRecoveryCount += 1
        noteLossEvent(reason: reason, enablePFrameFEC: true)
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

    private func keyframeRecoveryAck(accepted: Bool) -> KeyframeRecoveryAckMessage {
        let now = CFAbsoluteTimeGetCurrent()
        let deadlineMs: Int
        let state: KeyframeRecoveryAckState
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
        return KeyframeRecoveryAckMessage(
            streamID: streamID,
            deadlineMilliseconds: deadlineMs,
            accepted: accepted,
            state: state
        )
    }
}

private extension MirageMediaFeedbackRecoveryCause {
    var allowsExplicitKeyframeRequest: Bool {
        switch self {
        case .decodeError,
             .manual,
             .startupTimeout,
             .none:
            true
        case .frameLoss,
             .freezeTimeout,
             .memoryBudget:
            false
        }
    }
}
#endif
