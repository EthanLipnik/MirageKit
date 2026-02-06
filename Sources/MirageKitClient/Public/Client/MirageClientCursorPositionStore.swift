//
//  MirageClientCursorPositionStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Thread-safe cursor position snapshots for streamed sessions.
//

import CoreGraphics
import Foundation
import MirageKit

public struct MirageCursorPositionSnapshot: Sendable, Equatable {
    public let position: CGPoint
    public let isVisible: Bool
    public let sequence: UInt64

    public init(position: CGPoint, isVisible: Bool, sequence: UInt64) {
        self.position = position
        self.isVisible = isVisible
        self.sequence = sequence
    }
}

public final class MirageClientCursorPositionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var positions: [StreamID: MirageCursorPositionSnapshot] = [:]

    public init() {}

    /// Update cursor position for a stream.
    /// - Returns: True when the cursor state changed.
    @discardableResult
    public func updatePosition(streamID: StreamID, position: CGPoint, isVisible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let existing = positions[streamID],
           existing.position == position,
           existing.isVisible == isVisible {
            return false
        }

        let nextSequence = (positions[streamID]?.sequence ?? 0) &+ 1
        positions[streamID] = MirageCursorPositionSnapshot(
            position: position,
            isVisible: isVisible,
            sequence: nextSequence
        )
        return true
    }

    /// Snapshot the latest cursor position for a stream.
    public func snapshot(for streamID: StreamID) -> MirageCursorPositionSnapshot? {
        lock.lock()
        let result = positions[streamID]
        lock.unlock()
        return result
    }

    /// Clear cursor position for a stream.
    public func clear(streamID: StreamID) {
        lock.lock()
        positions.removeValue(forKey: streamID)
        lock.unlock()
    }

    /// Clear all cursor positions.
    public func clearAll() {
        lock.lock()
        positions.removeAll()
        lock.unlock()
    }
}
