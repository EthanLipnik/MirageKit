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
    @Test("UDP hedge launches when QUIC has not reached remote hello")
    func udpHedgeLaunchesWhenQUICIsOnlyTransportStarting() async {
        let state = OverlayControlSessionRaceState()
        await state.recordLaunched(.quic)

        #expect(await state.shouldLaunch(.udp))
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

