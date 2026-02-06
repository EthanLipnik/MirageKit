//
//  InputStreamCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Cached stream entry with all info needed for fast input mapping
struct InputStreamCacheEntry {
    var window: MirageWindow
    var client: MirageConnectedClient
    /// The content rect within the capture buffer (for offset adjustment)
    /// Origin indicates padding at top-left, size is the actual content dimensions
    var contentRect: CGRect = .zero
}

/// Thread-safe cache for stream info used by fast input path
/// Using a class with lock for synchronous access from inputQueue
final class InputStreamCacheActor: @unchecked Sendable {
    private var cache: [StreamID: InputStreamCacheEntry] = [:]
    private let lock = NSLock()

    func set(_ streamID: StreamID, window: MirageWindow, client: MirageConnectedClient) {
        lock.lock()
        cache[streamID] = InputStreamCacheEntry(window: window, client: client)
        lock.unlock()
    }

    func remove(_ streamID: StreamID) {
        lock.lock()
        cache.removeValue(forKey: streamID)
        lock.unlock()
    }

    func get(_ streamID: StreamID) -> InputStreamCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[streamID]
    }

    /// Update the window frame in the cache after window move/resize
    /// Critical for correct mouse coordinate translation after virtual display moves
    func updateWindowFrame(_ streamID: StreamID, newFrame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.window = MirageWindow(
            id: entry.window.id,
            title: entry.window.title,
            application: entry.window.application,
            frame: newFrame,
            isOnScreen: entry.window.isOnScreen,
            windowLayer: entry.window.windowLayer
        )
        cache[streamID] = entry
    }

    /// Update the content rect for a stream (for coordinate offset adjustment)
    /// Called when capture frames arrive with contentRect metadata
    func updateContentRect(_ streamID: StreamID, contentRect: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[streamID] else { return }
        entry.contentRect = contentRect
        cache[streamID] = entry
    }

    /// Get stream ID for a given window ID (for updating frame by windowID)
    func getStreamID(forWindowID windowID: WindowID) -> StreamID? {
        lock.lock()
        defer { lock.unlock() }
        return cache.first(where: { $0.value.window.id == windowID })?.key
    }
}

#endif
