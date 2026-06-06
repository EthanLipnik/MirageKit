//
//  Locked.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
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
import Foundation

#if os(macOS)
/// Small lock-backed container for shared mutable state.
final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initial: State) {
        state = initial
    }

    /// Runs a synchronous mutation while holding the underlying lock.
    func withLock(_ body: (inout State) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        try body(&state)
    }

    /// Runs a synchronous mutation while holding the underlying lock and returning a value.
    func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    /// Runs a synchronous read while holding the underlying lock.
    func read<T>(_ body: (State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(state)
    }
}
#endif
