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
    @Test("Application-activation recovery skips stale streams without touching transport")
    func applicationActivationRecoverySkipsStaleStreams() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Altair")

        service.requestStreamRecovery(for: 99, trigger: .applicationActivation)

        #expect(service.controllersByStream.isEmpty)
        #expect(service.pendingApplicationActivationRecoveryStreamIDs.isEmpty)
    }

    @MainActor
    @Test("Application-activation recovery waits for active stream controller")
    func applicationActivationRecoveryWaitsForActiveStreamController() {
        let service = MirageClientService(deviceName: "Test Device")
        let streamID: StreamID = 99
        service.connectionState = .connected(host: "Altair")
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()

        service.requestStreamRecovery(for: streamID, trigger: .applicationActivation)

        #expect(service.pendingApplicationActivationRecoveryStreamIDs == Set([streamID]))
        #expect(service.controllersByStream.isEmpty)
    }
}
