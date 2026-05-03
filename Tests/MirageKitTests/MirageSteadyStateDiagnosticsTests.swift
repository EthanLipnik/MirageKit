//
//  MirageSteadyStateDiagnosticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage Steady-State Diagnostics")
struct MirageSteadyStateDiagnosticsTests {
    @Test("MIRAGE_LOG all does not enable steady-state stream diagnostics")
    func mirageLogAllDoesNotEnableSteadyStateDiagnostics() {
        #expect(!MirageSteadyStateDiagnostics.isEnabled(environment: ["MIRAGE_LOG": "all"]))
    }

    @Test("Explicit steady-state diagnostics flag enables fixed-cadence logs")
    func explicitSteadyStateDiagnosticsFlagEnablesLogs() {
        #expect(MirageSteadyStateDiagnostics.isEnabled(environment: ["MIRAGE_STEADY_STATE_DIAGNOSTICS": "1"]))
        #expect(MirageSteadyStateDiagnostics.isEnabled(environment: ["MIRAGE_STEADY_STATE_DIAGNOSTICS": "true"]))
        #expect(MirageSteadyStateDiagnostics.isEnabled(environment: ["MIRAGE_STEADY_STATE_DIAGNOSTICS": "on"]))
    }

    @Test("Streaming verbose diagnostics alias enables fixed-cadence logs")
    func streamingVerboseDiagnosticsAliasEnablesLogs() {
        #expect(MirageSteadyStateDiagnostics.isEnabled(environment: ["MIRAGE_STREAMING_VERBOSE_DIAGNOSTICS": "1"]))
    }
}
