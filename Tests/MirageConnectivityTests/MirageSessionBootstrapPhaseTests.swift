//
//  MirageSessionBootstrapPhaseTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
@testable import MirageConnectivity
import Testing

@Suite("Mirage Session Bootstrap Phase")
struct MirageSessionBootstrapPhaseTests {
    @Test("Loom bootstrap phases project into Mirage connectivity phases")
    func loomBootstrapPhasesProjectIntoMirageConnectivityPhases() {
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .idle) == .idle)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .transportStarting) == .transportStarting)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .transportReady) == .transportReady)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .localHelloSent) == .localHelloSent)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .remoteHelloReceived) == .remoteHelloReceived)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .trustPendingApproval) == .trustPendingApproval)
        #expect(MirageConnectivityLoomAdapter.sessionBootstrapPhase(from: .ready) == .ready)
    }

    @Test("Loom bootstrap progress projects phase and failure reason")
    func loomBootstrapProgressProjectsPhaseAndFailureReason() {
        let progress = LoomAuthenticatedSessionBootstrapProgress(
            phase: .localHelloSent,
            failureReason: "handshake-aborted"
        )

        let projected = MirageConnectivityLoomAdapter.sessionBootstrapProgress(from: progress)

        #expect(projected.phase == .localHelloSent)
        #expect(projected.failureReason == "handshake-aborted")
        #expect(projected.isFailure)
    }

    @Test("Loom transport kinds project into Mirage transport kinds")
    func loomTransportKindsProjectIntoMirageTransportKinds() {
        #expect(MirageConnectivityLoomAdapter.transportKind(from: .tcp) == .tcp)
        #expect(MirageConnectivityLoomAdapter.transportKind(from: .quic) == .quic)
        #expect(MirageConnectivityLoomAdapter.transportKind(from: .udp) == .udp)
    }
}
