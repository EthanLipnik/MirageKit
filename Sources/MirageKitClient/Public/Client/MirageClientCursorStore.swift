//
//  MirageClientCursorStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

/// Latest cursor shape and visibility received for a streamed display.
public struct MirageCursorSnapshot: Sendable, Equatable {
    /// Cursor shape reported by the host.
    public let cursorType: MirageCursorType
    /// Whether the host cursor should be visible in the stream view.
    public let isVisible: Bool
    /// Monotonic generation that increments whenever the snapshot changes.
    public let sequence: UInt64

    /// Creates a cursor snapshot.
    public init(cursorType: MirageCursorType, isVisible: Bool, sequence: UInt64) {
        self.cursorType = cursorType
        self.isVisible = isVisible
        self.sequence = sequence
    }
}

/// Thread-safe cursor store for streamed sessions.
public final class MirageClientCursorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [StreamID: MirageCursorSnapshot] = [:]

    /// Creates an empty cursor store.
    public init() {}

    /// Updates cursor state for a stream.
    /// - Returns: `true` when the cursor state changed and the sequence advanced.
    public func updateCursor(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let existing = cursors[streamID]
        if let existing,
           existing.cursorType == cursorType,
           existing.isVisible == isVisible {
            return false
        }

        let nextSequence = (existing?.sequence ?? 0) &+ 1
        cursors[streamID] = MirageCursorSnapshot(
            cursorType: cursorType,
            isVisible: isVisible,
            sequence: nextSequence
        )
        return true
    }

    /// Returns the latest cursor state for a stream.
    public func snapshot(for streamID: StreamID) -> MirageCursorSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return cursors[streamID]
    }

    /// Clears cursor state for a stream.
    public func clear(streamID: StreamID) {
        lock.lock()
        defer { lock.unlock() }
        cursors.removeValue(forKey: streamID)
    }

    /// Clears all cursor state.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        cursors.removeAll()
    }
}
