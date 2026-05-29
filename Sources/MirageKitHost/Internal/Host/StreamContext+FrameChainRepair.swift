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
        switch frameChainState {
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

    @discardableResult
    func scheduleEmergencyChainRepairKeyframe(
        reason: String,
        bypassesRecoveryCooldown: Bool,
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
        let queued = await scheduleCoalescedRecoveryKeyframe(
            reason: reason,
            noteLoss: false,
            requiresFlush: false,
            requiresReset: false,
            ignoreExistingInFlight: false,
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
        return true
    }

    func emergencyKeyframeQuality() -> Float {
        let base = min(pendingEmergencyKeyframeQuality ?? activeQuality, keyframeQuality)
        return max(0.02, min(base, activeQuality * 0.35, resolvedQualityCeiling * 0.35))
    }

    func lowerEmergencyKeyframeQuality(using decision: HostFrameBudgetDecision?) async {
        let basis = pendingEmergencyKeyframeQuality ??
            decision?.keyframeQuality ??
            min(activeQuality, keyframeQuality)
        let nextQuality = max(0.02, basis * 0.55)
        pendingEmergencyKeyframeQuality = nextQuality
        await encoder?.prepareForKeyframe(quality: nextQuality)
    }

    func noteEmergencyKeyframePrepared(using decision: HostFrameBudgetDecision?) async {
        let decisionQuality = decision?.keyframeQuality ?? emergencyKeyframeQuality()
        pendingEmergencyKeyframeQuality = min(decisionQuality, emergencyKeyframeQuality())
        if let pendingEmergencyKeyframeQuality {
            await encoder?.prepareForKeyframe(quality: pendingEmergencyKeyframeQuality)
        }
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
            try await updateStreamScale(nextScale)
            emergencyRecoveryScaleIndex = nextIndex
            emergencyRecoveryCleanPFrames = 0
            startFrameChainRepair(reason: reason, now: now)
            await noteEmergencyKeyframePrepared(using: nil)
            MirageLogger.metrics(
                "Emergency recovery scale lowered for stream \(streamID): " +
                    "scale=\(String(format: "%.2f", Double(nextScale))) reason=\(reason)"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "Emergency recovery scale update failed: ")
            return false
        }
    }

    func handleFrameTransportCompleted(
        streamID completedStreamID: StreamID,
        frameNumber: UInt32,
        isKeyframe: Bool,
        didSend: Bool
    ) async {
        guard completedStreamID == streamID else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if didSend {
            recordFrameTransportCompletion(frameNumber: frameNumber, completedAt: now)
        }

        if isKeyframe {
            if didSend {
                frameChainRepairKeyframeRetryTask?.cancel()
                frameChainRepairKeyframeRetryTask = nil
                lastSuccessfulKeyframeSendTime = now
                if keyframeInFlightFrameNumber == frameNumber {
                    keyframeInFlightFrameNumber = nil
                }
                handleSuccessfulKeyframeTransport(frameNumber: frameNumber, now: now)
            } else {
                handleFailedKeyframeTransport(frameNumber: frameNumber, now: now)
            }
            return
        }

        guard didSend else { return }
        await handleCleanPFrameTransport(frameNumber: frameNumber, now: now)
    }

    private func recordFrameTransportCompletion(frameNumber: UInt32, completedAt: CFAbsoluteTime) {
        recentFrameTransportCompletions.append((frameNumber: frameNumber, completedAt: completedAt))
        if recentFrameTransportCompletions.count > recentFrameTransportCompletionLimit {
            recentFrameTransportCompletions.removeFirst(
                recentFrameTransportCompletions.count - recentFrameTransportCompletionLimit
            )
        }
    }

    private func handleSuccessfulKeyframeTransport(frameNumber: UInt32, now: CFAbsoluteTime) {
        let wasRepairing: Bool
        switch frameChainState {
        case .chainBroken,
             .emergencyKeyframePending:
            wasRepairing = true
        case .normal,
             .postKeyframeCooling:
            wasRepairing = suppressEncodedNonKeyframesUntilKeyframe
        }

        suppressEncodedNonKeyframesUntilKeyframe = false
        latestReceiverRecoveryCause = .none
        pendingEmergencyKeyframeQuality = nil
        frameBudgetController.resetEncodedOvershootHistory()
        if wasRepairing {
            frameChainState = .postKeyframeCooling(
                untilCleanPFrames: postEmergencyKeyframeCleanPFrameCount
            )
            MirageLogger.metrics(
                "Emergency recovery keyframe sent for stream \(streamID); " +
                    "cooling until \(postEmergencyKeyframeCleanPFrameCount) clean P-frames"
            )
        }
    }

    private func handleFailedKeyframeTransport(frameNumber: UInt32, now: CFAbsoluteTime) {
        switch frameChainState {
        case let .emergencyKeyframePending(reason, _):
            frameChainState = .chainBroken(
                reason: reason,
                firstBrokenFrame: frameNumber,
                openedAt: now
            )
            suppressEncodedNonKeyframesUntilKeyframe = true
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
        let nextIndex = max(0, emergencyRecoveryScaleIndex - 1)
        let targetScale = StreamContext.clampStreamScale(
            baseScale * Self.emergencyRecoveryScaleFactors[nextIndex]
        )
        emergencyRecoveryScaleChangeInProgress = true
        defer { emergencyRecoveryScaleChangeInProgress = false }
        do {
            try await updateStreamScale(targetScale)
            emergencyRecoveryScaleIndex = nextIndex
            emergencyRecoveryCleanPFrames = 0
            if nextIndex == 0 {
                emergencyRecoveryBaseStreamScale = nil
            }
            MirageLogger.metrics(
                "Emergency recovery scale restored for stream \(streamID): " +
                    "scale=\(String(format: "%.2f", Double(targetScale)))"
            )
        } catch {
            MirageLogger.error(.stream, error: error, message: "Emergency recovery scale restore failed: ")
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

    private func frameChainRepairKeyframeRetryDelay(
        now: CFAbsoluteTime,
        bypassesRecoveryCooldown: Bool
    ) -> CFAbsoluteTime {
        let inFlightDelay = max(0, keyframeSendDeadline - now)
        let requestDelay: CFAbsoluteTime
        if lastKeyframeRequestTime > 0 {
            requestDelay = max(0, activeKeyframeRequestCooldown - (now - lastKeyframeRequestTime))
        } else {
            requestDelay = 0
        }
        let recoveryDelay = bypassesRecoveryCooldown ? 0 : recoveryKeyframeCooldownRemaining(now: now)
        return max(0.05, inFlightDelay, requestDelay, recoveryDelay) + 0.025
    }

    private func retryFrameChainRepairKeyframe(
        reason: String,
        bypassesRecoveryCooldown: Bool
    ) async {
        frameChainRepairKeyframeRetryTask = nil
        guard isRunning else { return }
        switch frameChainState {
        case .chainBroken:
            await scheduleEmergencyChainRepairKeyframe(
                reason: reason,
                bypassesRecoveryCooldown: bypassesRecoveryCooldown,
                now: CFAbsoluteTimeGetCurrent()
            )
        case .normal,
             .emergencyKeyframePending,
             .postKeyframeCooling:
            break
        }
    }
}

private extension StreamContext {
    static let emergencyRecoveryScaleFactors: [CGFloat] = [1.0, 0.75, 0.5]
}
#endif
