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

public final class MirageCursorUpdateRouter: @unchecked Sendable {
    public static let shared = MirageCursorUpdateRouter()

    private final class WeakCursorView {
        weak var value: (any MirageCursorUpdateHandling)?

        init(_ value: any MirageCursorUpdateHandling) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var viewsByStream: [StreamID: WeakCursorView] = [:]
    private var pendingStreamIDs: Set<StreamID> = []
    private var forcedStreamIDs: Set<StreamID> = []
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration

    init(flushInterval: Duration = MirageInteractionCadence.frameInterval120Duration) {
        self.flushInterval = flushInterval
    }

    deinit {
        lock.lock()
        let task = flushTask
        flushTask = nil
        lock.unlock()
        task?.cancel()
    }

    func register(view: any MirageCursorUpdateHandling, for streamID: StreamID) {
        lock.lock()
        viewsByStream[streamID] = WeakCursorView(view)
        lock.unlock()
    }

    func unregister(streamID: StreamID) {
        lock.lock()
        viewsByStream.removeValue(forKey: streamID)
        pendingStreamIDs.remove(streamID)
        forcedStreamIDs.remove(streamID)
        lock.unlock()
    }

    public func notify(streamID: StreamID, force: Bool = false) {
        lock.lock()
        if viewsByStream[streamID]?.value == nil {
            viewsByStream.removeValue(forKey: streamID)
            pendingStreamIDs.remove(streamID)
            forcedStreamIDs.remove(streamID)
            lock.unlock()
            return
        }
        pendingStreamIDs.insert(streamID)
        if force {
            forcedStreamIDs.insert(streamID)
        }
        startFlushTaskIfNeededLocked()
        lock.unlock()
    }

    private func startFlushTaskIfNeededLocked() {
        guard flushTask == nil else { return }
        flushTask = Task(priority: .high) { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        while !Task.isCancelled {
            let refreshes = takePendingRefreshes()
            guard !refreshes.isEmpty else { break }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for (streamID, force) in refreshes {
                    self.view(for: streamID)?.refreshCursorUpdates(force: force)
                }
            }

            do {
                try await Task.sleep(for: flushInterval)
            } catch {
                break
            }
        }

        finalizeFlushLoop()
    }

    private func finalizeFlushLoop() {
        lock.lock()
        flushTask = nil
        if !pendingStreamIDs.isEmpty {
            startFlushTaskIfNeededLocked()
        }
        lock.unlock()
    }

    private func takePendingRefreshes() -> [(StreamID, Bool)] {
        lock.lock()
        let refreshes = pendingStreamIDs.map { streamID in
            (streamID, forcedStreamIDs.contains(streamID))
        }
        pendingStreamIDs.removeAll(keepingCapacity: true)
        forcedStreamIDs.removeAll(keepingCapacity: true)
        lock.unlock()
        return refreshes
    }

    private func view(for streamID: StreamID) -> (any MirageCursorUpdateHandling)? {
        lock.lock()
        let view = viewsByStream[streamID]?.value
        if view == nil {
            viewsByStream.removeValue(forKey: streamID)
            pendingStreamIDs.remove(streamID)
            forcedStreamIDs.remove(streamID)
        }
        lock.unlock()
        return view
    }

    func debugPendingStreamCount() -> Int {
        lock.lock()
        let count = pendingStreamIDs.count
        lock.unlock()
        return count
    }

    func debugFlushTaskIsRunning() -> Bool {
        lock.lock()
        let isRunning = flushTask != nil
        lock.unlock()
        return isRunning
    }
}

extension MirageCursorUpdateRouter {
    static func makeForTesting(flushInterval: Duration) -> MirageCursorUpdateRouter {
        MirageCursorUpdateRouter(flushInterval: flushInterval)
    }
}
#endif
