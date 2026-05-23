//
//  StreamContext+ReceiverMediaFeedback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func applyReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) async {
        let now = CFAbsoluteTimeGetCurrent()
        lastReceiverFeedbackTime = now
        receiverPresentationBacklogFrames = feedback.presentationBacklogFrames
        receiverAcceptedFPS = feedback.rendererAcceptedFPS
        receiverPresentedFPS = feedback.rendererPresentedFPS
        if feedback.rendererPresentedFPS > 0 || feedback.rendererAcceptedFPS > 0 {
            receiverHasPresentedFrame = true
        }
        guard let decision = transportController.update(
            with: feedback,
            currentFrameRate: currentFrameRate,
            transportPathKind: transportPathKind,
            now: now
        ) else {
            return
        }

        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            decision.qualityRaiseSuppressionDeadline
        )
        receiverFrameAdmissionTargetFPS = decision.frameAdmissionTargetFPS
        receiverFrameAdmissionDeadline = decision.frameAdmissionDeadline
        if transportPathKind == .awdl, decision.awdlPacingDeadline > now {
            await packetSender?.activateAwdlPressurePacing(
                until: decision.awdlPacingDeadline,
                reason: decision.awdlPacingTrigger.rawValue
            )
        }

        if transportPathKind != .awdl ||
            decision.frameAdmissionTargetFPS != nil ||
            receiverFrameAdmissionLastLoggedTargetFPS != nil {
            logReceiverFrameAdmissionChangeIfNeeded(
                now: now,
                trigger: decision.frameAdmissionTrigger
            )
        }
    }

    func receiverFrameAdmissionIsActive(now: CFAbsoluteTime) -> Bool {
        guard let targetFPS = receiverFrameAdmissionTargetFPS else { return false }
        guard targetFPS < currentFrameRate else { return false }
        if receiverFrameAdmissionDeadline > 0, now >= receiverFrameAdmissionDeadline {
            receiverFrameAdmissionTargetFPS = nil
            receiverFrameAdmissionDeadline = 0
            receiverFrameAdmissionLastAdmitTime = 0
            return false
        }
        return true
    }

    func shouldDropForReceiverFrameAdmission(now: CFAbsoluteTime) -> Bool {
        guard receiverFrameAdmissionIsActive(now: now),
              let targetFPS = receiverFrameAdmissionTargetFPS else {
            return false
        }
        if pendingKeyframeReason != nil ||
            pendingKeyframeDeadline > now ||
            pendingKeyframeRequiresFlush ||
            isKeyframeEncoding {
            receiverFrameAdmissionLastAdmitTime = now
            return false
        }

        let interval = 1.0 / Double(max(1, targetFPS))
        if receiverFrameAdmissionLastAdmitTime == 0 ||
            now - receiverFrameAdmissionLastAdmitTime >= interval {
            receiverFrameAdmissionLastAdmitTime = now
            return false
        }
        return true
    }

    private func logReceiverFrameAdmissionChangeIfNeeded(
        now: CFAbsoluteTime,
        trigger: HostStreamTransportController.FrameAdmissionTrigger
    ) {
        let logTarget = receiverFrameAdmissionIsActive(now: now) ? receiverFrameAdmissionTargetFPS : nil
        guard logTarget != receiverFrameAdmissionLastLoggedTargetFPS ||
            trigger != receiverFrameAdmissionLastLoggedTrigger ||
            now - receiverFrameAdmissionLastLogTime >= 1.0 else {
            return
        }
        receiverFrameAdmissionLastLogTime = now
        receiverFrameAdmissionLastLoggedTargetFPS = logTarget
        receiverFrameAdmissionLastLoggedTrigger = trigger
        if let targetFPS = logTarget {
            MirageLogger.metrics(
                "Receiver transport pressure limiting pre-encode admission to \(targetFPS)fps for stream \(streamID) trigger=\(trigger.rawValue)"
            )
        } else {
            MirageLogger.metrics(
                "Receiver transport pressure cleared pre-encode admission limit for stream \(streamID) trigger=\(trigger.rawValue)"
            )
        }
    }
}
#endif
