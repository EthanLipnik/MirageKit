//
//  MirageDiagnosticsLocked.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import Foundation

package final class MirageDiagnosticsLocked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    package init(_ state: State) {
        self.state = state
    }

    package func withLock<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
