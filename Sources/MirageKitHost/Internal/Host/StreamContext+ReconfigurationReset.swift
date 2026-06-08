//
//  StreamContext+ReconfigurationReset.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
    /// Clears transient encode, keyframe, pressure, and latency-burst state before reconfiguring capture.
    func resetPipelineStateForReconfiguration(
        reason: String,
        preservePendingGeometryRecoveryKeyframe: Bool = false
    ) {
        if inFlightCount > 0 || isKeyframeEncoding || lastEncodeActivityTime > 0 {
            MirageLogger.stream("Resetting pipeline state for \(reason) (inFlight=\(inFlightCount))")
        }
        let preservedGeometryKeyframe = preservePendingGeometryRecoveryKeyframe
            ? pendingGeometryRecoveryKeyframeStateForReconfiguration()
            : nil
        resetInFlightEncodingStateForReconfiguration()
        clearPendingKeyframeStateForReconfiguration()
        clearCaptureAndPressureStateForReconfiguration()
        resetLatencyBurstStateForReconfiguration()
        resetQualityStateForReconfiguration()
        frameInbox.discardAll()
        if let preservedGeometryKeyframe {
            restorePendingGeometryRecoveryKeyframeAfterReconfiguration(
                preservedGeometryKeyframe,
                reason: reason
            )
        }
    }

    /// Clears in-flight encoder bookkeeping for a stream reconfiguration.
    private func resetInFlightEncodingStateForReconfiguration() {
        inFlightCount = 0
        encoderInFlightCountSnapshot = 0
        encoderAverageEncodeMsSnapshot = 0
        lastEncodeActivityTime = 0
        isKeyframeEncoding = false
        needsEncoderReset = false
        encoderResetRetryTask?.cancel()
        encoderResetRetryTask = nil
    }

    private struct PendingGeometryRecoveryKeyframeState {
        let reason: String
        let deadline: CFAbsoluteTime
        let requiresFlush: Bool
        let urgent: Bool
        let requiresReset: Bool
        let emergencyQuality: Float?
        let keyframeSendDeadline: CFAbsoluteTime
        let lastKeyframeRequestTime: CFAbsoluteTime
        let protectedReason: String?
    }

    private func pendingGeometryRecoveryKeyframeStateForReconfiguration()
        -> PendingGeometryRecoveryKeyframeState? {
        guard let pendingKeyframeReason,
              pendingKeyframeReason.hasPrefix("Desktop resize") ||
                pendingKeyframeReason.hasPrefix("Shared display resize") else {
            return nil
        }
        return PendingGeometryRecoveryKeyframeState(
            reason: pendingKeyframeReason,
            deadline: pendingKeyframeDeadline,
            requiresFlush: pendingKeyframeRequiresFlush,
            urgent: pendingKeyframeUrgent,
            requiresReset: pendingKeyframeRequiresReset,
            emergencyQuality: pendingEmergencyKeyframeQuality,
            keyframeSendDeadline: keyframeSendDeadline,
            lastKeyframeRequestTime: lastKeyframeRequestTime,
            protectedReason: protectedGeometryRecoveryKeyframeReason
        )
    }

    private func restorePendingGeometryRecoveryKeyframeAfterReconfiguration(
        _ state: PendingGeometryRecoveryKeyframeState,
        reason: String
    ) {
        pendingKeyframeReason = state.reason
        pendingKeyframeDeadline = min(state.deadline, CFAbsoluteTimeGetCurrent())
        pendingKeyframeRequiresFlush = state.requiresFlush
        pendingKeyframeUrgent = true
        pendingKeyframeRequiresReset = state.requiresReset
        pendingEmergencyKeyframeQuality = state.emergencyQuality
        suppressEncodedNonKeyframesUntilKeyframe = true
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = state.lastKeyframeRequestTime
        protectedGeometryRecoveryKeyframeReason = state.protectedReason ?? state.reason
        MirageLogger.stream(
            "Preserved geometry recovery keyframe across \(reason): \(state.reason)"
        )
        scheduleProcessingForPendingKeyframe(reason: state.reason)
    }

    /// Clears deferred keyframe requests and send deadlines for a stream reconfiguration.
    private func clearPendingKeyframeStateForReconfiguration() {
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        protectedGeometryRecoveryKeyframeReason = nil
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
        clearBackpressureState(log: false)
        realtimeLastEncoderThroughputAdjustmentTime = 0
        lastCapturedFrame = nil
        cachedStartupFrame = nil
        lastCapturedFrameTime = 0
        mosaicDirtyTileTracker.reset()
        mosaicMediaUnitCropper.reset()
        mosaicSemanticSnapshotCache.reset()
        mosaicEncodedDependencyTracker.reset()
        mosaicTileQualityGovernor.reset()
        Task { await mosaicCodecUnitEncoderPool.stopAll() }
        latestMosaicDirtyTileSummary = nil
        latestMosaicTilePlan = nil
        latestMosaicMediaUnitWorkItems.removeAll(keepingCapacity: false)
        latestMosaicQualityRefreshTileIDs.removeAll(keepingCapacity: false)
        lastDispatchedMosaicTilePlanEpoch = nil
        mosaicQualityRefreshTileCursor = 0
        freshnessBurstActive = false
        startupFrameCachingEnabled = false
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
        clearAwdlHostStructuralQualityReduction()
    }
}
#endif
