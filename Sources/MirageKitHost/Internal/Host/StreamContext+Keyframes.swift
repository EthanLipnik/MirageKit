//
//  StreamContext+Keyframes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Keyframe scheduling and motion heuristics.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func markDiscontinuity(reason: String, advanceEpoch: Bool) {
        if dynamicFrameFlags.contains(.discontinuity) { return }
        if advanceEpoch { epoch &+= 1 }
        dynamicFrameFlags.insert(.discontinuity)
        if advanceEpoch { MirageLogger.stream("Stream epoch advanced to \(epoch) (\(reason))") } else {
            MirageLogger.stream("Stream discontinuity flagged without epoch bump (\(reason))")
        }
    }

    var usesConstrainedKeyframeInFlightWindow: Bool {
        mediaPathProfile.usesAwdlRadioPolicy || transportPathKind == .cellular
    }

    func markKeyframeInFlight(frameNumber: UInt32? = nil) {
        let deadline = CFAbsoluteTimeGetCurrent() + activeKeyframeInFlightCap
        if deadline > keyframeSendDeadline { keyframeSendDeadline = deadline }
        if let frameNumber {
            keyframeInFlightFrameNumber = frameNumber
        }
    }

    var activeKeyframeRequestCooldown: CFAbsoluteTime {
        usesConstrainedKeyframeInFlightWindow ? 1.5 : keyframeRequestCooldown
    }

    var activeKeyframeInFlightCap: CFAbsoluteTime {
        usesConstrainedKeyframeInFlightWindow ? 1.5 : keyframeInFlightCap
    }

    func extendConstrainedKeyframeInFlightDeadline(
        now: CFAbsoluteTime,
        requestLabel: String
    ) {
        guard usesConstrainedKeyframeInFlightWindow else { return }
        let extendedDeadline = now + activeKeyframeInFlightCap
        guard extendedDeadline > keyframeSendDeadline else { return }
        keyframeSendDeadline = extendedDeadline
        let deadlineMs = Int(((keyframeSendDeadline - now) * 1000).rounded())
        MirageLogger.stream(
                "\(requestLabel) extended constrained-path keyframe in-flight deadline "
                + "frame=\(keyframeInFlightFrameNumber.map { String($0) } ?? "nil") "
                + "deadlineMs=\(deadlineMs) path=\(transportPathKind.rawValue) media=\(mediaPathProfile.rawValue)"
        )
    }

    func shouldThrottleKeyframeRequest(
        requestLabel: String,
        checkInFlight: Bool,
        countsAgainstRecoveryBudget: Bool = true
    ) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if checkInFlight, now < keyframeSendDeadline {
            extendConstrainedKeyframeInFlightDeadline(now: now, requestLabel: requestLabel)
            let remaining = Int(((keyframeSendDeadline - now) * 1000).rounded())
            MirageLogger.stream(
                "\(requestLabel) skipped (keyframe in flight, \(remaining)ms remaining, "
                    + "frame=\(keyframeInFlightFrameNumber.map { String($0) } ?? "nil"))"
            )
            return true
        }
        let elapsed = now - lastKeyframeRequestTime
        let requestCooldown = activeKeyframeRequestCooldown
        if elapsed < requestCooldown {
            let remaining = Int(((requestCooldown - elapsed) * 1000).rounded())
            MirageLogger.stream("\(requestLabel) skipped (cooldown \(remaining)ms)")
            return true
        }
        if mediaPathProfile.usesAwdlRadioPolicy, countsAgainstRecoveryBudget {
            recentKeyframeRequestTimes.removeAll { now - $0 > 10.0 }
            if recentKeyframeRequestTimes.count >= 3 {
                MirageLogger.stream("\(requestLabel) skipped (AWDL recovery keyframe budget exhausted)")
                return true
            }
            recentKeyframeRequestTimes.append(now)
        }
        lastKeyframeRequestTime = now
        return false
    }

    func queueKeyframe(
        reason: String,
        checkInFlight: Bool,
        requiresFlush: Bool = false,
        requiresReset: Bool = false,
        advanceEpochOnReset: Bool = true,
        urgent: Bool = false,
        countsAgainstRecoveryBudget: Bool = true
    )
    -> Bool {
        let effectiveCountsAgainstRecoveryBudget = countsAgainstRecoveryBudget && !requiresReset
        guard !shouldThrottleKeyframeRequest(
            requestLabel: reason,
            checkInFlight: checkInFlight,
            countsAgainstRecoveryBudget: effectiveCountsAgainstRecoveryBudget
        ) else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = reason
        if urgent {
            pendingKeyframeDeadline = now
            pendingKeyframeUrgent = true
        } else {
            pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
        }
        if requiresReset {
            markDiscontinuity(reason: reason, advanceEpoch: advanceEpochOnReset)
            pendingKeyframeRequiresReset = true
            pendingKeyframeRequiresFlush = true
        }
        if requiresFlush { pendingKeyframeRequiresFlush = true }
        return true
    }

    func queueKeyframeIfPossible(
        reason: String,
        checkInFlight: Bool,
        requiresFlush: Bool = false,
        requiresReset: Bool = false,
        advanceEpochOnReset: Bool = true,
        urgent: Bool = false,
        countsAgainstRecoveryBudget: Bool = true
    ) {
        _ = queueKeyframe(
            reason: reason,
            checkInFlight: checkInFlight,
            requiresFlush: requiresFlush,
            requiresReset: requiresReset,
            advanceEpochOnReset: advanceEpochOnReset,
            urgent: urgent,
            countsAgainstRecoveryBudget: countsAgainstRecoveryBudget
        )
    }

    func forceKeyframeAfterCaptureRestart(
        restartStreak: Int,
        shouldEscalateRecovery: Bool
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        if !mediaPathProfile.usesAwdlRadioPolicy, now >= keyframeSendDeadline {
            keyframeSendDeadline = 0
            lastKeyframeRequestTime = 0
        }
        let queued = queueKeyframe(
            reason: "Fallback keyframe",
            checkInFlight: true,
            requiresFlush: true,
            requiresReset: shouldEscalateRecovery,
            urgent: true,
            countsAgainstRecoveryBudget: false
        )
        if shouldEscalateRecovery {
            MirageLogger.stream("Capture restart escalation active (streak \(restartStreak))")
        }
        if !queued { MirageLogger.stream("Fallback keyframe skipped (unable to queue after restart)") }
    }

    func handlePacketSenderDependencyFrameDrop(
        streamID droppedStreamID: StreamID,
        frameNumber: UInt32,
        reason: StreamPacketSender.DependencyFrameDropReason
    ) async {
        guard droppedStreamID == streamID, isRunning else { return }
        let label = "Packet sender dependency drop"
        let queuedBytes = packetSender?.queuedByteCount ?? 0
        dependencyRecoveryPendingDropFrameNumber = frameNumber
        dependencyRecoveryPendingDropReason = reason
        dependencyRecoveryPendingQueuedBytes = queuedBytes
        dependencyRecoveryRetryNecessary = false
        MirageLogger.stream(
            "\(label) observed frame=\(frameNumber) reason=\(reason.rawValue) queuedBytes=\(queuedBytes)"
        )
        noteLossEvent(reason: label, enablePFrameFEC: false)
        let now = CFAbsoluteTimeGetCurrent()
        let budgetDecision = if reason == .staleChain {
            adaptivePFrameController.recordFreshnessPressure(
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
        } else {
            adaptivePFrameController.recordSenderDeadlineDrop(
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
        }
        await applyFrameBudgetDecision(budgetDecision, now: now)
        startFrameChainRepair(
            reason: "sender-dependency-drop",
            firstBrokenFrame: frameNumber,
            now: now
        )
        await noteEmergencyKeyframePrepared(using: budgetDecision)
        if isRecoveryKeyframeCooldownActive(now: now) {
            dependencyRecoveryRetryNecessary = true
            logRecoveryKeyframeCooldownSuppression(reason: label, now: now)
            scheduleFrameChainRepairKeyframeRetry(
                reason: label,
                bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError
            )
            return
        }
        let queued = await scheduleEmergencyChainRepairKeyframe(
            reason: label,
            bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError,
            now: now
        )
        guard queued else {
            dependencyRecoveryRetryNecessary = true
            MirageLogger.stream(
                "\(label) coalesced frame=\(frameNumber) reason=\(reason.rawValue) "
                    + "queuedBytes=\(queuedBytes) retryNecessary=true"
            )
            scheduleFrameChainRepairKeyframeRetry(
                reason: label,
                bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError
            )
            return
        }

        dependencyRecoveryKeyframeRetryTask?.cancel()
        dependencyRecoveryKeyframeRetryTask = nil
        MirageLogger.stream(
            "Scheduled coalesced keyframe after packet sender dependency drop "
                + "frame=\(frameNumber) reason=\(reason.rawValue) queuedBytes=\(queuedBytes) retryNecessary=false"
        )
    }

    private func schedulePacketSenderDependencyRecoveryKeyframeRetry(
        frameNumber: UInt32,
        reason: StreamPacketSender.DependencyFrameDropReason
    ) {
        dependencyRecoveryKeyframeRetryTask?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let delaySeconds = dependencyRecoveryKeyframeRetryDelay(now: now)
        dependencyRecoveryKeyframeRetryTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.retryPacketSenderDependencyRecoveryKeyframe(
                frameNumber: frameNumber,
                reason: reason
            )
        }
        let delayMs = Int((delaySeconds * 1000).rounded())
        MirageLogger.stream(
            "Scheduled packet sender dependency keyframe retry in \(delayMs)ms "
                + "frame=\(frameNumber) reason=\(reason.rawValue) "
                + "queuedBytes=\(dependencyRecoveryPendingQueuedBytes) retryNecessary=true"
        )
    }

    private func dependencyRecoveryKeyframeRetryDelay(now: CFAbsoluteTime) -> CFAbsoluteTime {
        let inFlightDelay = max(0, keyframeSendDeadline - now)
        let cooldownDelay: CFAbsoluteTime
        if lastKeyframeRequestTime > 0 {
            cooldownDelay = max(0, activeKeyframeRequestCooldown - (now - lastKeyframeRequestTime))
        } else {
            cooldownDelay = 0
        }
        let recoveryCooldownDelay = recoveryKeyframeCooldownRemaining(now: now)

        var budgetDelay: CFAbsoluteTime = 0
        if mediaPathProfile.usesAwdlRadioPolicy {
            recentKeyframeRequestTimes.removeAll { now - $0 > 10.0 }
            if recentKeyframeRequestTimes.count >= 3,
               let oldestRequest = recentKeyframeRequestTimes.first {
                budgetDelay = max(0, 10.0 - (now - oldestRequest))
            }
        }

        return max(0.05, inFlightDelay, cooldownDelay, recoveryCooldownDelay, budgetDelay) + 0.025
    }

    private func retryPacketSenderDependencyRecoveryKeyframe(
        frameNumber: UInt32,
        reason: StreamPacketSender.DependencyFrameDropReason
    ) async {
        dependencyRecoveryKeyframeRetryTask = nil
        guard isRunning else { return }
        let queuedBytes = packetSender?.queuedByteCount ?? dependencyRecoveryPendingQueuedBytes
        dependencyRecoveryPendingQueuedBytes = queuedBytes
        if let packetSender {
            let stillRequiresRecovery = await packetSender.requiresDependencyRecoveryKeyframe()
            guard stillRequiresRecovery else { return }
        }

        let label = "Packet sender dependency drop retry"
        let now = CFAbsoluteTimeGetCurrent()
        if isRecoveryKeyframeCooldownActive(now: now) {
            dependencyRecoveryRetryNecessary = true
            logRecoveryKeyframeCooldownSuppression(reason: label, now: now)
            schedulePacketSenderDependencyRecoveryKeyframeRetry(
                frameNumber: frameNumber,
                reason: reason
            )
            return
        }
        startFrameChainRepair(
            reason: "sender-dependency-drop-retry",
            firstBrokenFrame: frameNumber,
            now: now
        )
        await noteEmergencyKeyframePrepared(using: nil)
        let queued = await scheduleEmergencyChainRepairKeyframe(
            reason: label,
            bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError,
            now: now
        )
        guard queued else {
            dependencyRecoveryRetryNecessary = true
            MirageLogger.stream(
                "\(label) deferred frame=\(frameNumber) reason=\(reason.rawValue) "
                    + "queuedBytes=\(queuedBytes) retryNecessary=true"
            )
            schedulePacketSenderDependencyRecoveryKeyframeRetry(
                frameNumber: frameNumber,
                reason: reason
            )
            return
        }

        scheduleProcessingIfNeeded()
        MirageLogger.stream(
            "Scheduled retried keyframe after packet sender dependency drop "
                + "frame=\(frameNumber) reason=\(reason.rawValue) queuedBytes=\(queuedBytes) retryNecessary=true"
        )
    }

    func logDependencyRecoveryKeyframeIfNeeded(
        frameNumber: UInt32,
        queuedBytes: Int
    ) {
        guard let droppedFrameNumber = dependencyRecoveryPendingDropFrameNumber,
              let reason = dependencyRecoveryPendingDropReason else {
            return
        }

        MirageLogger.stream(
            "Dependency-drop recovery keyframe encoded "
                + "keyframeFrame=\(frameNumber) droppedFrame=\(droppedFrameNumber) "
                + "reason=\(reason.rawValue) queuedBytes=\(queuedBytes) "
                + "retryNecessary=\(dependencyRecoveryRetryNecessary)"
        )
        dependencyRecoveryPendingDropFrameNumber = nil
        dependencyRecoveryPendingDropReason = nil
        dependencyRecoveryPendingQueuedBytes = 0
        dependencyRecoveryRetryNecessary = false
    }

    func isRecoveryKeyframeCooldownActive(now: CFAbsoluteTime) -> Bool {
        guard lastSuccessfulKeyframeSendTime > 0 else { return false }
        return now - lastSuccessfulKeyframeSendTime < recoveryKeyframeCooldown
    }

    func recoveryKeyframeCooldownRemaining(now: CFAbsoluteTime) -> CFAbsoluteTime {
        guard lastSuccessfulKeyframeSendTime > 0 else { return 0 }
        return max(0, recoveryKeyframeCooldown - (now - lastSuccessfulKeyframeSendTime))
    }

    func recoveryCauseBypassesAdaptiveKeyframeCooldown(
        _ recoveryCause: MirageMediaFeedbackRecoveryCause
    ) -> Bool {
        recoveryCause == .decodeError
    }

    func logRecoveryKeyframeCooldownSuppression(reason: String, now: CFAbsoluteTime) {
        let remainingMs = Int((recoveryKeyframeCooldownRemaining(now: now) * 1000).rounded())
        MirageLogger.stream(
            "\(reason) skipped (adaptive recovery keyframe cooldown \(remainingMs)ms remaining)"
        )
    }

    @discardableResult
    func scheduleCoalescedRecoveryKeyframe(
        reason: String,
        resetFrameNumber: Bool = false,
        noteLoss: Bool = false,
        requiresFlush: Bool = false,
        requiresReset: Bool = false,
        advanceEpochOnReset: Bool = true,
        ignoreExistingInFlight: Bool = false,
        bypassesRecoveryCooldown: Bool = false
    ) async -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if !requiresReset,
           !bypassesRecoveryCooldown,
           isRecoveryKeyframeCooldownActive(now: now) {
            logRecoveryKeyframeCooldownSuppression(reason: reason, now: now)
            return false
        }
        let effectiveIgnoreExistingInFlight = ignoreExistingInFlight &&
            !usesConstrainedKeyframeInFlightWindow
        if effectiveIgnoreExistingInFlight {
            keyframeSendDeadline = 0
            lastKeyframeRequestTime = 0
            keyframeInFlightFrameNumber = nil
        }

        let queued = queueKeyframe(
            reason: reason,
            checkInFlight: !effectiveIgnoreExistingInFlight,
            requiresFlush: requiresFlush,
            requiresReset: requiresReset,
            advanceEpochOnReset: advanceEpochOnReset,
            urgent: true,
            countsAgainstRecoveryBudget: false
        )
        guard queued else {
            MirageLogger.stream("\(reason) skipped (recovery keyframe already pending or in flight)")
            return false
        }

        if noteLoss {
            noteLossEvent(reason: reason, enablePFrameFEC: true)
        }
        if resetFrameNumber {
            await encoder?.resetFrameNumber()
        }
        scheduleProcessingIfNeeded()
        MirageLogger.stream("Scheduled coalesced recovery keyframe (\(reason))")
        return true
    }

    func scheduleCoalescedStartupKeyframe(
        reason: String,
        resetFrameNumber: Bool = false
    ) async {
        let queued = queueKeyframe(
            reason: reason,
            checkInFlight: true,
            urgent: true,
            countsAgainstRecoveryBudget: false
        )
        guard queued else {
            MirageLogger.stream("\(reason) skipped (startup keyframe already pending or in flight)")
            return
        }

        if resetFrameNumber {
            await encoder?.resetFrameNumber()
        }
        scheduleProcessingIfNeeded()
        MirageLogger.stream("Scheduled coalesced startup keyframe (\(reason))")
    }

    func shouldEmitPendingKeyframe(queueBytes: Int) -> Bool {
        guard pendingKeyframeReason != nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        if pendingKeyframeUrgent {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            pendingKeyframeUrgent = false
            lastKeyframeTime = now
            return true
        }
        let settleThreshold = max(minQueuedBytes, Int(Double(queuePressureBytes) * keyframeQueueSettleFactor))
        let settled = queueBytes <= settleThreshold && inFlightCount == 0
        if settled || now >= pendingKeyframeDeadline {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            lastKeyframeTime = now
            return true
        }
        return false
    }

    static func keyframeCadence(
        intervalFrames: Int,
        frameRate: Int
    )
    -> (interval: CFAbsoluteTime, maxInterval: CFAbsoluteTime) {
        let clampedFrames = max(1, intervalFrames)
        let clampedRate = max(1, frameRate)
        let intervalSeconds = Double(clampedFrames) / Double(clampedRate)
        let cadence = max(1.0, intervalSeconds)
        let maxCadence = max(cadence * 2.0, cadence + 1.0)
        return (cadence, maxCadence)
    }

    func updateKeyframeCadence() {
        let cadence = Self.keyframeCadence(
            intervalFrames: encoderConfig.keyFrameInterval,
            frameRate: currentFrameRate
        )
        keyframeIntervalSeconds = cadence.interval
        keyframeMaxIntervalSeconds = cadence.maxInterval
    }

    func shouldQueueScheduledKeyframe(queueBytes: Int) -> Bool {
        guard scheduledKeyframesEnabled else { return false }
        guard shouldEncodeFrames else { return false }
        guard !isResizing else { return false }
        guard lastKeyframeTime > 0 else { return false }
        guard pendingKeyframeReason == nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastKeyframeTime
        guard elapsed >= keyframeIntervalSeconds else { return false }

        let queueBackedUp = queueBytes >= queuePressureBytes
        let allowDespitePressure = elapsed >= keyframeMaxIntervalSeconds

        if queueBackedUp, !allowDespitePressure { return false }

        if now < keyframeSendDeadline {
            extendConstrainedKeyframeInFlightDeadline(now: now, requestLabel: "Scheduled keyframe")
            let remaining = Int(((keyframeSendDeadline - now) * 1000).rounded())
            MirageLogger.stream(
                "Scheduled keyframe skipped (keyframe in flight, \(remaining)ms remaining, "
                    + "frame=\(keyframeInFlightFrameNumber.map { String($0) } ?? "nil"))"
            )
            return false
        }
        let requestElapsed = now - lastKeyframeRequestTime
        let requestCooldown = activeKeyframeRequestCooldown
        if requestElapsed < requestCooldown {
            let remaining = Int(((requestCooldown - requestElapsed) * 1000).rounded())
            MirageLogger.stream("Scheduled keyframe skipped (cooldown \(remaining)ms)")
            return false
        }
        return true
    }

    func markKeyframeSent() {
        lastKeyframeTime = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        if !frameChainSuppressesPFrames {
            suppressEncodedNonKeyframesUntilKeyframe = false
            pendingEmergencyKeyframeQuality = nil
        }
        if dynamicFrameFlags.contains(.discontinuity) { dynamicFrameFlags.remove(.discontinuity) }
    }

    func noteLossEvent(reason: String, enablePFrameFEC: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let lossDeadline = now + lossModeHold
        if lossDeadline > lossModeDeadline { lossModeDeadline = lossDeadline }
        if enablePFrameFEC {
            let pFrameDeadline = now + pFrameFECLossModeHold
            if pFrameDeadline > lossModePFrameFECDeadline { lossModePFrameFECDeadline = pFrameDeadline }
        }
        let pFrameFECRemainderMs = Int(max(0, lossModePFrameFECDeadline - now) * 1000)
        let pFrameFECState = pFrameFECRemainderMs > 0 ? "on(\(pFrameFECRemainderMs)ms)" : "off"
        MirageLogger
            .stream(
                "Loss mode extended to \(Int((lossModeDeadline - now) * 1000))ms, pFrameFEC=\(pFrameFECState) (\(reason))"
            )
    }

    func enableStartupTransportProtection(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        startupTransportProtectionDeadline = now + startupTransportProtectionHold
    }

    func disableStartupTransportProtection() {
        startupTransportProtectionDeadline = 0
    }

    nonisolated func isStartupTransportProtectionActive(now: CFAbsoluteTime) -> Bool {
        now < startupTransportProtectionDeadline
    }

    nonisolated func isLossModeActive(now: CFAbsoluteTime) -> Bool {
        now < lossModeDeadline
    }

    nonisolated func isPFrameFECActive(now: CFAbsoluteTime) -> Bool {
        now < lossModePFrameFECDeadline
    }

    nonisolated func resolvedFECBlockSize(
        isKeyframe: Bool,
        frameByteCount: Int = 0,
        now: CFAbsoluteTime
    ) -> Int {
        if mediaPathProfile.usesAwdlRadioPolicy {
            if isKeyframe, isStartupTransportProtectionActive(now: now) {
                return MirageAwdlMediaController.startupKeyframeFECBlockSizeForAwdlRadio()
            }
            if isLossModeActive(now: now) || isKeyframe {
                return MirageAwdlMediaController.keyframeFECBlockSize()
            }
            return MirageAwdlMediaController.pFrameFECBlockSize(
                frameByteCount: frameByteCount,
                maxPayloadSize: maxPayloadSize,
                isLossModeActive: false
            )
        }
        if isKeyframe, isStartupTransportProtectionActive(now: now) {
            return startupKeyframeFECBlockSize
        }
        guard isLossModeActive(now: now) else { return 0 }
        if isKeyframe { return 8 }
        return isPFrameFECActive(now: now) ? 16 : 0
    }

    nonisolated static func mediaPacingOverride(
        isKeyframe: Bool,
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile,
        targetBitrateBps: Int?,
        maxPayloadSize: Int
    ) -> StreamPacketSender.PacingOverride? {
        if isKeyframe {
            return keyframePacingOverride(
                transportPathKind: transportPathKind,
                mediaPathProfile: mediaPathProfile,
                targetBitrateBps: targetBitrateBps,
                maxPayloadSize: maxPayloadSize
            )
        }

        guard mediaPathProfile.usesAwdlRadioPolicy else { return nil }
        let packetBudget = max(1, maxPayloadSize)
        return StreamPacketSender.PacingOverride(
            rateBps: MirageAwdlMediaController.pacingBudgetBps(targetBitrateBps: targetBitrateBps),
            burstBytes: packetBudget * MirageAwdlMediaController.pFramePacketBurst
        )
    }

    nonisolated static func keyframePacingOverride() -> StreamPacketSender.PacingOverride {
        keyframePacingOverride(
            transportPathKind: .unknown,
            mediaPathProfile: .unknown,
            targetBitrateBps: nil,
            maxPayloadSize: miragePayloadSize(maxPacketSize: mirageDefaultMaxPacketSize)
        )
    }

    nonisolated static func keyframePacingOverride(
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile,
        targetBitrateBps: Int?,
        maxPayloadSize: Int
    ) -> StreamPacketSender.PacingOverride {
        if mediaPathProfile.usesAwdlRadioPolicy {
            return StreamPacketSender.PacingOverride(
                rateBps: MirageAwdlMediaController.pacingBudgetBps(targetBitrateBps: targetBitrateBps),
                burstBytes: max(1, maxPayloadSize) * MirageAwdlMediaController.keyframePacketBurst
            )
        }

        return StreamPacketSender.PacingOverride(
            rateBps: 48_000_000,
            burstBytes: 16 * 1024
        )
    }

    var keyframeQuality: Float {
        let base = min(activeQuality, min(encoderConfig.keyframeQuality, compressionQualityCeiling))
        guard runtimeQualityAdjustmentEnabled else { return base }
        return min(activeQuality, max(keyframeQualityFloor, base))
    }
}
#endif
