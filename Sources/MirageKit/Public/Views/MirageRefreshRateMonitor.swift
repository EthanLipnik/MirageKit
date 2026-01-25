//
//  MirageRefreshRateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  MTKView refresh rate sampler for ProMotion overrides.
//

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
    private var displayLink: CADisplayLink?
    private var sampleContinuation: CheckedContinuation<Double, Never>?

    private var isSampling = false
    private var sampleStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var sampleCount: Int = 0
    private var sampleTotalFPS: Double = 0

    private var currentOverride: Int = 60
    private var highSampleStreak: Int = 0
    private var lowSampleStreak: Int = 0

    private let pollInterval: Duration = .seconds(3)
    private let sampleWindow: CFTimeInterval = 0.5
    private let highThreshold: Double = 90
    private let lowThreshold: Double = 75
    private let requiredSamples: Int = 2

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
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.isProMotionEnabled, self.isViewReadyForSampling {
                    let measured = await self.sampleDisplayLink()
                    self.evaluate(measured)
                } else if !self.isProMotionEnabled {
                    self.setOverride(60)
                }

                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        stopDisplayLink()
    }

    private func evaluate(_ measuredFPS: Double) {
        guard measuredFPS > 0 else { return }

        if measuredFPS >= highThreshold {
            highSampleStreak += 1
            lowSampleStreak = 0
        } else if measuredFPS <= lowThreshold {
            lowSampleStreak += 1
            highSampleStreak = 0
        } else {
            highSampleStreak = 0
            lowSampleStreak = 0
        }

        if currentOverride == 60, highSampleStreak >= requiredSamples {
            setOverride(120)
            return
        }

        if currentOverride == 120, lowSampleStreak >= requiredSamples {
            setOverride(60)
        }
    }

    private func setOverride(_ newValue: Int) {
        let clamped = newValue >= 120 ? 120 : 60
        guard currentOverride != clamped else { return }
        currentOverride = clamped
        onOverrideChange?(clamped)
    }

    private func sampleDisplayLink() async -> Double {
        guard !isSampling else { return 0 }
        guard isViewReadyForSampling else { return 0 }
        isSampling = true

        return await withCheckedContinuation { continuation in
            sampleContinuation = continuation
            sampleStart = 0
            lastTimestamp = 0
            sampleCount = 0
            sampleTotalFPS = 0

            let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
            configureDisplayLink(link)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func configureDisplayLink(_ link: CADisplayLink) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        if sampleStart == 0 {
            sampleStart = link.timestamp
            lastTimestamp = link.timestamp
            return
        }

        let dt = link.timestamp - lastTimestamp
        if dt > 0 {
            sampleTotalFPS += 1.0 / dt
            sampleCount += 1
        }
        lastTimestamp = link.timestamp

        if link.timestamp - sampleStart >= sampleWindow {
            finalizeSample()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        if isSampling {
            finalizeSample()
        }
    }

    private func finalizeSample() {
        displayLink?.invalidate()
        displayLink = nil
        let averageFPS = sampleCount > 0 ? (sampleTotalFPS / Double(sampleCount)) : 0
        isSampling = false
        sampleContinuation?.resume(returning: averageFPS)
        sampleContinuation = nil
    }
}
#endif
