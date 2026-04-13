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
import QuartzCore
#if os(iOS)
import UIKit
#endif

@MainActor
final class MirageRefreshRateMonitor: NSObject {
    private weak var view: MirageSampleBufferView?

    var onOverrideChange: ((Int) -> Void)?

    var preferredMaximumRefreshRate: Int = 60 {
        didSet {
            updateMode()
        }
    }

    private var pollTask: Task<Void, Never>?

    private var currentOverride: Int = 60
    private var lastScreenMaxFPS: Int = 0

    private let pollInterval: Duration = .seconds(3)

    private var isViewReadyForSampling: Bool {
        guard let view else { return false }
        return view.superview != nil && !view.bounds.isEmpty
    }

    init(view: MirageSampleBufferView) {
        self.view = view
    }

    func start() {
        updateMode()
    }

    func stop() {
        stopPolling()
    }

    private func updateMode() {
        let preferredFPS = MirageRenderModePolicy.normalizedTargetFPS(preferredMaximumRefreshRate)
        guard preferredFPS > 60 else {
            setOverride(preferredFPS)
            stopPolling()
            return
        }
        evaluateScreenMaxFPS()
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if preferredMaximumRefreshRate > 60, isViewReadyForSampling {
                    evaluateScreenMaxFPS()
                } else if preferredMaximumRefreshRate <= 60 {
                    setOverride(preferredMaximumRefreshRate)
                }

                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func evaluateScreenMaxFPS() {
        let maxFPS = resolveScreenMaxFPS()
        if maxFPS != lastScreenMaxFPS { lastScreenMaxFPS = maxFPS }
        guard maxFPS > 0 else { return }
        MirageClientService.lastKnownScreenMaxFPS = maxFPS
        let target = min(
            MirageRenderModePolicy.normalizedTargetFPS(preferredMaximumRefreshRate),
            maxFPS
        )
        setOverride(target)
    }

    private func resolveScreenMaxFPS() -> Int {
        #if os(iOS)
        if let screen = view?.window?.windowScene?.screen { return screen.maximumFramesPerSecond }
        if let screen = view?.window?.screen { return screen.maximumFramesPerSecond }
        if let screen = UIWindow.current?.windowScene?.screen ?? UIWindow.current?.screen {
            return screen.maximumFramesPerSecond
        }
        return 0
        #else
        // visionOS doesn't have UIScreen; use 90 fps (Vision Pro native rate)
        // TODO: Support 120fps on M5 Vision Pro when Apple provides API to detect display capabilities
        return 90
        #endif
    }

    private func setOverride(_ newValue: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(newValue)
        guard currentOverride != clamped else { return }
        currentOverride = clamped
        onOverrideChange?(clamped)
    }
}
#endif
