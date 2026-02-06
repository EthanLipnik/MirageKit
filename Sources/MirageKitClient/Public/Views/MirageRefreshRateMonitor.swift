//
//  MirageRefreshRateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  MTKView refresh rate sampler for ProMotion overrides.
//

import MirageKit
#if os(iOS) || os(visionOS)
import MetalKit
import QuartzCore

@MainActor
final class MirageRefreshRateMonitor: NSObject {
    private weak var view: MTKView?

    var onOverrideChange: ((Int) -> Void)?

    var isProMotionEnabled: Bool = false {
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

    init(view: MTKView) {
        self.view = view
    }

    func start() {
        updateMode()
    }

    func stop() {
        stopPolling()
    }

    private func updateMode() {
        guard isProMotionEnabled else {
            setOverride(60)
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
                if isProMotionEnabled, isViewReadyForSampling { evaluateScreenMaxFPS() } else if !isProMotionEnabled {
                    setOverride(60)
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
        if maxFPS > 0 { MirageClientService.lastKnownScreenMaxFPS = maxFPS }
        let target = maxFPS >= 120 ? 120 : 60
        setOverride(target)
    }

    private func resolveScreenMaxFPS() -> Int {
        #if os(iOS)
        if let screen = view?.window?.windowScene?.screen { return screen.maximumFramesPerSecond }
        if let screen = view?.window?.screen { return screen.maximumFramesPerSecond }
        return 60
        #else
        // visionOS doesn't have UIScreen; use 90 fps (Vision Pro native rate)
        // TODO: Support 120fps on M5 Vision Pro when Apple provides API to detect display capabilities
        return 90
        #endif
    }

    private func setOverride(_ newValue: Int) {
        let clamped = newValue >= 120 ? 120 : 60
        guard currentOverride != clamped else { return }
        currentOverride = clamped
        onOverrideChange?(clamped)
    }
}
#endif
