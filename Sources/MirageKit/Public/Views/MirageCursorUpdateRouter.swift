//
//  MirageCursorUpdateRouter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Cursor update routing for input capture views.
//

#if os(iOS) || os(visionOS)
import Foundation

final class MirageCursorUpdateRouter: @unchecked Sendable {
    static let shared = MirageCursorUpdateRouter()

    private final class WeakInputView {
        weak var value: InputCapturingView?

        init(_ value: InputCapturingView) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var viewsByStream: [StreamID: WeakInputView] = [:]

    private init() {}

    func register(view: InputCapturingView, for streamID: StreamID) {
        lock.lock()
        viewsByStream[streamID] = WeakInputView(view)
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
        if view == nil {
            viewsByStream.removeValue(forKey: streamID)
        }
        lock.unlock()

        guard let view else { return }

        Task { @MainActor [weak view] in
            view?.refreshCursorIfNeeded(force: true)
        }
    }
}
#endif
