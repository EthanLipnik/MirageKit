//
//  MirageRefreshRateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Sample-buffer view refresh rate sampler for dynamic display refresh overrides.
//

import MirageKit
#if os(iOS) || os(visionOS)

/// Tracks the refresh-rate cap requested by a stream view and reports effective changes to the coordinator.
@MainActor
final class MirageRefreshRateMonitor: NSObject {
    /// Called when the normalized refresh-rate override changes.
    var onOverrideChange: ((Int) -> Void)?

    /// Preferred maximum refresh rate requested by the current stream configuration.
    var preferredMaximumRefreshRate: Int = 60 {
        didSet {
            setOverride(preferredMaximumRefreshRate)
        }
    }

    private var currentOverride: Int = 60

    /// Emits the current preferred refresh-rate override when the stream view attaches.
    func start() {
        setOverride(preferredMaximumRefreshRate)
    }

    private func setOverride(_ newValue: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(newValue)
        guard currentOverride != clamped else { return }
        currentOverride = clamped
        onOverrideChange?(clamped)
    }
}
#endif
