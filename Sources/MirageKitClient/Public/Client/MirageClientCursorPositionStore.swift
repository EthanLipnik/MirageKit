//
//  MirageClientCursorPositionStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Thread-safe cursor position snapshots for streamed sessions.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

/// Latest normalized cursor position and visibility received for a streamed display.
public struct MirageCursorPositionSnapshot: Sendable, Equatable {
    /// Cursor position in stream-local normalized coordinates.
    public let position: CGPoint
    /// Whether the host cursor should be visible in the stream view.
    public let isVisible: Bool
    /// Monotonic generation that increments whenever the snapshot changes.
    public let sequence: UInt64

    /// Creates a cursor position snapshot.
    public init(position: CGPoint, isVisible: Bool, sequence: UInt64) {
        self.position = position
        self.isVisible = isVisible
        self.sequence = sequence
    }
}

/// Thread-safe cursor position store for streamed sessions.
public final class MirageClientCursorPositionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var positions: [StreamID: MirageCursorPositionSnapshot] = [:]

    /// Creates an empty cursor position store.
    public init() {}

    /// Updates cursor position for a stream.
    /// - Returns: `true` when the cursor position or visibility changed and the sequence advanced.
    public func updatePosition(streamID: StreamID, position: CGPoint, isVisible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let existing = positions[streamID]
        if let existing,
           existing.position == position,
           existing.isVisible == isVisible {
            return false
        }

        let nextSequence = (existing?.sequence ?? 0) &+ 1
        positions[streamID] = MirageCursorPositionSnapshot(
            position: position,
            isVisible: isVisible,
            sequence: nextSequence
        )
        return true
    }

    /// Returns the latest cursor position for a stream.
    public func snapshot(for streamID: StreamID) -> MirageCursorPositionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return positions[streamID]
    }

    /// Clears cursor position for a stream.
    public func clear(streamID: StreamID) {
        lock.lock()
        defer { lock.unlock() }
        positions.removeValue(forKey: streamID)
    }

    /// Clears all cursor positions.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        positions.removeAll()
    }
}
