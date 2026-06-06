//
//  MirageDiagnosticsLocked.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
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
