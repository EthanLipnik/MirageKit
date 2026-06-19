//
//  ClientFailedConnectCleanupTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Client Failed Connect Cleanup")
struct ClientFailedConnectCleanupTests {
    @MainActor
    @Test("Current failed connect attempt requires disconnect cleanup")
    func currentFailedConnectRequiresCleanup() {
        let service = MirageClientService(deviceName: "Test Device")
        let attemptID = service.beginConnectAttempt()
        service.connectionState = .connecting

        #expect(
            service.shouldRunDisconnectCleanupAfterFailedConnect(
                attemptID: attemptID,
                isCancelledFailure: false
            )
        )
    }

    @MainActor
    @Test("Cancelled stale connect attempt cleans up when no newer attempt exists")
    func staleCancelledConnectCleansUpWhenNoNewerAttemptExists() {
        let service = MirageClientService(deviceName: "Test Device")
        let attemptID = service.beginConnectAttempt()
        service.finishConnectAttempt(attemptID)
        service.connectionState = .connecting

        #expect(
            service.shouldRunDisconnectCleanupAfterFailedConnect(
                attemptID: attemptID,
                isCancelledFailure: true
            )
        )
    }

    @MainActor
    @Test("Cancelled stale connect attempt preserves newer attempt")
    func staleCancelledConnectPreservesNewerAttempt() {
        let service = MirageClientService(deviceName: "Test Device")
        let staleAttemptID = service.beginConnectAttempt()
        _ = service.beginConnectAttempt()
        service.connectionState = .connecting

        #expect(
            !service.shouldRunDisconnectCleanupAfterFailedConnect(
                attemptID: staleAttemptID,
                isCancelledFailure: true
            )
        )
    }

    @MainActor
    @Test("Disconnected service without session skips failed connect cleanup")
    func disconnectedWithoutSessionSkipsCleanup() {
        let service = MirageClientService(deviceName: "Test Device")
        let attemptID = service.beginConnectAttempt()
        service.connectionState = .disconnected

        #expect(
            !service.shouldRunDisconnectCleanupAfterFailedConnect(
                attemptID: attemptID,
                isCancelledFailure: false
            )
        )
    }
}
