//
//  MirageClientService+DisplayCadence.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Client-side display cadence and refresh-rate overrides.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Selected target refresh rate requested by the client.
    public var screenMaxRefreshRate: Int {
        Self.resolvedRequestedRefreshRate(
            override: maxRefreshRateOverride,
            preferredMaximumRefreshRate: MirageRenderPreferences.preferredMaximumRefreshRate
        )
    }

    /// Updates the client-side maximum refresh-rate override used by stream views.
    public func updateMaxRefreshRateOverride(_ newValue: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(newValue)
        guard maxRefreshRateOverride != clamped else { return }
        maxRefreshRateOverride = clamped
    }

    /// Records the host-observed cadence for a stream after applying normal FPS bounds.
    func updateObservedFrameRate(_ frameRate: Int, for streamID: StreamID) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(frameRate)
        guard observedFrameRateByStream[streamID] != clamped else { return }
        observedFrameRateByStream[streamID] = clamped
    }

    /// Resolves the active cadence source for a stream, including workload safety caps.
    func resolvedStreamCadenceFrameRate(for streamID: StreamID, fallback: Int? = nil) -> Int {
        if let fallback {
            return Self.runtimeWorkloadSafetyCappedFrameRate(
                fallback,
                cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
            )
        }
        if let observed = observedFrameRateByStream[streamID], observed > 0 {
            return Self.runtimeWorkloadSafetyCappedFrameRate(
                observed,
                cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
            )
        }
        if let override = refreshRateOverridesByStream[streamID], override > 0 {
            return Self.runtimeWorkloadSafetyCappedFrameRate(
                override,
                cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
            )
        }
        return Self.runtimeWorkloadSafetyCappedFrameRate(
            screenMaxRefreshRate,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
    }

    /// Applies a cadence target to render storage and the active stream controller.
    func applyStreamCadenceTarget(
        _ frameRate: Int,
        for streamID: StreamID,
        reason: String
    )
    async {
        let targetFrameRate = Self.runtimeWorkloadSafetyCappedFrameRate(
            frameRate,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        updateObservedFrameRate(targetFrameRate, for: streamID)
        let latencyMode = renderLatencyModeByStream[streamID] ?? .lowestLatency
        let target = MirageStreamCadenceTarget(
            sourceFPS: targetFrameRate,
            displayFPS: targetFrameRate,
            latencyMode: latencyMode
        )
        MirageRenderStreamStore.shared.setCadenceTarget(for: streamID, target: target)
        guard let controller = controllersByStream[streamID] else { return }
        await controller.updateCadenceTarget(
            sourceFPS: targetFrameRate,
            displayFPS: targetFrameRate,
            latencyMode: latencyMode,
            reason: reason
        )
    }

    /// Sends a refresh-rate override to the host for an active stream.
    func sendStreamRefreshRateChange(
        streamID: StreamID,
        maxRefreshRate: Int,
        forceDisplayRefresh: Bool = false
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let clamped = Self.runtimeWorkloadSafetyCappedFrameRate(
            maxRefreshRate,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        let request = StreamRefreshRateChangeMessage(
            streamID: streamID,
            maxRefreshRate: clamped,
            forceDisplayRefresh: forceDisplayRefresh
        )
        let adaptiveFloorFPS = clamped >= 90 ? 60 : clamped
        let latencyMode = renderLatencyModeByStream[streamID] ?? .lowestLatency
        MirageLogger.client("Sending refresh rate override for stream \(streamID): \(clamped)Hz")
        MirageLogger.client(
            "event=cadence_contract phase=refresh_change stream=\(streamID) requested=\(clamped) " +
                "source=\(clamped) display=\(clamped) adaptiveFloor=\(adaptiveFloorFPS) " +
                "path=\(controlPathSnapshot?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue) " +
                "latency=\(latencyMode.rawValue) force=\(forceDisplayRefresh)"
        )
        try await sendControlMessage(.streamRefreshRateChange, content: request)
    }

    /// Stores and sends a refresh-rate override for an active stream controller.
    func updateStreamRefreshRateOverride(streamID: StreamID, maxRefreshRate: Int) {
        guard controllersByStream[streamID] != nil else {
            MirageLogger.client(
                "Ignoring stale refresh rate override for inactive stream \(streamID): \(maxRefreshRate)Hz"
            )
            return
        }
        let clamped = Self.runtimeWorkloadSafetyCappedFrameRate(
            maxRefreshRate,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        let existing = refreshRateOverridesByStream[streamID]
        guard existing != clamped else { return }
        refreshRateOverridesByStream[streamID] = clamped
        refreshRateMismatchCounts.removeValue(forKey: streamID)
        refreshRateFallbackTargets.removeValue(forKey: streamID)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendStreamRefreshRateChange(streamID: streamID, maxRefreshRate: clamped)
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to send refresh override update: ")
            }
        }
    }

    /// Clears all client-side cadence overrides and safety state for a stream.
    func clearStreamRefreshRateOverride(streamID: StreamID) {
        refreshRateOverridesByStream.removeValue(forKey: streamID)
        observedFrameRateByStream.removeValue(forKey: streamID)
        refreshRateMismatchCounts.removeValue(forKey: streamID)
        refreshRateFallbackTargets.removeValue(forKey: streamID)
        clearRuntimeWorkloadSafetyState(for: streamID)
    }

    private nonisolated static func resolvedRequestedRefreshRate(
        override: Int?,
        preferredMaximumRefreshRate: Int
    ) -> Int {
        if let override {
            return MirageRenderModePolicy.normalizedTargetFPS(override)
        }
        return MirageRenderModePolicy.normalizedTargetFPS(preferredMaximumRefreshRate)
    }
}
