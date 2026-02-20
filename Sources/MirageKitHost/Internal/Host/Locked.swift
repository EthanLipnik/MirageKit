//
//  Locked.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation

#if os(macOS)
/// Small lock-backed container for shared mutable state.
final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initial: State) {
        state = initial
    }

    @discardableResult
    func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    @discardableResult
    func read<T>(_ body: (State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(state)
    }
}
#endif
