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
        receiverDecodedFPS = feedback.decodedFPS
        receiverPresentationBacklogFrames = feedback.presentationBacklogFrames
        receiverReassemblyBacklogFrames = feedback.reassemblyBacklogFrames
        receiverReassemblyBacklogBytes = feedback.reassemblyBacklogBytes
        receiverDecodeBacklogFrames = feedback.decodeBacklogFrames
        receiverLostFrameCount = feedback.lostFrameCount
        receiverDiscardedPacketCount = feedback.discardedPacketCount
        receiverPFrameCompletionLatencyP95Ms = feedback.pFrameCompletionLatencyP95Ms
        receiverAcceptedFPS = feedback.rendererAcceptedFPS
        receiverPresentedFPS = feedback.rendererPresentedFPS
        latestReceiverRecoveryCause = feedback.recoveryCause
        applyReceiverFrameAcknowledgements(feedback.ackRanges, now: now)
        if feedback.rendererPresentedFPS > 0 || feedback.rendererAcceptedFPS > 0 {
            receiverHasPresentedFrame = true
        }
        let transportDecision = transportController.update(
            with: feedback,
            currentFrameRate: currentFrameRate,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
        let frameBudgetDecision = frameBudgetController.update(
            with: feedback,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            now: now
        )
        if mediaPathProfile.usesAwdlRadioPolicy {
            await logAwdlReceiverFeedbackIfNeeded(
                now: now,
                feedback: feedback,
                decision: transportDecision
            )
        }

        if let transportDecision {
            await applyTransportFeedbackDecision(transportDecision, now: now)
        }
        if let frameBudgetDecision {
            await applyFrameBudgetDecision(frameBudgetDecision, now: now)
        }
    }

    private func applyReceiverFrameAcknowledgements(
        _ ranges: [MediaFeedbackFrameRange],
        now: CFAbsoluteTime
    ) {
        guard !ranges.isEmpty else { return }

        var newestAckedFrame = receiverAcknowledgedFrameNumber
        for range in ranges where isFrameNumber(range.endFrame, newerThan: newestAckedFrame) {
            newestAckedFrame = range.endFrame
        }
        guard let ackedFrame = newestAckedFrame,
              isFrameNumber(ackedFrame, newerThan: receiverAcknowledgedFrameNumber) else {
            return
        }

        receiverAcknowledgedFrameNumber = ackedFrame
        lastReceiverAckTime = now
        if let completion = recentFrameTransportCompletions.last(where: { $0.frameNumber == ackedFrame }) {
            receiverAckLagMs = max(0, (now - completion.completedAt) * 1000)
        }
    }

    private func isFrameNumber(_ frameNumber: UInt32, newerThan current: UInt32?) -> Bool {
        guard let current else { return true }
        let difference = frameNumber &- current
        return difference != 0 && difference < 0x8000_0000
    }

    private func applyTransportFeedbackDecision(
        _ decision: HostStreamTransportController.Decision,
        now: CFAbsoluteTime
    ) async {
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            decision.qualityRaiseSuppressionDeadline
        )
        transportFrameAdmissionTargetFPS = decision.frameAdmissionTargetFPS
        transportFrameAdmissionDeadline = decision.frameAdmissionDeadline
        refreshReceiverFrameAdmission(now: now)
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

    func applyFrameBudgetDecision(
        _ decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) async {
        realtimePressureState = decision.state
        realtimePressureReason = decision.reason.rawValue
        realtimeRuntimeBitrateCeilingBps = frameBudgetController.runtimeCeilingBps
        realtimeRuntimeQualityCeiling = decision.state == .observing ? nil : decision.qualityCeiling
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            decision.qualityRaiseSuppressionDeadline
        )
        realtimeFrameAdmissionTargetFPS = nil
        realtimeFrameAdmissionDeadline = 0
        refreshReceiverFrameAdmission(now: now)

        await applyRealtimeBudgetBitrate(
            decision.targetBitrateBps,
            ceilingBitrateBps: realtimeRuntimeBitrateCeilingBps,
            reason: decision.reason.rawValue
        )
        await applyFrameBudgetQuality(decision)

        logReceiverFrameAdmissionChangeIfNeeded(
            now: now,
            trigger: frameAdmissionTrigger(for: decision)
        )
        logRealtimeBudgetDecisionIfNeeded(now: now, decision: decision)
    }

    func receiverFrameAdmissionIsActive(now: CFAbsoluteTime) -> Bool {
        refreshReceiverFrameAdmission(now: now)
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

    @discardableResult
    private func refreshReceiverFrameAdmission(now: CFAbsoluteTime) -> Bool {
        if transportFrameAdmissionDeadline > 0, now >= transportFrameAdmissionDeadline {
            transportFrameAdmissionTargetFPS = nil
            transportFrameAdmissionDeadline = 0
        }
        if realtimeFrameAdmissionDeadline > 0, now >= realtimeFrameAdmissionDeadline {
            realtimeFrameAdmissionTargetFPS = nil
            realtimeFrameAdmissionDeadline = 0
        }

        var candidates: [(targetFPS: Int, deadline: CFAbsoluteTime)] = []
        if let targetFPS = transportFrameAdmissionTargetFPS, targetFPS < currentFrameRate {
            candidates.append((targetFPS, transportFrameAdmissionDeadline))
        }
        if let targetFPS = realtimeFrameAdmissionTargetFPS, targetFPS < currentFrameRate {
            candidates.append((targetFPS, realtimeFrameAdmissionDeadline))
        }
        let nextTarget = candidates.map(\.targetFPS).min()
        let nextDeadline = candidates.map(\.deadline).max() ?? 0
        let changed = receiverFrameAdmissionTargetFPS != nextTarget ||
            receiverFrameAdmissionDeadline != nextDeadline
        receiverFrameAdmissionTargetFPS = nextTarget
        receiverFrameAdmissionDeadline = nextDeadline
        if nextTarget == nil {
            receiverFrameAdmissionLastAdmitTime = 0
        }
        return changed
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

    private func applyFrameBudgetQuality(_ decision: HostFrameBudgetDecision) async {
        let previousQuality = activeQuality
        qualityCeiling = min(resolvedQualityCeiling, decision.qualityCeiling)
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: min(decision.keyframeQuality, qualityCeiling)
        )
        activeQuality = max(qualityFloor, min(qualityCeiling, decision.quality))
        guard abs(Double(activeQuality - previousQuality)) > 0.0001 else { return }
        await encoder?.updateQuality(activeQuality)
        MirageLogger.metrics(
            "Frame budget updated quality for stream \(streamID): " +
                "active=\(formatAwdlMetric(Double(activeQuality))) " +
                "ceiling=\(formatAwdlMetric(Double(qualityCeiling))) reason=\(decision.reason.rawValue)"
        )
    }

    private func frameAdmissionTrigger(
        for decision: HostFrameBudgetDecision
    ) -> HostStreamTransportController.FrameAdmissionTrigger {
        switch decision.reason {
        case .pFrameLatency:
            return .clientPFrameLatency
        case .receiverCadence,
             .receiverBacklog:
            return .clientReassemblyBacklog
        case .receiverLoss:
            return .clientTransportLoss
        case .clientRecovery:
            return .clientRecovery
        case .senderDeadline:
            return .clientTransportLoss
        default:
            return .clear
        }
    }

    private func logRealtimeBudgetDecisionIfNeeded(
        now: CFAbsoluteTime,
        decision: HostFrameBudgetDecision
    ) {
        let admission = receiverFrameAdmissionIsActive(now: now) ? receiverFrameAdmissionTargetFPS : nil
        guard realtimeLastLoggedState != decision.state ||
            realtimeLastLoggedBitrateCeilingBps != realtimeRuntimeBitrateCeilingBps ||
            realtimeLastLoggedAdmissionTargetFPS != admission ||
            now - realtimeLastLogTime >= 2.0 else {
            return
        }
        realtimeLastLogTime = now
        realtimeLastLoggedState = decision.state
        realtimeLastLoggedBitrateCeilingBps = realtimeRuntimeBitrateCeilingBps
        realtimeLastLoggedAdmissionTargetFPS = admission

        let ceilingText = realtimeRuntimeBitrateCeilingBps
            .map { mirageFormattedMegabitRate($0) }
            ?? "unknown"
        let currentBitrateText = (currentTargetBitrateBps ?? encoderConfig.bitrate)
            .map { mirageFormattedMegabitRate($0) }
            ?? "auto"
        let admissionText = admission.map { "\($0)fps" } ?? "none"
        let qualityText = realtimeRuntimeQualityCeiling
            .map { formatAwdlMetric(Double($0)) }
            ?? "none"
        MirageLogger.metrics(
            "Frame budget: stream=\(streamID) " +
                "state=\(decision.state.rawValue) reason=\(decision.reason.rawValue) " +
                "runtimeCeiling=\(ceilingText) currentBitrate=\(currentBitrateText) " +
                "qualityCeiling=\(qualityText) admission=\(admissionText) " +
                "frameBytes=\(decision.maxFrameBytes) wireBytes=\(decision.maxWireBytes) packets=\(decision.maxPacketCount)"
        )
    }

    private func mirageFormattedMegabitRate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000.0
        return "\(mbps.formatted(.number.precision(.fractionLength(1))))Mbps"
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
