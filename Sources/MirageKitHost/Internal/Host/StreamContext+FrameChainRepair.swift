//
//  StreamContext+FrameChainRepair.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//
//  Host-side encoded-frame chain repair state.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    var frameChainSuppressesPFrames: Bool {
        if emergencyRecoveryScaleChangeInProgress { return true }
        return switch frameChainState {
        case .chainBroken,
             .emergencyKeyframePending:
            true
        case .normal,
             .postKeyframeCooling:
            false
        }
    }

    func startFrameChainRepair(
        reason: String,
        firstBrokenFrame: UInt32? = nil,
        now: CFAbsoluteTime
    ) {
        suppressEncodedNonKeyframesUntilKeyframe = true
        adaptiveFrameCoordinator.startKeyframeBarrier(
            kind: .recovery,
            reason: reason,
            now: now
        )
        switch frameChainState {
        case .chainBroken,
             .emergencyKeyframePending:
            return
        case .normal,
             .postKeyframeCooling:
            frameChainState = .chainBroken(
                reason: reason,
                firstBrokenFrame: firstBrokenFrame,
                openedAt: now
            )
        }
    }

    func enterSenderDeadlineRecoveryModeIfNeeded(
        reason: StreamPacketSender.DependencyFrameDropReason,
        now: CFAbsoluteTime
    ) {
        guard reason == .transportDrop,
              mediaPathProfile.usesLocalBulkTransportPolicy,
              encoderConfig.codec != .proRes4444 else {
            return
        }
        let recoveryCeiling = currentStreamQualityContract().localMotionQualityFloor
        guard recoveryCeiling > 0 else { return }
        let previous = senderDeadlineRecoveryQualityCeiling
        senderDeadlineRecoveryQualityCeiling = min(previous ?? recoveryCeiling, recoveryCeiling)
        guard previous == nil || abs(Double((previous ?? 0) - recoveryCeiling)) > 0.0001 else { return }
        MirageLogger.metrics(
            "Sender-deadline recovery quality ceiling armed for stream \(streamID): " +
                "quality=\(recoveryCeiling.formatted(.number.precision(.fractionLength(2))))"
        )
    }

    @discardableResult
    func scheduleEmergencyChainRepairKeyframe(
        reason: String,
        bypassesRecoveryCooldown: Bool,
        supersedesInFlightGeometry: Bool = false,
        now: CFAbsoluteTime
    ) async -> Bool {
        if case .emergencyKeyframePending = frameChainState {
            return false
        }
        guard bypassesRecoveryCooldown || !isRecoveryKeyframeCooldownActive(now: now) else {
            logRecoveryKeyframeCooldownSuppression(reason: reason, now: now)
            scheduleFrameChainRepairKeyframeRetry(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown
            )
            return false
        }
        if pendingEmergencyKeyframeQuality == nil {
            pendingEmergencyKeyframeQuality = emergencyKeyframeQuality()
        }
        if bypassesRecoveryCooldown {
            lastKeyframeRequestTime = 0
        }
        let queued = await scheduleCoalescedRecoveryKeyframe(
            reason: reason,
            noteLoss: false,
            requiresFlush: true,
            requiresReset: true,
            advanceEpochOnReset: true,
            ignoreExistingInFlight: false,
            supersedesInFlightGeometry: supersedesInFlightGeometry,
            bypassesRecoveryCooldown: bypassesRecoveryCooldown
        )
        guard queued else {
            scheduleFrameChainRepairKeyframeRetry(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown
            )
            return false
        }
        frameChainRepairKeyframeRetryTask?.cancel()
        frameChainRepairKeyframeRetryTask = nil
        frameChainState = .emergencyKeyframePending(reason: reason, openedAt: now)
        scheduleFrameChainRepairKeyframeProgressCheck(
            reason: reason,
            bypassesRecoveryCooldown: bypassesRecoveryCooldown
        )
        return true
    }

    func emergencyKeyframeQuality() -> Float {
        let base = min(pendingEmergencyKeyframeQuality ?? activeQuality, keyframeQuality)
        let floor = emergencyKeyframeQualityFloor()
        if mediaPathProfile.usesAwdlRadioPolicy {
            guard currentAwdlQualityReductionAllowed() else {
                return min(
                    resolvedQualityCeiling,
                    max(floor, min(base, activeQuality, keyframeQuality, resolvedQualityCeiling))
                )
            }
            let recoveryScale: Float = 0.50
            return min(
                resolvedQualityCeiling,
                max(floor, min(base, activeQuality * recoveryScale, resolvedQualityCeiling * recoveryScale))
            )
        }
        return min(
            resolvedQualityCeiling,
            max(floor, min(base, activeQuality * 0.65, resolvedQualityCeiling * 0.65))
        )
    }

    func noteEmergencyKeyframePrepared(using decision: HostFrameBudgetDecision?) async {
        var decisionQuality = decision?.keyframeQuality ?? emergencyKeyframeQuality()
        if let senderDeadlineRecoveryQualityCeiling {
            decisionQuality = min(decisionQuality, senderDeadlineRecoveryQualityCeiling)
        }
        let floor = emergencyKeyframeQualityFloor()
        let emergencyCeiling = max(floor, min(keyframeQuality, resolvedQualityCeiling))
        let effectiveEmergencyCeiling = senderDeadlineRecoveryQualityCeiling.map {
            max(floor, min($0, emergencyCeiling))
        } ?? emergencyCeiling
        if decision != nil {
            pendingEmergencyKeyframeQuality = max(
                floor,
                min(decisionQuality, effectiveEmergencyCeiling, resolvedQualityCeiling)
            )
        } else {
            pendingEmergencyKeyframeQuality = max(
                floor,
                min(decisionQuality, effectiveEmergencyCeiling, emergencyKeyframeQuality())
            )
        }
        if let pendingEmergencyKeyframeQuality {
            await encoder?.prepareForKeyframe(quality: pendingEmergencyKeyframeQuality)
        }
    }

    private func emergencyKeyframeQualityFloor() -> Float {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return 0.02 }
        return resolvedRuntimeKeyframeQualityFloor(for: resolvedQualityCeiling)
    }

    @discardableResult
    func advanceEmergencyRecoveryScaleIfPossible(reason: String, now: CFAbsoluteTime) async -> Bool {
        guard !emergencyRecoveryScaleChangeInProgress else { return false }
        let nextIndex = emergencyRecoveryScaleIndex + 1
        guard nextIndex < Self.emergencyRecoveryScaleFactors.count else { return false }

        let baseScale = emergencyRecoveryBaseStreamScale ?? requestedStreamScale
        emergencyRecoveryBaseStreamScale = baseScale
        let nextScale = StreamContext.clampStreamScale(
            baseScale * Self.emergencyRecoveryScaleFactors[nextIndex]
        )
        guard abs(Double(nextScale - streamScale)) > 0.0001 else {
            emergencyRecoveryScaleIndex = nextIndex
            return true
        }

        emergencyRecoveryScaleChangeInProgress = true
        defer { emergencyRecoveryScaleChangeInProgress = false }
        do {
            try await updateEmergencyRecoveryScale(nextScale, reason: reason)
            emergencyRecoveryScaleIndex = nextIndex
            emergencyRecoveryCleanPFrames = 0
            startFrameChainRepair(reason: reason, now: now)
            await noteEmergencyKeyframePrepared(using: nil)
            MirageLogger.metrics(
                "Emergency recovery scale lowered for stream \(streamID): " +
                    "scale=\(String(format: "%.2f", Double(nextScale))) " +
                    "token=\(dimensionToken) reason=\(reason)"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "Emergency recovery scale update failed: ")
            return false
        }
    }

    func handleFrameTransportCompleted(_ completion: StreamPacketSender.FrameTransportCompletion) async {
        guard completion.streamID == streamID else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let frameNumber = completion.frameNumber
        let isKeyframe = completion.isKeyframe
        let didSend = completion.didSend
        adaptiveFrameCoordinator.noteFrameTransportCompletion(
            frameNumber: frameNumber,
            didSend: didSend,
            queuedUnreliableDropCount: completion.queuedUnreliableDropCounts.total,
            now: now
        )

        if didSend {
            recordFrameTransportCompletion(completion)
            await applyFrameTransportBudgetFeedback(completion, now: now)
        }

        if isKeyframe {
            if didSend {
                frameChainRepairKeyframeRetryTask?.cancel()
                frameChainRepairKeyframeRetryTask = nil
                lastSuccessfulKeyframeSendTime = now
                if keyframeInFlightFrameNumber == frameNumber {
                    keyframeInFlightFrameNumber = nil
                }
                logKeyframeTransportCompletion(completion)
                let senderQueuedBytes = packetSender?.queuedByteCount ?? 0
                let allowsStartupLocalRelease = !usesDependencyKeyframeReceiverAcceptanceGate &&
                    senderQueuedBytes <= queuePressureBytes
                if let release = adaptiveFrameCoordinator.noteKeyframeTransportCompletion(
                    frameNumber: frameNumber,
                    didSend: true,
                    allowsStartupLocalRelease: allowsStartupLocalRelease,
                    now: now
                ) {
                    releaseAdaptiveKeyframeBarrier(release)
                    return
                }
                handleSuccessfulKeyframeTransport(frameNumber: frameNumber)
            } else {
                if let release = adaptiveFrameCoordinator.noteKeyframeTransportCompletion(
                    frameNumber: frameNumber,
                    didSend: false,
                    allowsStartupLocalRelease: false,
                    now: now
                ) {
                    releaseAdaptiveKeyframeBarrier(release)
                }
                handleFailedKeyframeTransport(frameNumber: frameNumber, now: now)
            }
            return
        }

        guard didSend else {
            logFailedPFrameTransport(completion)
            await applyFrameTransportBudgetFeedback(completion, now: now)
            await handlePacketSenderDependencyFrameDrop(
                streamID: completion.streamID,
                frameNumber: frameNumber,
                reason: .transportDrop
            )
            return
        }
        await handleCleanPFrameTransport(frameNumber: frameNumber, now: now)
        scheduleProcessingIfNeeded()
    }

    private func logFailedPFrameTransport(_ completion: StreamPacketSender.FrameTransportCompletion) {
        let sendMs = completion.sendCompletionMs.formatted(.number.precision(.fractionLength(1)))
        let transportMs = completion.transportDurationMs.formatted(.number.precision(.fractionLength(1)))
        let drops = completion.queuedUnreliableDropCounts
        MirageLogger.stream(
            "event=p_frame_transport_failure stream=\(streamID) frame=\(completion.frameNumber) " +
                "frameBytes=\(completion.frameByteCount) wireBytes=\(completion.wireBytes) " +
                "packets=\(completion.packetCount) sendMs=\(sendMs) transportMs=\(transportMs) " +
                "deadlineExpired=\(drops.deadlineExpired) queueLimit=\(drops.queueLimit) " +
                "superseded=\(drops.superseded) unsupportedTransport=\(drops.unsupportedTransport) " +
                "closed=\(drops.closed) token=\(completion.dimensionToken)"
        )
    }

    private func recordFrameTransportCompletion(_ completion: StreamPacketSender.FrameTransportCompletion) {
        recentFrameTransportCompletions.append(completion)
        if recentFrameTransportCompletions.count > recentFrameTransportCompletionLimit {
            recentFrameTransportCompletions.removeFirst(
                recentFrameTransportCompletions.count - recentFrameTransportCompletionLimit
            )
        }
    }

    private func handleSuccessfulKeyframeTransport(frameNumber: UInt32) {
        let wasRepairing: Bool
        switch frameChainState {
        case .chainBroken,
             .emergencyKeyframePending:
            wasRepairing = true
        case .normal,
             .postKeyframeCooling:
            wasRepairing = suppressEncodedNonKeyframesUntilKeyframe
        }

        if wasRepairing {
            cancelPacketSenderDependencyRecoveryKeyframeRetry()
            pendingReceiverAcceptedKeyframeFrameNumber = frameNumber
            let gateReason = pendingReceiverAcceptedKeyframeReason ?? "frame-chain repair"
            pendingReceiverAcceptedKeyframeReason = gateReason
            MirageLogger.metrics(
                "Dependency keyframe sent for stream \(streamID): " +
                    "frame=\(frameNumber) reason=\(gateReason); " +
                    "waiting for receiver acceptance before resuming P-frames"
            )
            scheduleReceiverKeyframeAcceptanceFallbackIfNeeded(
                frameNumber: frameNumber,
                reason: gateReason
            )
        }
    }

    func handleReceiverAcceptedKeyframe(
        frameNumber: UInt32,
        evidence: String
    ) {
        guard pendingReceiverAcceptedKeyframeFrameNumber == frameNumber else { return }
        let gateReason = pendingReceiverAcceptedKeyframeReason ?? "frame-chain repair"
        let adaptiveRelease = adaptiveFrameCoordinator.noteReceiverAcceptedKeyframe(
            frameNumber: frameNumber,
            now: CFAbsoluteTimeGetCurrent()
        )
        let wasRepairing: Bool
        switch frameChainState {
        case .chainBroken,
             .emergencyKeyframePending:
            wasRepairing = true
        case .normal,
             .postKeyframeCooling:
            wasRepairing = suppressEncodedNonKeyframesUntilKeyframe
        }

        pendingReceiverAcceptedKeyframeFrameNumber = nil
        pendingReceiverAcceptedKeyframeReason = nil
        suppressEncodedNonKeyframesUntilKeyframe = false
        latestReceiverRecoveryCause = .none
        pendingEmergencyKeyframeQuality = nil
        senderDeadlineRecoveryQualityCeiling = nil
        receiverKeyframeAcceptanceFallbackTask?.cancel()
        receiverKeyframeAcceptanceFallbackTask = nil
        cancelPacketSenderDependencyRecoveryKeyframeRetry()
        adaptivePFrameController.resetEncodedOvershootHistory()
        if wasRepairing {
            frameChainState = .postKeyframeCooling(
                untilCleanPFrames: postEmergencyKeyframeCleanPFrameCount
            )
            MirageLogger.metrics(
                "Dependency keyframe accepted for stream \(streamID): " +
                    "frame=\(frameNumber) evidence=\(evidence) reason=\(gateReason) " +
                "cooling until \(postEmergencyKeyframeCleanPFrameCount) clean P-frames"
            )
        }
        if let adaptiveRelease {
            releaseAdaptiveKeyframeBarrier(adaptiveRelease)
        }
        scheduleProcessingIfNeeded()
    }

    private func handleFailedKeyframeTransport(frameNumber: UInt32, now: CFAbsoluteTime) {
        if let gateReason = pendingReceiverAcceptedKeyframeReason {
            pendingReceiverAcceptedKeyframeFrameNumber = nil
            pendingReceiverAcceptedKeyframeReason = nil
            receiverKeyframeAcceptanceFallbackTask?.cancel()
            receiverKeyframeAcceptanceFallbackTask = nil
            let repairStillActive = switch frameChainState {
            case .chainBroken,
                 .emergencyKeyframePending:
                true
            case .normal,
                 .postKeyframeCooling:
                false
            }
            suppressEncodedNonKeyframesUntilKeyframe = repairStillActive
            MirageLogger.stream(
                "Dependency keyframe transport failed for stream \(streamID): " +
                    "frame=\(frameNumber) reason=\(gateReason); " +
                    "\(repairStillActive ? "repair remains active" : "releasing receiver acceptance gate")"
            )
            if !repairStillActive {
                scheduleProcessingIfNeeded()
            }
        }
        if pendingReceiverAcceptedKeyframeFrameNumber == frameNumber {
            pendingReceiverAcceptedKeyframeFrameNumber = nil
        }
        switch frameChainState {
        case let .emergencyKeyframePending(reason, _):
            frameChainState = .chainBroken(
                reason: reason,
                firstBrokenFrame: frameNumber,
                openedAt: now
            )
            suppressEncodedNonKeyframesUntilKeyframe = true
            adaptiveFrameCoordinator.startKeyframeBarrier(
                kind: .recovery,
                reason: reason,
                now: now
            )
            scheduleFrameChainRepairKeyframeRetry(
                reason: reason,
                bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError
            )
        case .normal,
             .chainBroken,
             .postKeyframeCooling:
            break
        }
    }

    private func handleCleanPFrameTransport(frameNumber: UInt32, now: CFAbsoluteTime) async {
        if case let .postKeyframeCooling(remaining) = frameChainState {
            let nextRemaining = max(0, remaining - 1)
            if nextRemaining == 0 {
                frameChainState = .normal
                cancelPacketSenderDependencyRecoveryKeyframeRetry()
                senderDeadlineRecoveryQualityCeiling = nil
                MirageLogger.metrics(
                    "Post-keyframe chain cooling complete for stream \(streamID) at frame \(frameNumber)"
                )
            } else {
                frameChainState = .postKeyframeCooling(untilCleanPFrames: nextRemaining)
            }
        }

        guard emergencyRecoveryBaseStreamScale != nil else { return }
        emergencyRecoveryCleanPFrames += 1
        guard frameChainState == .normal,
              emergencyRecoveryCleanPFrames >= recoveryScaleRestoreCleanPFrameCount,
              lastSuccessfulKeyframeSendTime > 0,
              now - lastSuccessfulKeyframeSendTime >= recoveryKeyframeCooldown else {
            return
        }
        await restoreEmergencyRecoveryScaleIfReady(now: now)
    }

    private func restoreEmergencyRecoveryScaleIfReady(now: CFAbsoluteTime) async {
        guard !emergencyRecoveryScaleChangeInProgress,
              pendingKeyframeReason == nil,
              let baseScale = emergencyRecoveryBaseStreamScale else {
            return
        }
        guard receiverCanRestoreEmergencyRecoveryScale(now: now) else { return }
        let nextIndex = max(0, emergencyRecoveryScaleIndex - 1)
        let targetScale = StreamContext.clampStreamScale(
            baseScale * Self.emergencyRecoveryScaleFactors[nextIndex]
        )
        emergencyRecoveryScaleChangeInProgress = true
        defer { emergencyRecoveryScaleChangeInProgress = false }
        do {
            try await updateEmergencyRecoveryScale(targetScale, reason: "restore")
            emergencyRecoveryScaleIndex = nextIndex
            emergencyRecoveryCleanPFrames = 0
            if nextIndex == 0 {
                emergencyRecoveryBaseStreamScale = nil
            }
            startFrameChainRepair(reason: "emergency-recovery-scale-restore", now: now)
            await noteEmergencyKeyframePrepared(using: nil)
            await scheduleEmergencyChainRepairKeyframe(
                reason: "Emergency recovery scale restore",
                bypassesRecoveryCooldown: false,
                now: now
            )
            MirageLogger.metrics(
                "Emergency recovery scale restored for stream \(streamID): " +
                    "scale=\(String(format: "%.2f", Double(targetScale))) token=\(dimensionToken)"
            )
        } catch {
            MirageLogger.error(.stream, error: error, message: "Emergency recovery scale restore failed: ")
        }
    }

    private func receiverCanRestoreEmergencyRecoveryScale(now: CFAbsoluteTime) -> Bool {
        guard lastReceiverFeedbackTime > 0,
              now - lastReceiverFeedbackTime <= 1.0,
              receiverFrameBudgetIsHealthy(now: now),
              receiverCapacityLearningQuarantineUntil <= now,
              receiverDecodeBacklogFrames == 0,
              receiverPresentationBacklogFrames == 0,
              let latestPresentedFrameAgeMs = receiverLatestPresentedFrameAgeMs,
              latestPresentedFrameAgeMs <= 500 else {
            return false
        }
        return receiverLatestPresentedFrameNumber != nil
    }

    private func logKeyframeTransportCompletion(_ completion: StreamPacketSender.FrameTransportCompletion) {
        let reason: String = switch frameChainState {
        case .normal:
            "normal"
        case let .chainBroken(reason, _, _):
            reason
        case let .emergencyKeyframePending(reason, _):
            reason
        case .postKeyframeCooling:
            "post-keyframe-cooling"
        }
        let sendMs = completion.sendCompletionMs.formatted(.number.precision(.fractionLength(2)))
        let transportMs = completion.transportDurationMs.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.metrics(
            "Keyframe transport complete stream=\(streamID) frame=\(completion.frameNumber) " +
                "token=\(completion.dimensionToken) scale=\(String(format: "%.2f", Double(streamScale))) " +
                "frameBytes=\(completion.frameByteCount) wireBytes=\(completion.wireBytes) " +
                "packets=\(completion.packetCount) sendMs=\(sendMs) transportMs=\(transportMs) " +
                "reason=\(reason)"
        )
    }

    private func scheduleReceiverKeyframeAcceptanceFallbackIfNeeded(
        frameNumber: UInt32,
        reason: String
    ) {
        guard pendingReceiverAcceptedKeyframeReason != nil else { return }
        receiverKeyframeAcceptanceFallbackTask?.cancel()
        let delaySeconds = receiverKeyframeAcceptanceFallbackDelay()
        receiverKeyframeAcceptanceFallbackTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.releaseReceiverKeyframeAcceptanceGateIfTimedOut(
                frameNumber: frameNumber,
                reason: reason
            )
        }
    }

    private func releaseReceiverKeyframeAcceptanceGateIfTimedOut(
        frameNumber: UInt32,
        reason: String
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard pendingReceiverAcceptedKeyframeFrameNumber == frameNumber,
              pendingReceiverAcceptedKeyframeReason == reason else {
            return
        }
        let adaptiveRelease = adaptiveFrameCoordinator.releaseKeyframeBarrierAfterReceiverAcceptanceTimeout(
            frameNumber: frameNumber,
            now: now
        )
        pendingReceiverAcceptedKeyframeFrameNumber = nil
        pendingReceiverAcceptedKeyframeReason = nil
        suppressEncodedNonKeyframesUntilKeyframe = false
        receiverKeyframeAcceptanceFallbackTask = nil
        MirageLogger.stream(
            "Receiver acceptance timed out for dependency keyframe stream=\(streamID) " +
                "frame=\(frameNumber) reason=\(reason); resuming P-frames"
        )
        if let adaptiveRelease {
            releaseAdaptiveKeyframeBarrier(adaptiveRelease)
        } else {
            scheduleProcessingIfNeeded()
        }
    }

    func scheduleFrameChainRepairKeyframeRetry(
        reason: String,
        bypassesRecoveryCooldown: Bool
    ) {
        frameChainRepairKeyframeRetryTask?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let delaySeconds = frameChainRepairKeyframeRetryDelay(
            now: now,
            bypassesRecoveryCooldown: bypassesRecoveryCooldown
        )
        frameChainRepairKeyframeRetryTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.retryFrameChainRepairKeyframe(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown
            )
        }
        let delayMs = Int((delaySeconds * 1000).rounded())
        MirageLogger.stream(
            "Scheduled frame-chain repair keyframe retry in \(delayMs)ms (\(reason))"
        )
    }

    private func scheduleFrameChainRepairKeyframeProgressCheck(
        reason: String,
        bypassesRecoveryCooldown: Bool
    ) {
        guard isRunning, shouldEncodeFrames else { return }
        frameChainRepairKeyframeRetryTask?.cancel()
        let delaySeconds = frameChainRepairKeyframeProgressCheckDelay(reason: reason)
        frameChainRepairKeyframeRetryTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.retryFrameChainRepairKeyframe(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown
            )
        }
    }

    private func frameChainRepairKeyframeProgressCheckDelay(reason: String) -> CFAbsoluteTime {
        if hasProtectedGeometryRecoveryKeyframe ||
            pendingKeyframeReason.map(isGeometryRecoveryKeyframeReason) == true ||
            isGeometryRecoveryKeyframeReason(reason) {
            return max(0.35, activeKeyframeRequestCooldown)
        }
        return 0.05
    }

    private func frameChainRepairKeyframeRetryDelay(
        now: CFAbsoluteTime,
        bypassesRecoveryCooldown: Bool
    ) -> CFAbsoluteTime {
        let inFlightDelay = max(0, keyframeSendDeadline - now)
        let requestDelay: CFAbsoluteTime
        if bypassesRecoveryCooldown {
            requestDelay = 0
        } else if lastKeyframeRequestTime > 0 {
            requestDelay = max(0, activeKeyframeRequestCooldown - (now - lastKeyframeRequestTime))
        } else {
            requestDelay = 0
        }
        let recoveryDelay = bypassesRecoveryCooldown ? 0 : recoveryKeyframeCooldownRemaining(now: now)
        return max(0.05, inFlightDelay, requestDelay, recoveryDelay)
    }

    private func retryFrameChainRepairKeyframe(
        reason: String,
        bypassesRecoveryCooldown: Bool
    ) async {
        frameChainRepairKeyframeRetryTask = nil
        guard isRunning, shouldEncodeFrames else { return }
        switch frameChainState {
        case .chainBroken:
            await scheduleEmergencyChainRepairKeyframe(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown,
                now: CFAbsoluteTimeGetCurrent()
            )
        case let .emergencyKeyframePending(pendingReason, openedAt):
            let now = CFAbsoluteTimeGetCurrent()
            if pendingReceiverAcceptedKeyframeFrameNumber != nil ||
                keyframeInFlightFrameNumber != nil {
                guard now - openedAt >= emergencyKeyframeReceiverAcceptanceTimeout else {
                    scheduleFrameChainRepairKeyframeProgressCheck(
                        reason: reason,
                        bypassesRecoveryCooldown: bypassesRecoveryCooldown
                    )
                    return
                }
                MirageLogger.stream(
                    "Emergency recovery keyframe receiver acceptance timed out; " +
                        "requeueing (\(pendingReason))"
                )
                pendingReceiverAcceptedKeyframeFrameNumber = nil
                keyframeInFlightFrameNumber = nil
                frameChainState = .chainBroken(
                    reason: pendingReason,
                    firstBrokenFrame: nil,
                    openedAt: now
                )
                await scheduleEmergencyChainRepairKeyframe(
                    reason: pendingReason,
                    bypassesRecoveryCooldown: bypassesRecoveryCooldown,
                    now: now
                )
                return
            }
            if isKeyframeEncoding {
                scheduleFrameChainRepairKeyframeProgressCheck(
                    reason: reason,
                    bypassesRecoveryCooldown: bypassesRecoveryCooldown
                )
                return
            }
            if pendingKeyframeReason != nil {
                scheduleProcessingForPendingKeyframe(reason: reason)
                scheduleFrameChainRepairKeyframeProgressCheck(
                    reason: reason,
                    bypassesRecoveryCooldown: bypassesRecoveryCooldown
                )
                return
            }
            frameChainState = .chainBroken(
                reason: pendingReason,
                firstBrokenFrame: nil,
                openedAt: openedAt
            )
            MirageLogger.stream(
                "Frame-chain repair keyframe made no encode progress; requeueing (\(pendingReason))"
            )
            await scheduleEmergencyChainRepairKeyframe(
                reason: pendingReason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown,
                now: now
            )
        case .normal,
             .postKeyframeCooling:
            break
        }
    }
}

private extension StreamContext {
    static let emergencyRecoveryScaleFactors: [CGFloat] = [1.0, 0.75, 0.5]

    var emergencyKeyframeReceiverAcceptanceTimeout: CFAbsoluteTime {
        let playoutSeconds = max(0, receiverPlayoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs) / 1_000
        let constrainedTimeout = max(activeKeyframeInFlightCap, playoutSeconds + 1.0)
        return mediaPathProfile.usesAwdlRadioPolicy ? constrainedTimeout : activeKeyframeInFlightCap
    }

    func receiverKeyframeAcceptanceFallbackDelay() -> CFAbsoluteTime {
        let playoutSeconds = max(0, receiverPlayoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs) / 1_000
        return max(activeKeyframeInFlightCap, playoutSeconds + 0.5)
    }
}
#endif
