//
//  MirageClientService+AutomaticDesktopWorkload.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Client-driven automatic desktop cadence reconfiguration.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Requests a host-side desktop frame-rate change for the active desktop stream.
    public func requestAutomaticDesktopWorkloadReconfiguration(
        streamID: StreamID,
        target: MirageAutomaticDesktopWorkloadTier
    )
    async throws -> Bool {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard desktopStreamID == streamID else { return false }
        guard pendingLocalDesktopStopStreamID != streamID else { return false }
        guard !startupCriticalSectionActive, !hasActivePostResizeTransition else { return false }
        guard let session = sessionStore.sessionByStreamID(streamID),
              session.hasPresentedFrame,
              session.clientRecoveryStatus == .idle else {
            return false
        }

        let effectiveTarget = Self.runtimeWorkloadSafetyCappedTier(
            target,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        let snapshot = metricsStore.snapshot(for: streamID)
        let currentFrameRate = snapshot?.hostTargetFrameRate ?? 0
        let needsFrameRateChange = currentFrameRate > 0 && currentFrameRate != effectiveTarget.targetFrameRate
        let decision = Self.automaticDesktopWorkloadReconfigurationDecision(
            needsFrameRateChange: needsFrameRateChange,
            needsResize: false,
            allowsAutomaticResolutionResize: false
        )

        guard decision.shouldChangeFrameRate else { return false }

        try await sendStreamEncoderSettingsChange(
            streamID: streamID,
            targetFrameRate: effectiveTarget.targetFrameRate
        )
        refreshRateOverridesByStream[streamID] = effectiveTarget.targetFrameRate
        refreshRateMismatchCounts.removeValue(forKey: streamID)
        refreshRateFallbackTargets.removeValue(forKey: streamID)

        MirageLogger.client(
            "Requested automatic desktop cadence reconfiguration for stream \(streamID): " +
                "\(effectiveTarget.targetFrameRate)fps"
        )
        return true
    }

    struct AutomaticDesktopWorkloadReconfigurationDecision: Equatable {
        let shouldChangeFrameRate: Bool
        let shouldResize: Bool
    }

    nonisolated static func automaticDesktopWorkloadReconfigurationDecision(
        needsFrameRateChange: Bool,
        needsResize: Bool,
        allowsAutomaticResolutionResize: Bool
    ) -> AutomaticDesktopWorkloadReconfigurationDecision {
        _ = needsResize
        _ = allowsAutomaticResolutionResize
        return AutomaticDesktopWorkloadReconfigurationDecision(
            shouldChangeFrameRate: needsFrameRateChange,
            shouldResize: false
        )
    }
}
