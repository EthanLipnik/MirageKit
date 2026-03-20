//
//  HostDataPortLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//

@testable import MirageKitClient
import Testing

@Suite("Media Stream Lifecycle")
struct HostDataPortLifecycleTests {
    @MainActor
    @Test("Stopping the media stream listener clears active media streams")
    func stopMediaStreamListenerClearsState() {
        let service = MirageClientService(deviceName: "Test Device")

        service.stopMediaStreamListener()

        #expect(service.activeMediaStreams.isEmpty)
        #expect(service.videoStreamReceiveTasks.isEmpty)
    }

    @MainActor
    @Test("Disconnect cleanup stops the media stream listener")
    func disconnectCleanupStopsMediaStreams() async {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Altair")

        await service.handleDisconnect(
            reason: "test",
            state: .disconnected,
            notifyDelegate: false
        )

        #expect(service.activeMediaStreams.isEmpty)
    }

    @MainActor
    @Test("Application-activation recovery skips stale streams without touching transport")
    func applicationActivationRecoverySkipsStaleStreams() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Altair")

        service.requestApplicationActivationRecovery(for: 99)
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.controllersByStream.isEmpty)
    }
}
