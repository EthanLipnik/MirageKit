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

@MainActor
final class MirageRefreshRateMonitor: NSObject {
    var onOverrideChange: ((Int) -> Void)?

    var preferredMaximumRefreshRate: Int = 60 {
        didSet {
            applyPreferredOverride()
        }
    }

    private var currentOverride: Int = 60

    init(view: MirageSampleBufferView) {}

    func start() {
        applyPreferredOverride()
    }

    func stop() {}

    private func applyPreferredOverride() {
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
