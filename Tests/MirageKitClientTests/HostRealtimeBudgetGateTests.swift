//
//  HostRealtimeBudgetGateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing
import MirageDiagnostics

#if os(macOS)
@Suite("Host Realtime Budget Gate")
struct HostRealtimeBudgetGateTests {
    @Test("Idle observing state with a startup ceiling is not active throttling")
    func observingWithStartupCeilingIsNotActive() {
        // The host reports a non-nil bitrate ceiling and an "observing" pressure
        // state from stream init onward. That must NOT be treated as the host
        // actively throttling, otherwise the client permanently delegates and
        // never probes the bitrate upward.
        let snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            hostRealtimeBitrateCeiling: 32_000_000,
            hostRealtimePressureState: "observing"
        )
        #expect(snapshot.hostRealtimeBudgetIsActivelyThrottling == false)
    }

    @Test("Missing host pressure state is not active throttling")
    func nilStateIsNotActive() {
        let snapshot = MirageDiagnostics.MirageClientMetricsSnapshot()
        #expect(snapshot.hostRealtimeBudgetIsActivelyThrottling == false)
    }

    @Test("Active host pressure states count as throttling")
    func activeStatesAreThrottling() {
        for state in ["pressured", "severe", "recovery"] {
            let snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
                hostRealtimeBitrateCeiling: 16_000_000,
                hostRealtimePressureState: state
            )
            #expect(
                snapshot.hostRealtimeBudgetIsActivelyThrottling == true,
                "\(state) should be treated as active host throttling"
            )
        }
    }

    @Test("Realtime adaptation ownership follows host capability revisions")
    func realtimeAdaptationOwnershipFollowsCapabilityRevisions() {
        #expect(MirageDiagnostics.MirageClientMetricsSnapshot().hostOwnsRealtimeAdaptation == false)
        #expect(MirageDiagnostics.MirageClientMetricsSnapshot(hostRealtimeControlRevision: 0).hostOwnsRealtimeAdaptation == false)
        #expect(MirageDiagnostics.MirageClientMetricsSnapshot(hostRealtimeControlRevision: 1).hostOwnsRealtimeAdaptation)
        #expect(MirageDiagnostics.MirageClientMetricsSnapshot(hostAdaptiveGovernorRevision: 2).hostOwnsRealtimeAdaptation)
    }
}

@Suite("Host Production Cadence Gate")
struct HostProductionCadenceGateTests {
    @Test("Host producing at target is at cadence")
    func producingAtTargetIsAtCadence() {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(hostTargetFrameRate: 60)
        snapshot.hostEncodedFPS = 60
        #expect(snapshot.hostIsProducingAtCadence == true)
    }

    @Test("Low host production (static content) is not at cadence")
    func lowProductionIsNotAtCadence() {
        // SCK delivered ~20fps because the screen was mostly static — the gaps
        // this produces must not be read as a network ingress burst.
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(hostTargetFrameRate: 60)
        snapshot.hostEncodedFPS = 20
        snapshot.hostEncodeAttemptFPS = 20
        snapshot.hostCaptureFPS = 20
        #expect(snapshot.hostIsProducingAtCadence == false)
    }

    @Test("Capture FPS without encoded output is not production cadence")
    func captureFPSWithoutEncodedOutputIsNotProductionCadence() {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(hostTargetFrameRate: 60)
        snapshot.hostEncodedFPS = 0
        snapshot.hostCaptureFPS = 58
        snapshot.hostEncodeAttemptFPS = 58
        #expect(snapshot.hostIsProducingAtCadence == false)
    }
}
#endif
