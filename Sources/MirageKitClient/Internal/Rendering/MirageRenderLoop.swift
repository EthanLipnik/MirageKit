//
//  MirageRenderLoop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Dedicated render scheduler that keeps decode-to-render flow off the MainActor.
//

import Foundation
import MirageKit

@MainActor
protocol MirageRenderLoopDelegate: AnyObject {
    func renderLoopDraw(
        now: CFAbsoluteTime,
        decision: MirageRenderModeDecision,
        completion: @escaping @Sendable (MirageRenderDrawOutcome) -> Void
    )

    func renderLoopScaleChanged(_ scale: Double)
}

struct MirageRenderDrawOutcome: Sendable {
    let drawableWaitMs: Double
    let rendered: Bool
}

final class MirageRenderLoop: @unchecked Sendable {
    private enum PulseSource {
        case display
        case frameSignal
    }

    private let lock = NSLock()
    private let schedulingQueue = DispatchQueue(label: "com.mirage.client.render.loop", qos: .userInteractive)
    private let clock: MirageRenderClock

    private weak var delegate: MirageRenderLoopDelegate?
    private var streamID: StreamID?
    private var latencyMode: MirageStreamLatencyMode = .auto
    private var targetFPS: Int = 60
    private var allowDegradationRecovery = false

    private var running = false
    private var pendingRedraw = true
    private var drawDispatchScheduled = false
    private var lastOffCycleWakeTime: CFAbsoluteTime = 0

    private var scaleController = MirageRenderLoopScaleController()
    private var currentScale: Double = 1.0

    init(delegate: MirageRenderLoopDelegate, clock: MirageRenderClock = MirageRenderClockFactory.make()) {
        self.delegate = delegate
        self.clock = clock
        clock.onPulse = { [weak self] now in
            guard let self else { return }
            self.schedulingQueue.async { [weak self] in
                self?.handlePulse(now: now, source: .display)
            }
        }
    }

    deinit {
        if let streamID {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: self)
        }
        clock.stop()
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        lock.unlock()

        clock.updateTargetFPS(normalized)
        clock.start()
    }

    func stop() {
        lock.lock()
        running = false
        pendingRedraw = false
        drawDispatchScheduled = false
        lock.unlock()
        clock.stop()
    }

    func setStreamID(_ streamID: StreamID?) {
        let previousStreamID: StreamID?
        let currentTargetFPS: Int
        lock.lock()
        previousStreamID = self.streamID
        self.streamID = streamID
        currentTargetFPS = targetFPS
        pendingRedraw = true
        lock.unlock()

        if let previousStreamID {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: previousStreamID, owner: self)
        }

        if let streamID {
            MirageFrameCache.shared.setTargetFPS(currentTargetFPS, for: streamID)
            MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: self) { [weak self] in
                self?.handleFrameAvailableSignal()
            }
        }
    }

    func updateLatencyMode(_ latencyMode: MirageStreamLatencyMode) {
        lock.lock()
        self.latencyMode = latencyMode
        pendingRedraw = true
        lock.unlock()
    }

    func updateTargetFPS(_ fps: Int) {
        let streamID: StreamID?
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(fps)
        lock.lock()
        targetFPS = normalized
        streamID = self.streamID
        pendingRedraw = true
        lock.unlock()
        if let streamID {
            MirageFrameCache.shared.setTargetFPS(normalized, for: streamID)
        }
        clock.updateTargetFPS(normalized)
    }

    func updateAllowDegradationRecovery(_ enabled: Bool) {
        var notifyScaleReset = false
        lock.lock()
        allowDegradationRecovery = enabled
        if !enabled, currentScale != 1.0 {
            scaleController.reset()
            currentScale = 1.0
            notifyScaleReset = true
        }
        pendingRedraw = true
        lock.unlock()

        guard notifyScaleReset else { return }
        dispatchToMain { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.renderLoopScaleChanged(1.0)
            }
        }
    }

    func requestRedraw() {
        lock.lock()
        pendingRedraw = true
        lock.unlock()
    }

    func currentRenderScale() -> Double {
        lock.lock()
        let value = currentScale
        lock.unlock()
        return value
    }

    private func handleFrameAvailableSignal() {
        let now = CFAbsoluteTimeGetCurrent()
        let resolvedStreamID: StreamID?
        let resolvedLatencyMode: MirageStreamLatencyMode
        let resolvedTargetFPS: Int
        let shouldWakeImmediately: Bool

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }

        pendingRedraw = true
        resolvedStreamID = streamID
        resolvedLatencyMode = latencyMode
        resolvedTargetFPS = targetFPS
        lock.unlock()

        let typingBurstActive = resolvedStreamID.map {
            MirageRenderStreamStore.shared.isTypingBurstActive(for: $0, now: now)
        } ?? false
        let telemetry = resolvedStreamID.map {
            MirageFrameCache.shared.renderTelemetrySnapshot(for: $0)
        }

        let decision = MirageRenderModePolicy.decision(
            latencyMode: resolvedLatencyMode,
            typingBurstActive: typingBurstActive,
            decodeHealthy: telemetry?.decodeHealthy ?? true,
            targetFPS: resolvedTargetFPS
        )

        if decision.allowOffCycleWake {
            lock.lock()
            if now - lastOffCycleWakeTime >= offCycleWakeMinInterval(for: resolvedTargetFPS) {
                lastOffCycleWakeTime = now
                shouldWakeImmediately = true
            } else {
                shouldWakeImmediately = false
            }
            lock.unlock()
        } else {
            shouldWakeImmediately = false
        }

        guard shouldWakeImmediately else { return }
        schedulingQueue.async { [weak self] in
            self?.handlePulse(now: now, source: .frameSignal)
        }
    }

    private func handlePulse(now: CFAbsoluteTime, source _: PulseSource) {
        let shouldDispatch: Bool
        let decision: MirageRenderModeDecision

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }

        let resolvedStreamID = streamID
        let typingBurstActive = resolvedStreamID.map {
            MirageRenderStreamStore.shared.isTypingBurstActive(for: $0, now: now)
        } ?? false
        let telemetry = resolvedStreamID.map {
            MirageFrameCache.shared.renderTelemetrySnapshot(for: $0)
        }

        decision = MirageRenderModePolicy.decision(
            latencyMode: latencyMode,
            typingBurstActive: typingBurstActive,
            decodeHealthy: telemetry?.decodeHealthy ?? true,
            targetFPS: targetFPS
        )

        let hasFrames = (telemetry?.queueDepth ?? 0) > 0
        let shouldDraw = pendingRedraw || hasFrames
        if shouldDraw {
            if drawDispatchScheduled {
                pendingRedraw = true
                shouldDispatch = false
            } else {
                pendingRedraw = false
                drawDispatchScheduled = true
                shouldDispatch = true
            }
        } else {
            shouldDispatch = false
        }
        lock.unlock()

        guard shouldDispatch else { return }
        dispatchToMain { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.renderLoopDraw(now: now, decision: decision) { [weak self] outcome in
                    guard let self else { return }
                    self.schedulingQueue.async { [weak self] in
                        self?.completeDraw(outcome)
                    }
                }
            }
        }
    }

    private func completeDraw(_ outcome: MirageRenderDrawOutcome) {
        let transition: MirageRenderLoopScaleTransition?
        let shouldForceRedraw = !outcome.rendered
        lock.lock()
        let frameBudgetMs = 1000.0 / Double(max(1, targetFPS))
        transition = scaleController.evaluate(
            now: CFAbsoluteTimeGetCurrent(),
            allowDegradation: allowDegradationRecovery,
            frameBudgetMs: frameBudgetMs,
            drawableWaitMs: outcome.drawableWaitMs
        )
        if let transition {
            currentScale = transition.newScale
            pendingRedraw = true
        }
        if shouldForceRedraw {
            pendingRedraw = true
        }
        drawDispatchScheduled = false
        lock.unlock()

        if let transition {
            dispatchToMain { [weak self] in
                MainActor.assumeIsolated {
                    self?.delegate?.renderLoopScaleChanged(transition.newScale)
                }
            }
        }
    }

    private func offCycleWakeMinInterval(for targetFPS: Int) -> CFAbsoluteTime {
        let fps = Double(max(1, MirageRenderModePolicy.normalizedTargetFPS(targetFPS)))
        return 0.5 / fps
    }

    private func dispatchToMain(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
            return
        }

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(mainRunLoop)
    }
}
