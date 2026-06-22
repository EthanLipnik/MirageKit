//
//  OverlayControlSessionRaceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

@testable import MirageKitClient
import Foundation
import Loom
@testable import MirageConnectivity
import Testing

@Suite("Overlay Control Session Race")
struct OverlayControlSessionRaceTests {
    @Test("Overlay remote route budgets allow slow handshakes")
    func overlayRemoteRouteBudgetsAllowSlowHandshakes() {
        #expect(OverlayControlSessionRacePolicy.udpPrimaryDelay == .milliseconds(0))
        #expect(OverlayControlSessionRacePolicy.tcpHedgeDelay == .seconds(3))
        #expect(OverlayControlSessionRacePolicy.groupBudget == .seconds(45))
        #expect(OverlayControlSessionRacePolicy.preRemoteHelloIdleTimeout == .seconds(12))
    }

    @Test("UDP overlay candidate launches before TCP")
    func udpOverlayCandidateLaunchesBeforeTCP() async {
        let state = OverlayControlSessionRaceState()
        let now = ContinuousClock.now

        #expect(await state.launchDecision(
            for: .udp,
            now: now,
            earliestLaunch: now
        ) == .launch)
        #expect(await state.launchDecision(
            for: .tcp,
            now: now,
            earliestLaunch: now + OverlayControlSessionRacePolicy.tcpHedgeDelay
        ) != .launch)
    }

    @Test("Legacy QUIC overlay candidates are suppressed")
    func legacyQUICOverlayCandidatesAreSuppressed() async {
        let state = OverlayControlSessionRaceState()

        #expect(await state.launchDecision(
            for: .quic,
            now: ContinuousClock.now,
            earliestLaunch: ContinuousClock.now
        ) != .launch)
    }

    @Test("TCP hedge is suppressed once UDP reaches remote hello")
    func tcpHedgeSuppressesWhenUDPReachesRemoteHello() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.udp)
        await state.recordProgress(
            .remoteHelloReceived,
            transportKind: .udp
        )

        #expect(await state.launchDecision(
            for: .tcp,
            now: ContinuousClock.now,
            earliestLaunch: ContinuousClock.now
        ) != .launch)
    }

    @Test("UDP primary is not blocked by TCP pre-remote-hello progress")
    func udpPrimaryIsNotBlockedByTCPPreRemoteHelloProgress() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.tcp)
        await state.recordProgress(
            .localHelloSent,
            transportKind: .tcp
        )

        #expect(await state.shouldLaunch(.udp))
    }

    @Test("TCP hedge launches only while no overlay candidate has remote hello")
    func tcpHedgeLaunchesOnlyBeforeRemoteHello() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.udp)

        #expect(await state.shouldLaunch(.tcp))

        await state.recordProgress(
            .remoteHelloReceived,
            transportKind: .udp
        )

        #expect(!(await state.shouldLaunch(.tcp)))
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
