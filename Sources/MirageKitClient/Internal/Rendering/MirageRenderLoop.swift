//
//  MirageRenderLoop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Unified display loop that drives mode-aware presentation.
//

import Foundation
import MirageKit

@MainActor
protocol MirageRenderLoopDelegate: AnyObject {
    func renderLoopDraw(now: CFAbsoluteTime, decision: MirageRenderModeDecision)
    func renderLoopScaleChanged(_ scale: Double)
}

final class MirageRenderLoop: @unchecked Sendable {
    private enum PulseSource {
        case display
        case frameSignal
    }

    private let lock = NSLock()
    private let clock: MirageRenderClock

    private struct RenderLoopDiagnosticsSnapshot {
        let elapsed: CFAbsoluteTime
        let targetFPS: Int
        let displayPulses: UInt64
        let frameSignalPulses: UInt64
        let drawDispatches: UInt64
        let busySkips: UInt64
        let idleSkips: UInt64
        let queueDepth: Int
        let decodeFPS: Double
        let decodeHealthy: Bool
        let pendingRedraw: Bool
    }

    private weak var delegate: MirageRenderLoopDelegate?
    private var streamID: StreamID?
    private var latencyMode: MirageStreamLatencyMode = .auto
    private var targetFPS: Int = 60
    private var allowDegradationRecovery: Bool = false

    private var running = false
    private var pendingRedraw = true
    private var drawDispatchScheduled = false
    private var lastOffCycleWakeTime: CFAbsoluteTime = 0

    private var scaleController = MirageRenderLoopScaleController()
    private var currentScale: Double = 1.0

    private var diagnosticsWindowStart: CFAbsoluteTime = 0
    private var diagnosticsDisplayPulses: UInt64 = 0
    private var diagnosticsFrameSignalPulses: UInt64 = 0
    private var diagnosticsDrawDispatches: UInt64 = 0
    private var diagnosticsBusySkips: UInt64 = 0
    private var diagnosticsIdleSkips: UInt64 = 0

    init(delegate: MirageRenderLoopDelegate, clock: MirageRenderClock = MirageRenderClockFactory.make()) {
        self.delegate = delegate
        self.clock = clock
        clock.onPulse = { [weak self] now in
            self?.handlePulse(now: now, source: .display)
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

        if notifyScaleReset {
            Task { @MainActor [weak delegate] in
                delegate?.renderLoopScaleChanged(1.0)
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

    func recordDrawResult(
        drawableWaitMs: Double,
        rendered: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        let transition: MirageRenderLoopScaleTransition?
        lock.lock()
        let frameBudgetMs = 1000.0 / Double(max(1, targetFPS))
        transition = scaleController.evaluate(
            now: now,
            allowDegradation: allowDegradationRecovery,
            frameBudgetMs: frameBudgetMs,
            drawableWaitMs: drawableWaitMs
        )
        if let transition {
            currentScale = transition.newScale
            pendingRedraw = true
        }
        lock.unlock()

        guard let transition else { return }
        Task { @MainActor [weak delegate] in
            delegate?.renderLoopScaleChanged(transition.newScale)
        }

        if MirageLogger.isEnabled(.renderer) {
            let fromText = transition.previousScale.formatted(.number.precision(.fractionLength(2)))
            let toText = transition.newScale.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.renderer(
                "Render scale transition direction=\(transition.direction.rawValue) scale=\(fromText)->\(toText) rendered=\(rendered)"
            )
        }
    }

    private func handleFrameAvailableSignal() {
        let shouldWakeImmediately: Bool
        let decision: MirageRenderModeDecision
        let now = CFAbsoluteTimeGetCurrent()
        let resolvedStreamID: StreamID?
        let resolvedLatencyMode: MirageStreamLatencyMode
        let resolvedTargetFPS: Int

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

        decision = MirageRenderModePolicy.decision(
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
        handlePulse(now: now, source: .frameSignal)
    }

    private func handlePulse(now: CFAbsoluteTime, source: PulseSource) {
        let shouldDraw: Bool
        let shouldDispatch: Bool
        let decision: MirageRenderModeDecision
        let diagnosticsSnapshot: RenderLoopDiagnosticsSnapshot?
        let queueDepth: Int
        let decodeFPS: Double
        let decodeHealthy: Bool

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }

        switch source {
        case .display:
            diagnosticsDisplayPulses &+= 1
        case .frameSignal:
            diagnosticsFrameSignalPulses &+= 1
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

        queueDepth = telemetry?.queueDepth ?? 0
        decodeFPS = telemetry?.decodeFPS ?? 0
        decodeHealthy = telemetry?.decodeHealthy ?? true

        let hasFrames = queueDepth > 0
        shouldDraw = pendingRedraw || hasFrames
        if shouldDraw {
            if drawDispatchScheduled {
                pendingRedraw = true
                diagnosticsBusySkips &+= 1
                shouldDispatch = false
            } else {
                pendingRedraw = false
                drawDispatchScheduled = true
                diagnosticsDrawDispatches &+= 1
                shouldDispatch = true
            }
        } else {
            diagnosticsIdleSkips &+= 1
            shouldDispatch = false
        }

        diagnosticsSnapshot = maybeCaptureDiagnosticsSnapshot(
            now: now,
            queueDepth: queueDepth,
            decodeFPS: decodeFPS,
            decodeHealthy: decodeHealthy
        )
        lock.unlock()

        if let diagnosticsSnapshot {
            emitDiagnostics(diagnosticsSnapshot)
        }

        guard shouldDraw, shouldDispatch else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.renderLoopDraw(now: now, decision: decision)
            self.clearDrawDispatchScheduledFlag()
        }
    }

    private func offCycleWakeMinInterval(for targetFPS: Int) -> CFAbsoluteTime {
        let fps = Double(max(1, MirageRenderModePolicy.normalizedTargetFPS(targetFPS)))
        return 0.5 / fps
    }

    private func clearDrawDispatchScheduledFlag() {
        lock.lock()
        drawDispatchScheduled = false
        lock.unlock()
    }

    private func maybeCaptureDiagnosticsSnapshot(
        now: CFAbsoluteTime,
        queueDepth: Int,
        decodeFPS: Double,
        decodeHealthy: Bool
    ) -> RenderLoopDiagnosticsSnapshot? {
        guard MirageLogger.isEnabled(.renderer) else { return nil }
        if diagnosticsWindowStart == 0 {
            diagnosticsWindowStart = now
            return nil
        }

        let elapsed = now - diagnosticsWindowStart
        guard elapsed >= 1.0 else { return nil }

        let snapshot = RenderLoopDiagnosticsSnapshot(
            elapsed: elapsed,
            targetFPS: targetFPS,
            displayPulses: diagnosticsDisplayPulses,
            frameSignalPulses: diagnosticsFrameSignalPulses,
            drawDispatches: diagnosticsDrawDispatches,
            busySkips: diagnosticsBusySkips,
            idleSkips: diagnosticsIdleSkips,
            queueDepth: queueDepth,
            decodeFPS: decodeFPS,
            decodeHealthy: decodeHealthy,
            pendingRedraw: pendingRedraw
        )

        diagnosticsWindowStart = now
        diagnosticsDisplayPulses = 0
        diagnosticsFrameSignalPulses = 0
        diagnosticsDrawDispatches = 0
        diagnosticsBusySkips = 0
        diagnosticsIdleSkips = 0

        return snapshot
    }

    private func emitDiagnostics(_ snapshot: RenderLoopDiagnosticsSnapshot) {
        let seconds = max(0.001, snapshot.elapsed)
        let displayHz = Double(snapshot.displayPulses) / seconds
        let signalHz = Double(snapshot.frameSignalPulses) / seconds
        let dispatchHz = Double(snapshot.drawDispatches) / seconds

        let displayText = displayHz.formatted(.number.precision(.fractionLength(1)))
        let signalText = signalHz.formatted(.number.precision(.fractionLength(1)))
        let dispatchText = dispatchHz.formatted(.number.precision(.fractionLength(1)))
        let decodeText = snapshot.decodeFPS.formatted(.number.precision(.fractionLength(1)))

        MirageLogger.renderer(
            "Render loop stats target=\(snapshot.targetFPS)Hz display=\(displayText)Hz " +
                "signal=\(signalText)Hz dispatch=\(dispatchText)Hz " +
                "busySkips=\(snapshot.busySkips) idleSkips=\(snapshot.idleSkips) " +
                "queueDepth=\(snapshot.queueDepth) decode=\(decodeText)Hz " +
                "healthy=\(snapshot.decodeHealthy) pendingRedraw=\(snapshot.pendingRedraw)"
        )
    }
}
