//
//  OverlayControlSessionRaceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

@testable import MirageKitClient
import Foundation
import Loom
import Testing

@Suite("Overlay Control Session Race")
struct OverlayControlSessionRaceTests {
    @Test("Overlay remote route budgets allow slow handshakes")
    func overlayRemoteRouteBudgetsAllowSlowHandshakes() {
        #expect(OverlayControlSessionRacePolicy.udpPrimaryDelay == .milliseconds(0))
        #expect(OverlayControlSessionRacePolicy.quicHedgeDelay == .seconds(3))
        #expect(OverlayControlSessionRacePolicy.groupBudget == .seconds(45))
        #expect(OverlayControlSessionRacePolicy.preRemoteHelloIdleTimeout == .seconds(12))
    }

    @Test("UDP overlay candidate launches before QUIC")
    func udpOverlayCandidateLaunchesBeforeQUIC() async {
        let state = OverlayControlSessionRaceState()
        let now = ContinuousClock.now

        #expect(await state.launchDecision(
            for: .udp,
            now: now,
            earliestLaunch: now
        ) == .launch)
        #expect(await state.launchDecision(
            for: .quic,
            now: now,
            earliestLaunch: now + OverlayControlSessionRacePolicy.quicHedgeDelay
        ) != .launch)
    }

    @Test("QUIC hedge is suppressed once UDP reaches remote hello")
    func quicHedgeSuppressesWhenUDPReachesRemoteHello() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.udp)
        await state.recordProgress(
            LoomAuthenticatedSessionBootstrapProgress(phase: .remoteHelloReceived),
            transportKind: .udp
        )

        #expect(await state.launchDecision(
            for: .quic,
            now: ContinuousClock.now,
            earliestLaunch: ContinuousClock.now
        ) != .launch)
    }

    @Test("UDP hedge is suppressed once QUIC reaches remote hello")
    func udpHedgeSuppressesWhenQUICReachesRemoteHello() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.quic)
        await state.recordProgress(
            LoomAuthenticatedSessionBootstrapProgress(phase: .remoteHelloReceived),
            transportKind: .quic
        )

        #expect(!(await state.shouldLaunch(.udp)))
    }

    @Test("TCP hedge launches only while no overlay candidate has remote hello")
    func tcpHedgeLaunchesOnlyBeforeRemoteHello() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.quic)
        await state.recordLaunched(.udp)

        #expect(await state.shouldLaunch(.tcp))

        await state.recordProgress(
            LoomAuthenticatedSessionBootstrapProgress(phase: .remoteHelloReceived),
            transportKind: .udp
        )

        #expect(!(await state.shouldLaunch(.tcp)))
    }

    @Test("Pre-remote-hello progress waits for the lenient idle window")
    func preRemoteHelloProgressWaitsForLenientIdleWindow() async {
        let state = OverlayControlSessionRaceState()
        let base = ContinuousClock.now
        await state.recordLaunched(.quic, at: base)
        await state.recordProgress(
            LoomAuthenticatedSessionBootstrapProgress(phase: .localHelloSent),
            transportKind: .quic,
            at: base
        )

        let beforeDeadline = await state.launchDecision(
            for: .udp,
            now: base + .seconds(11),
            earliestLaunch: base
        )
        let afterDeadline = await state.launchDecision(
            for: .udp,
            now: base + .seconds(12),
            earliestLaunch: base
        )

        #expect(beforeDeadline != .launch)
        #expect(afterDeadline == .launch)
    }

    @MainActor
    @Test("Connection attempt cancellation clears every pending transport candidate")
    func connectionAttemptCancellationClearsEveryPendingTransportCandidate() {
        let service = MirageClientService(deviceName: "Test Device")
        let attemptID = UUID()
        let firstTask = Task<LoomAuthenticatedSession, Error> {
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        }
        let secondTask = Task<LoomAuthenticatedSession, Error> {
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        }

        service.registerPendingConnectTask(firstTask, attemptID: attemptID)
        service.registerPendingConnectTask(secondTask, attemptID: attemptID)

        #expect(service.pendingConnectTasksByAttemptID[attemptID]?.count == 2)

        service.cancelPendingConnectTask(attemptID: attemptID)

        #expect(service.pendingConnectTasksByAttemptID[attemptID] == nil)
        #expect(firstTask.isCancelled)
        #expect(secondTask.isCancelled)
    }
}
