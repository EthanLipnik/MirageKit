//
//  BootstrapDaemonStateMachineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//
//  Coverage for bootstrap daemon lifecycle state transitions.
//

import MirageHostBootstrapRuntime
import Testing

@Suite("Bootstrap Daemon State Machine")
struct BootstrapDaemonStateMachineTests {
    @Test("Valid lifecycle transitions")
    func validLifecycleTransitions() throws {
        var machine = MirageHostBootstrapDaemonStateMachine()
        #expect(machine.state == .idle)

        try machine.markListening()
        #expect(machine.state == .listening)

        try machine.markActive()
        #expect(machine.state == .active)
    }

    @Test("Invalid transition from idle to active is rejected")
    func invalidIdleToActiveTransition() {
        var machine = MirageHostBootstrapDaemonStateMachine()
        do {
            try machine.markActive()
            Issue.record("Expected invalid transition failure.")
        } catch let error as MirageHostBootstrapDaemonStateMachineError {
            switch error {
            case let .invalidTransition(from, to):
                #expect(from == .idle)
                #expect(to == .active)
            }
        } catch {
            Issue.record("Unexpected error type: \(error.localizedDescription)")
        }
    }
}
