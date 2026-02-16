//
//  MirageClientRenderTrigger.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Decode-driven render trigger for client Metal views.
//

import Foundation
import MirageKit

#if os(macOS) || os(iOS) || os(visionOS)
/// @unchecked Sendable: access is guarded by NSLock and views are used on MainActor only.
final class MirageClientRenderTrigger: @unchecked Sendable {
    static let shared = MirageClientRenderTrigger()

    struct CoalescingState: Equatable {
        var pending = false
        var resignalNeeded = false

        mutating func handleRequest() -> Bool {
            if pending {
                resignalNeeded = true
                return false
            }
            pending = true
            return true
        }

        mutating func handleCompletion() -> Bool {
            if resignalNeeded {
                resignalNeeded = false
                pending = true
                return true
            }
            pending = false
            return false
        }
    }

    private final class WeakMetalView {
        weak var value: MirageMetalView?

        init(_ value: MirageMetalView) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var views: [StreamID: WeakMetalView] = [:]
    private var requestStates: [StreamID: CoalescingState] = [:]
    private var decodeDrivenRequestsEnabled: [StreamID: Bool] = [:]

    private init() {}

    func register(view: MirageMetalView, for streamID: StreamID) {
        lock.lock()
        views[streamID] = WeakMetalView(view)
        if requestStates[streamID] == nil {
            requestStates[streamID] = CoalescingState()
        }
        decodeDrivenRequestsEnabled[streamID] = true
        lock.unlock()
    }

    func unregister(streamID: StreamID) {
        lock.lock()
        views.removeValue(forKey: streamID)
        requestStates.removeValue(forKey: streamID)
        decodeDrivenRequestsEnabled.removeValue(forKey: streamID)
        lock.unlock()
    }

    func setDecodeDrivenRequestsEnabled(_ enabled: Bool, for streamID: StreamID) {
        lock.lock()
        decodeDrivenRequestsEnabled[streamID] = enabled
        if !enabled {
            requestStates[streamID] = CoalescingState()
        } else if requestStates[streamID] == nil {
            requestStates[streamID] = CoalescingState()
        }
        lock.unlock()
    }

    func requestDraw(for streamID: StreamID) {
        var view: MirageMetalView?
        var shouldDispatch = false
        lock.lock()
        if let resolved = views[streamID]?.value {
            let requestsEnabled = decodeDrivenRequestsEnabled[streamID] ?? true
            if !requestsEnabled {
                requestStates[streamID] = CoalescingState()
                lock.unlock()
                return
            }
            var state = requestStates[streamID] ?? CoalescingState()
            shouldDispatch = state.handleRequest()
            requestStates[streamID] = state
            view = resolved
        } else {
            views.removeValue(forKey: streamID)
            requestStates.removeValue(forKey: streamID)
            decodeDrivenRequestsEnabled.removeValue(forKey: streamID)
        }
        lock.unlock()

        guard shouldDispatch, let view else { return }
        dispatchDraw(for: streamID, view: view)
    }

    private func finishRequest(for streamID: StreamID) {
        var followUpView: MirageMetalView?
        var shouldDispatchFollowUp = false
        lock.lock()
        guard var state = requestStates[streamID] else {
            lock.unlock()
            return
        }
        shouldDispatchFollowUp = state.handleCompletion()
        requestStates[streamID] = state
        if shouldDispatchFollowUp {
            followUpView = views[streamID]?.value
        }
        lock.unlock()

        if shouldDispatchFollowUp, let followUpView {
            dispatchDraw(for: streamID, view: followUpView)
        }
    }

    private func dispatchDraw(for streamID: StreamID, view: MirageMetalView) {
        Task { @MainActor [weak view] in
            view?.requestDraw()
            self.finishRequest(for: streamID)
        }
    }
}
#endif
