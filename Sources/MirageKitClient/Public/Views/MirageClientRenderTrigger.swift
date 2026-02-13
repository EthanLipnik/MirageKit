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

    private final class WeakMetalView {
        weak var value: MirageMetalView?

        init(_ value: MirageMetalView) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var views: [StreamID: WeakMetalView] = [:]
    private var pendingRequests: Set<StreamID> = []

    private init() {}

    func register(view: MirageMetalView, for streamID: StreamID) {
        lock.lock()
        views[streamID] = WeakMetalView(view)
        lock.unlock()
    }

    func unregister(streamID: StreamID) {
        lock.lock()
        views.removeValue(forKey: streamID)
        pendingRequests.remove(streamID)
        lock.unlock()
    }

    func requestDraw(for streamID: StreamID) {
        var view: MirageMetalView?
        lock.lock()
        if let resolved = views[streamID]?.value {
            if pendingRequests.contains(streamID) {
                lock.unlock()
                return
            }
            pendingRequests.insert(streamID)
            view = resolved
        } else {
            views.removeValue(forKey: streamID)
            pendingRequests.remove(streamID)
        }
        lock.unlock()

        guard let view else { return }
        Task { @MainActor [weak view] in
            view?.requestDraw()
            self.finishRequest(for: streamID)
        }
    }

    private func finishRequest(for streamID: StreamID) {
        lock.lock()
        pendingRequests.remove(streamID)
        lock.unlock()
    }
}
#endif
