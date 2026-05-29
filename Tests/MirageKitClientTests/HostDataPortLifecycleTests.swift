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

    @Test("Application-activation recovery preserves the current presenter frame")
    func applicationActivationRecoveryPreservesCurrentPresenterFrame() {
        #expect(!MirageClientStreamRecoveryTrigger.applicationActivation.clearsExistingFramesImmediately)
        #expect(!MirageClientStreamRecoveryTrigger.applicationActivation.requestsPresentationRecoveryImmediately)
        #expect(MirageClientStreamRecoveryTrigger.manual.clearsExistingFramesImmediately)
        #expect(MirageClientStreamRecoveryTrigger.manual.requestsPresentationRecoveryImmediately)
    }

    @Test("Application-activation packet progress does not suppress hard recovery indefinitely")
    func applicationActivationPacketProgressExpiresAtHardRecoveryFloor() {
        #expect(MirageClientService.shouldContinueForegroundRecoveryForFreshPackets(
            packetProgressIsFresh: true,
            noProgressDuration: 7.99,
            hardRecoveryFloor: 8
        ))
        #expect(!MirageClientService.shouldContinueForegroundRecoveryForFreshPackets(
            packetProgressIsFresh: true,
            noProgressDuration: 8,
            hardRecoveryFloor: 8
        ))
        #expect(!MirageClientService.shouldContinueForegroundRecoveryForFreshPackets(
            packetProgressIsFresh: false,
            noProgressDuration: 1,
            hardRecoveryFloor: 8
        ))
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
