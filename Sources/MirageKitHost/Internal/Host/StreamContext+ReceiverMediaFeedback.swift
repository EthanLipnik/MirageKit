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
        let decision = transportController.update(
            with: feedback,
            currentFrameRate: currentFrameRate,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
        if mediaPathProfile.usesAwdlRadioPolicy {
            await logAwdlReceiverFeedbackIfNeeded(
                now: now,
                feedback: feedback,
                decision: decision
            )
        }
        guard let decision else {
            return
        }

        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            decision.qualityRaiseSuppressionDeadline
        )
        receiverFrameAdmissionTargetFPS = decision.frameAdmissionTargetFPS
        receiverFrameAdmissionDeadline = decision.frameAdmissionDeadline
        if mediaPathProfile.usesAwdlRadioPolicy, decision.awdlPacingDeadline > now {
            await packetSender?.activateAwdlPressurePacing(
                until: decision.awdlPacingDeadline,
                reason: decision.awdlPacingTrigger.rawValue
            )
        }

        if !mediaPathProfile.usesAwdlRadioPolicy ||
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

    private func logAwdlReceiverFeedbackIfNeeded(
        now: CFAbsoluteTime,
        feedback: ReceiverMediaFeedbackMessage,
        decision: HostStreamTransportController.Decision?
    ) async {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let trigger = decision?.awdlPacingTrigger ?? decision?.frameAdmissionTrigger ?? .none
        let hasReceiverStress = trigger != .none ||
            feedback.recoveryState != .idle ||
            feedback.lostFrameCount > 0 ||
            feedback.discardedPacketCount > 0 ||
            feedback.reassemblyBacklogFrames > 0 ||
            feedback.reassemblyBacklogKeyframes > 0 ||
            (feedback.presentationStallCount ?? 0) > 0 ||
            (feedback.displayTickNoFrameCount ?? 0) > 0 ||
            (feedback.reassemblerForwardGapTimeouts ?? 0) > 0
        guard hasReceiverStress ||
            lastAwdlReceiverFeedbackLogTime == 0 ||
            now - lastAwdlReceiverFeedbackLogTime >= 5.0 ||
            trigger != lastAwdlReceiverFeedbackTrigger else {
            return
        }
        guard lastAwdlReceiverFeedbackLogTime == 0 ||
            now - lastAwdlReceiverFeedbackLogTime >= 1.0 ||
            trigger != lastAwdlReceiverFeedbackTrigger else {
            return
        }

        lastAwdlReceiverFeedbackLogTime = now
        lastAwdlReceiverFeedbackTrigger = trigger
        let admission = decision?.frameAdmissionTargetFPS.map { "\($0)fps" } ?? "none"
        let latestAwdlPolicy = transportController.latestAwdlMediaDecision
        let policyState = decision?.awdlPolicyState?.rawValue ?? latestAwdlPolicy?.state.rawValue ?? "observing"
        let policyTrigger = decision?.awdlPolicyTrigger?.rawValue ?? latestAwdlPolicy?.trigger.rawValue ?? "none"
        let policyTargetFPS = decision?.awdlTargetFrameRate?.description ??
            latestAwdlPolicy?.targetFrameRate.description ??
            "n/a"
        let packetTelemetry = await packetSender?.telemetrySnapshot
        let loomProfile = mediaSendProfileRawValue ?? "unknown"
        let loomMaxOutstandingPackets = mediaSendProfileMaxOutstandingPackets.map { "\($0)" } ?? "unknown"
        let loomMaxOutstandingBytes = mediaSendProfileMaxOutstandingBytes.map { "\($0)" } ?? "unknown"
        let loomMaxQueuedPackets = mediaSendProfileMaxQueuedPackets.map { "\($0)" } ?? "none"
        let pacing = if let decision, decision.awdlPacingDeadline > now {
            "\(Int(max(0, decision.awdlPacingDeadline - now) * 1000))ms"
        } else {
            "none"
        }
        let causes = feedback.reliabilityCauses.map(\.rawValue).joined(separator: ",")
        MirageLogger.metrics(
            "AWDL host receiver feedback: stream=\(streamID) " +
                "trigger=\(trigger.rawValue) policy=\(policyState)/\(policyTrigger) " +
                "pacingHold=\(pacing) admission=\(admission) policyTargetFPS=\(policyTargetFPS) " +
                "loomProfile=\(loomProfile) " +
                "loomMaxOutstandingPackets=\(loomMaxOutstandingPackets) " +
                "loomMaxOutstandingBytes=\(loomMaxOutstandingBytes) " +
                "loomMaxQueuedPackets=\(loomMaxQueuedPackets) " +
                "senderQueueBytes=\(packetTelemetry?.queuedBytes ?? 0) " +
                "localSendStartAvgMs=\(formatAwdlMetric(packetTelemetry?.sendStartDelayAverageMs ?? 0)) " +
                "localSendStartMaxMs=\(formatAwdlMetric(packetTelemetry?.sendStartDelayMaxMs ?? 0)) " +
                "localContentProcessedAvgMs=\(formatAwdlMetric(packetTelemetry?.sendCompletionAverageMs ?? 0)) " +
                "localContentProcessedMaxMs=\(formatAwdlMetric(packetTelemetry?.sendCompletionMaxMs ?? 0)) " +
                "nonKeyframeContentProcessedMaxMs=\(formatAwdlMetric(packetTelemetry?.nonKeyframeSendCompletionMaxMs ?? 0)) " +
                "pacerFrameMaxSleepMs=\(packetTelemetry?.packetPacerFrameMaxSleepMs ?? 0) " +
                "senderLocalDeadlineDrops=\(packetTelemetry?.senderLocalDeadlineDrops ?? 0) " +
                "senderStaleDrops=\(packetTelemetry?.stalePacketDrops ?? 0) " +
                "targetFPS=\(feedback.targetFPS) " +
                "rxFPS=\(formatAwdlMetric(feedback.receivedFPS)) " +
                "decodeFPS=\(formatAwdlMetric(feedback.decodedFPS)) " +
                "presentFPS=\(formatAwdlMetric(feedback.rendererPresentedFPS)) " +
                "rxGapMaxMs=\(formatAwdlMetric(feedback.receivedWorstGapMs ?? 0)) " +
                "rxP99Ms=\(formatAwdlMetric(feedback.jitterP99Ms)) " +
                "pFrameP95Ms=\(formatAwdlMetric(feedback.pFrameCompletionLatencyP95Ms ?? 0)) " +
                "latePFrames=\(feedback.latePFrameCount ?? 0) " +
                "lostFrames=\(feedback.lostFrameCount) discardedPackets=\(feedback.discardedPacketCount) " +
                "reassemblyFrames=\(feedback.reassemblyBacklogFrames) " +
                "keyframes=\(feedback.reassemblyBacklogKeyframes) " +
                "reassemblyBytes=\(feedback.reassemblyBacklogBytes) " +
                "incompleteTimeouts=\(feedback.reassemblerIncompleteFrameTimeouts ?? 0) " +
                "missingFragments=\(feedback.reassemblerMissingFragmentTimeouts ?? 0) " +
                "fecRecovered=\(feedback.fecRecoveredFragmentCount ?? 0) " +
                "forwardGaps=\(feedback.reassemblerForwardGapTimeouts ?? 0) " +
                "playoutTargetMs=\(formatAwdlMetric(feedback.playoutDelayTargetMs ?? 0)) " +
                "playoutFrames=\(feedback.playoutDelayFrames ?? 0) " +
                "presentGapMaxMs=\(formatAwdlMetric(feedback.worstPresentationGapMs ?? 0)) " +
                "underflows=\(feedback.displayTickNoFrameCount ?? 0) " +
                "presentationStalls=\(feedback.presentationStallCount ?? 0) " +
                "recovery=\(feedback.recoveryState.rawValue) " +
                "causes=\(causes)"
        )
    }

    private func formatAwdlMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }
}
#endif
