//
//  MirageClientService+StartupCritical.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/26/26.
//

import MirageKit

@MainActor
extension MirageClientService {
    /// Updates the startup-critical flag and notifies observers when the visible state changes.
    private func setStartupCriticalSectionActive(_ active: Bool) {
        guard startupCriticalSectionActive != active else { return }
        startupCriticalSectionActive = active
        Task { @MainActor [weak self] in
            guard let self else { return }
            onStartupCriticalSectionChanged?(active)
        }
    }

    /// Marks connection bootstrap as startup-critical until it reaches idle or stream startup takes over.
    func beginConnectionStartupCriticalSection() {
        startupCriticalIdleReleaseTask?.cancel()
        setStartupCriticalSectionActive(true)
    }

    /// Releases connection-level startup isolation after the idle grace period when no streams are pending.
    func armConnectionStartupIdleRelease() {
        startupCriticalIdleReleaseTask?.cancel()
        startupCriticalIdleReleaseTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: startupCriticalIdleGrace)
            } catch {
                return
            }
            guard pendingStartupCriticalStreamIDs.isEmpty else { return }
            setStartupCriticalSectionActive(false)
        }
    }

    /// Tracks a stream whose first-frame path should keep startup isolation active.
    func beginStreamStartupCriticalSection(streamID: StreamID) {
        startupCriticalIdleReleaseTask?.cancel()
        pendingStartupCriticalStreamIDs.insert(streamID)
        setStartupCriticalSectionActive(true)
    }

    /// Completes startup isolation for a stream and clears the global flag when no streams remain pending.
    func completeStreamStartupCriticalSection(streamID: StreamID) {
        pendingStartupCriticalStreamIDs.remove(streamID)
        if pendingStartupCriticalStreamIDs.isEmpty {
            setStartupCriticalSectionActive(false)
        }
    }

    /// Cancels all pending startup isolation state after disconnect or failed startup cleanup.
    func clearStartupCriticalSection() {
        startupCriticalIdleReleaseTask?.cancel()
        startupCriticalIdleReleaseTask = nil
        pendingStartupCriticalStreamIDs.removeAll()
        setStartupCriticalSectionActive(false)
    }

    /// Sets client control-update policy for active-stream workload isolation.
    public func setControlUpdatePolicy(_ policy: ControlUpdatePolicy) {
        guard controlUpdatePolicy != policy else { return }
        controlUpdatePolicy = policy
        MirageLogger.client("Control update policy=\(policy)")
    }

    /// Consumes and clears deferred control refresh requirements accumulated while policy was suppressed.
    public func consumeDeferredControlRefreshRequirements() -> DeferredControlRefreshRequirements {
        let requirements = deferredControlRefreshRequirements
        deferredControlRefreshRequirements = .none
        return requirements
    }

    func refreshActiveStreamTransportBudgetPolicy() {
        let hasActiveVideoStream = activeMediaStreams.keys.contains { $0.hasPrefix("video/") }
        if hasActiveVideoStream {
            setControlUpdatePolicy(.interactiveStreaming)
            return
        }

        guard controlUpdatePolicy == .interactiveStreaming else { return }
        let deferred = deferredControlRefreshRequirements
        setControlUpdatePolicy(.normal)
        if deferred != .none {
            MirageLogger.client(
                "Deferred active-stream control refreshes ready: apps=\(deferred.needsAppListRefresh) windows=\(deferred.needsWindowListRefresh) softwareUpdate=\(deferred.needsHostSoftwareUpdateRefresh)"
            )
        }
    }
}
