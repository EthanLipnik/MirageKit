//
//  StreamContext+ReconfigurationReset.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Clears transient encode, keyframe, pressure, and latency-burst state before reconfiguring capture.
    func resetPipelineStateForReconfiguration(reason: String) {
        if inFlightCount > 0 || isKeyframeEncoding || lastEncodeActivityTime > 0 {
            MirageLogger.stream("Resetting pipeline state for \(reason) (inFlight=\(inFlightCount))")
        }
        resetInFlightEncodingStateForReconfiguration()
        clearPendingKeyframeStateForReconfiguration()
        clearCaptureAndPressureStateForReconfiguration()
        resetLatencyBurstStateForReconfiguration()
        resetQualityStateForReconfiguration()
        frameInbox.discardAll()
    }

    /// Clears in-flight encoder bookkeeping for a stream reconfiguration.
    private func resetInFlightEncodingStateForReconfiguration() {
        inFlightCount = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = false
        encoderResetRetryTask?.cancel()
        encoderResetRetryTask = nil
    }

    /// Clears deferred keyframe requests and send deadlines for a stream reconfiguration.
    private func clearPendingKeyframeStateForReconfiguration() {
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        pendingEmergencyKeyframeQuality = nil
        suppressEncodedNonKeyframesUntilKeyframe = false
        frameChainState = .normal
        frameChainRepairKeyframeRetryTask?.cancel()
        frameChainRepairKeyframeRetryTask = nil
        if !emergencyRecoveryScaleChangeInProgress {
            emergencyRecoveryBaseStreamScale = nil
            emergencyRecoveryScaleIndex = 0
            emergencyRecoveryCleanPFrames = 0
        }
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
    }

    /// Clears capture, startup, and pressure state that is no longer valid after reconfiguration.
    private func clearCaptureAndPressureStateForReconfiguration() {
        lastCaptureStarvationRestartTime = 0
        clearBackpressureState(log: false)
        lastCapturedFrame = nil
        cachedStartupFrame = nil
        lastCapturedFrameTime = 0
        freshnessBurstActive = false
        startupFrameCachingEnabled = false
        captureCadenceRecoveryPolicy.reset()
        screenCaptureDeliveryRecovery.reset()
    }

    /// Restores latency-burst capture queue overrides and disables burst drain mode.
    private func resetLatencyBurstStateForReconfiguration() {
        if latencyBurstCaptureQueueDepthOverride != nil {
            encoderConfig.captureQueueDepth = preLatencyBurstCaptureQueueDepthOverride
        }
        latencyBurstActive = false
        latencyBurstDrainsNewestFrames = false
        latencyBurstCaptureQueueDepthOverride = nil
        preLatencyBurstCaptureQueueDepthOverride = nil
    }

    /// Restores reconfiguration-time quality and in-flight limits to their current bounds.
    private func resetQualityStateForReconfiguration() {
        maxInFlightFrames = min(minInFlightFrames, maxInFlightFramesCap)
        qualityCeiling = resolvedQualityCeiling
        if activeQuality > qualityCeiling { activeQuality = qualityCeiling }
    }
}
#endif
