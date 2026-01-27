//
//  MirageRenderScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame-driven render scheduler for stream views.
//

import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

// @unchecked Sendable: state access is guarded by NSLock and views are used on MainActor only.
final class MirageRenderScheduler: @unchecked Sendable {
    static let shared = MirageRenderScheduler()

    private struct StreamState {
        var view: WeakMetalView
        var inFlightCount: Int
        var pendingCount: Int
        var maxInFlightCount: Int
        var maxDrawableCount: Int
        var renderLogStartTime: CFAbsoluteTime
        var renderCount: UInt64
    }

    private final class WeakMetalView {
        weak var value: MirageMetalView?

        init(_ value: MirageMetalView) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var states: [StreamID: StreamState] = [:]

    private init() {}

    @MainActor
    func register(view: MirageMetalView, for streamID: StreamID) {
        let maxInFlight: Int
        let maxDrawableCount: Int
        if let metalLayer = view.layer as? CAMetalLayer {
            // Keep one drawable free to avoid blocking the main thread in nextDrawable.
            maxDrawableCount = metalLayer.maximumDrawableCount
            maxInFlight = max(1, min(2, maxDrawableCount - 1))
        } else {
            maxDrawableCount = 0
            maxInFlight = 2
        }
        lock.lock()
        states[streamID] = StreamState(
            view: WeakMetalView(view),
            inFlightCount: 0,
            pendingCount: 0,
            maxInFlightCount: maxInFlight,
            maxDrawableCount: maxDrawableCount,
            renderLogStartTime: 0,
            renderCount: 0
        )
        lock.unlock()
        if MirageLogger.isEnabled(.renderer) {
            MirageLogger.renderer(
                "Render scheduler configured: stream=\(streamID) drawableMax=\(maxDrawableCount) inFlightMax=\(maxInFlight)"
            )
        }
        view.onDrawCompleted = { [weak self] in
            self?.completeDraw(for: streamID)
        }
    }

    @MainActor
    func unregister(streamID: StreamID) {
        var view: MirageMetalView?
        lock.lock()
        view = states[streamID]?.view.value
        states.removeValue(forKey: streamID)
        lock.unlock()
        view?.onDrawCompleted = nil
    }

    func signalFrame(for streamID: StreamID) {
        let signalTime = CFAbsoluteTimeGetCurrent()
        var view: MirageMetalView?
        var shouldDraw = false

        lock.lock()
        guard var state = states[streamID] else {
            lock.unlock()
            return
        }

        guard let resolvedView = state.view.value else {
            states.removeValue(forKey: streamID)
            lock.unlock()
            return
        }

        // Coalesce bursts of frames but preserve a small backlog so we can
        // pipeline draws up to the in-flight limit.
        let pendingLimit = max(2, state.maxInFlightCount * 2)
        state.pendingCount = min(state.pendingCount + 1, pendingLimit)

        if state.inFlightCount < state.maxInFlightCount {
            state.inFlightCount += 1
            state.pendingCount = max(0, state.pendingCount - 1)
            shouldDraw = true
        }
        states[streamID] = state
        view = shouldDraw ? resolvedView : nil
        lock.unlock()

        if shouldDraw {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                if let view {
                    view.noteScheduledDraw(signalTime: signalTime)
                    view.draw()
                } else {
                    self.completeDraw(for: streamID)
                }
            }
        }
    }

    private func completeDraw(for streamID: StreamID) {
        var shouldDraw = false
        var view: MirageMetalView?
        var renderFPS: Double?
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        guard var state = states[streamID] else {
            lock.unlock()
            return
        }

        state.inFlightCount = max(0, state.inFlightCount - 1)
        state.renderCount &+= 1
        if state.renderLogStartTime == 0 {
            state.renderLogStartTime = now
        } else if now - state.renderLogStartTime > 2.0 {
            let elapsed = now - state.renderLogStartTime
            renderFPS = Double(state.renderCount) / elapsed
            state.renderCount = 0
            state.renderLogStartTime = now
        }

        if state.pendingCount > 0,
           state.inFlightCount < state.maxInFlightCount,
           let resolvedView = state.view.value {
            state.pendingCount -= 1
            state.inFlightCount += 1
            shouldDraw = true
            view = resolvedView
        }
        states[streamID] = state
        lock.unlock()

        if let renderFPS, MirageLogger.isEnabled(.renderer) {
            let fpsText = renderFPS.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.renderer("Render fps: \(fpsText) (stream=\(streamID))")
        }

        if shouldDraw {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                if let view {
                    view.noteScheduledDraw(signalTime: now)
                    view.draw()
                } else {
                    self.completeDraw(for: streamID)
                }
            }
        }
    }
}
