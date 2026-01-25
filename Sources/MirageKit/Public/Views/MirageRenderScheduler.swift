//
//  MirageRenderScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame-driven render scheduler for stream views.
//

import Foundation

// @unchecked Sendable: state access is guarded by NSLock and views are used on MainActor only.
final class MirageRenderScheduler: @unchecked Sendable {
    static let shared = MirageRenderScheduler()

    private struct StreamState {
        var view: WeakMetalView
        var isPending: Bool
        var needsReschedule: Bool
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

    func register(view: MirageMetalView, for streamID: StreamID) {
        lock.lock()
        states[streamID] = StreamState(
            view: WeakMetalView(view),
            isPending: false,
            needsReschedule: false
        )
        lock.unlock()
    }

    func unregister(streamID: StreamID) {
        lock.lock()
        states.removeValue(forKey: streamID)
        lock.unlock()
    }

    func signalFrame(for streamID: StreamID) {
        var view: MirageMetalView?

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

        if state.isPending {
            state.needsReschedule = true
            states[streamID] = state
            lock.unlock()
            return
        }

        state.isPending = true
        states[streamID] = state
        view = resolvedView
        lock.unlock()

        Task { @MainActor [weak self, weak view] in
            guard let self else { return }
            view?.draw()
            self.completeDraw(for: streamID)
        }
    }

    private func completeDraw(for streamID: StreamID) {
        var shouldReschedule = false

        lock.lock()
        guard var state = states[streamID] else {
            lock.unlock()
            return
        }

        state.isPending = false
        if state.needsReschedule {
            state.needsReschedule = false
            shouldReschedule = true
        }
        states[streamID] = state
        lock.unlock()

        if shouldReschedule {
            signalFrame(for: streamID)
        }
    }
}
