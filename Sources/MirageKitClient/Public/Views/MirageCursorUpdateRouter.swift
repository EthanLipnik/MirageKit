//
//  MirageCursorUpdateRouter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Cursor update routing for input capture views.
//

import MirageKit
#if os(iOS) || os(visionOS) || os(macOS)
import Foundation

@MainActor
protocol MirageCursorUpdateHandling: AnyObject {
    func refreshCursorUpdates(force: Bool)
}

final class MirageCursorUpdateRouter: @unchecked Sendable {
    static let shared = MirageCursorUpdateRouter()

    private final class WeakCursorView {
        weak var value: (any MirageCursorUpdateHandling)?

        init(_ value: any MirageCursorUpdateHandling) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var viewsByStream: [StreamID: WeakCursorView] = [:]

    private init() {}

    func register(view: any MirageCursorUpdateHandling, for streamID: StreamID) {
        lock.lock()
        viewsByStream[streamID] = WeakCursorView(view)
        lock.unlock()
    }

    func unregister(streamID: StreamID) {
        lock.lock()
        viewsByStream.removeValue(forKey: streamID)
        lock.unlock()
    }

    func notify(streamID: StreamID) {
        lock.lock()
        let view = viewsByStream[streamID]?.value
        if view == nil { viewsByStream.removeValue(forKey: streamID) }
        lock.unlock()

        guard let view else { return }

        Task { @MainActor [weak view] in
            view?.refreshCursorUpdates(force: true)
        }
    }
}
#endif
