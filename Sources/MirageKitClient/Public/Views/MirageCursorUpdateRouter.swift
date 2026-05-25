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

/// Coalesces cursor refresh requests and routes them to the active input view for each stream.
public final class MirageCursorUpdateRouter: @unchecked Sendable {
    /// Shared router used by stream views and cursor stores.
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

    /// Schedules a cursor refresh for a stream, optionally bypassing normal deduplication in the view.
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
                let flushStart = CFAbsoluteTimeGetCurrent()
                for (streamID, force) in refreshes {
                    view(for: streamID)?.refreshCursorUpdates(force: force)
                }
                MirageCursorLatencyProbe.routerFlush(
                    refreshCount: refreshes.count,
                    forcedCount: refreshes.reduce(0) { count, refresh in
                        count + (refresh.1 ? 1 : 0)
                    },
                    flushMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: flushStart)
                )
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
}
#endif
