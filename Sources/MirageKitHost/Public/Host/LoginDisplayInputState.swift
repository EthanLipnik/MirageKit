//
//  LoginDisplayInputState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Thread-safe login display input tracking.
//

import Foundation
import MirageKit

#if os(macOS)
final class LoginDisplayInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var streamID: StreamID?
    private var bounds: CGRect = .zero
    private var lastCursorPosition: CGPoint = .zero
    private var hasCursorPosition = false
    private var hasReceivedFocusEvent = false

    func update(streamID: StreamID, bounds: CGRect) {
        lock.lock()
        self.streamID = streamID
        self.bounds = bounds
        lastCursorPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        hasCursorPosition = false
        hasReceivedFocusEvent = false
        lock.unlock()
        MirageLogger.host("LoginDisplayInputState registered: streamID=\(streamID), bounds=\(bounds)")
    }

    func clear() {
        lock.lock()
        let previousID = streamID
        streamID = nil
        bounds = .zero
        hasCursorPosition = false
        hasReceivedFocusEvent = false
        lock.unlock()
        if let previousID { MirageLogger.host("LoginDisplayInputState cleared: was streamID=\(previousID)") }
    }

    func getInfo(for streamID: StreamID)
    -> (bounds: CGRect, lastCursorPosition: CGPoint, hasCursorPosition: Bool, hasReceivedFocusEvent: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedID = self.streamID, storedID == streamID else { return nil }
        return (bounds, lastCursorPosition, hasCursorPosition, hasReceivedFocusEvent)
    }

    /// Mark that a focus-establishing event has been received (mouse click or explicit focus call).
    func markFocusReceived() {
        lock.lock()
        hasReceivedFocusEvent = true
        lock.unlock()
    }

    func updateCursorPosition(_ point: CGPoint) {
        lock.lock()
        lastCursorPosition = point
        hasCursorPosition = true
        lock.unlock()
    }
}
#endif
