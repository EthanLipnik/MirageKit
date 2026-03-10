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

        try machine.markUnlocking()
        #expect(machine.state == .unlocking)

        try machine.markListening()
        #expect(machine.state == .listening)

        try machine.markActive()
        #expect(machine.state == .active)

        try machine.markStopped()
        #expect(machine.state == .stopped)
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

    @Test("Stopped daemon can re-enter listening state")
    func stoppedCanRestartListening() throws {
        var machine = MirageHostBootstrapDaemonStateMachine(initialState: .stopped)
        try machine.markListening()
        #expect(machine.state == .listening)
    }
}
