//
//  ContinuationBox.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation

/// Thread-safe wrapper for throwing CheckedContinuation to prevent double-resume crashes.
///
/// Use this when a continuation may be resumed from multiple code paths or callbacks
/// (e.g., NWConnection state handlers where both ready and failed states might fire).
///
/// Example:
/// ```swift
/// let result = try await withCheckedThrowingContinuation { continuation in
///     let box = ContinuationBox(continuation)
///     connection.stateUpdateHandler = { state in
///         switch state {
///         case .ready:
///             box.resume(returning: connection.port)
///         case .failed(let error):
///             box.resume(throwing: error)
///         default: break
///         }
///     }
/// }
/// ```
package final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private nonisolated(unsafe) var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    package init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    package func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    package func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// Convenience extension for Void continuations
package extension ContinuationBox where T == Void {
    func resume() {
        resume(returning: ())
    }
}

/// Thread-safe wrapper for non-throwing CheckedContinuation.
///
/// Use this when a continuation will never fail (e.g., waiting for a state that always arrives).
/// The stored continuation is cleared before resume to enforce at-most-once behavior.
package final class SafeContinuationBox<T: Sendable>: @unchecked Sendable {
    private nonisolated(unsafe) var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    package init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    package func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
