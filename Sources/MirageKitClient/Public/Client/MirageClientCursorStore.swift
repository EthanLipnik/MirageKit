//
//  MirageClientCursorStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

public struct MirageCursorSnapshot: Sendable, Equatable {
    public let cursorType: MirageCursorType
    public let isVisible: Bool
    public let sequence: UInt64

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

    public init() {}

    /// Update cursor state for a stream.
    /// - Returns: True when the cursor state changed.
    @discardableResult
    public func updateCursor(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cursors[streamID],
           existing.cursorType == cursorType,
           existing.isVisible == isVisible {
            return false
        }

        let nextSequence = (cursors[streamID]?.sequence ?? 0) &+ 1
        cursors[streamID] = MirageCursorSnapshot(
            cursorType: cursorType,
            isVisible: isVisible,
            sequence: nextSequence
        )
        return true
    }

    /// Snapshot the latest cursor state for a stream.
    public func snapshot(for streamID: StreamID) -> MirageCursorSnapshot? {
        lock.lock()
        let result = cursors[streamID]
        lock.unlock()
        return result
    }

    /// Clear cursor state for a stream.
    public func clear(streamID: StreamID) {
        lock.lock()
        cursors.removeValue(forKey: streamID)
        lock.unlock()
    }

    /// Clear all cursor state.
    public func clearAll() {
        lock.lock()
        cursors.removeAll()
        lock.unlock()
    }
}
