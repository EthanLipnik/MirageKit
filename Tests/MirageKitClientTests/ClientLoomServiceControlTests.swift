//
//  ClientLoomServiceControlTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing
import MirageConnectivity
import MirageWire

#if os(macOS)
extension ClientLoomControlPlaneTests {
    @MainActor
    @Test("Client control send helpers write onto the Loom control stream")
    func clientControlSendHelpersUseLoomControlChannel() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)
        do {
            let service = MirageClientService(deviceName: "Loopback Client")
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Loopback Host")

            let request = MirageWire.AppListRequestMessage(
                forceRefresh: true,
                forceIconReset: true,
                priorityBundleIdentifiers: ["com.apple.Terminal"],
                requestID: UUID()
            )
            try await service.sendControlMessage(.appListRequest, content: request)

            let receivedRequestEnvelope = try await serverReceiver.next()
            #expect(receivedRequestEnvelope.type == .appListRequest)
            let receivedRequest = try receivedRequestEnvelope.decode(MirageWire.AppListRequestMessage.self)
            #expect(receivedRequest.forceRefresh == true)
            #expect(receivedRequest.forceIconReset == true)
            #expect(receivedRequest.priorityBundleIdentifiers == ["com.apple.terminal"])

            #expect(service.sendControlMessageBestEffort(MirageWire.ControlMessage(type: .ping)) == true)
            let receivedPing = try await serverReceiver.next()
            #expect(receivedPing.type == .ping)

            let refreshedPathKind = await service.refreshCurrentControlPathKind()
            #expect(refreshedPathKind != nil)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Client disconnect sends user-requested notice before cleanup")
    func clientDisconnectSendsUserRequestedNoticeBeforeCleanup() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        do {
            let service = MirageClientService(deviceName: "Loopback Client")
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Loopback Host")

            await service.disconnect()

            let disconnect = try await nextDisconnectMessage(from: serverReceiver)
            #expect(disconnect.reason == .userRequested)
            #expect(service.connectionState == .disconnected)
            #expect(service.controlChannel == nil)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Bootstrap rejection is delivered before the control stream closes")
    func bootstrapRejectionIsDeliveredBeforeControlStreamCloses() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let service = MirageClientService(deviceName: "Loopback Client")

        do {
            let rejection = MirageWire.MirageSessionBootstrapResponse(
                accepted: false,
                hostID: UUID(),
                hostName: "Loopback Host",
                mediaEncryptionEnabled: false,
                datagramRegistrationToken: Data(),
                rejectionReason: .hostBusy
            )
            try await serverControl.send(.sessionBootstrapResponse, content: rejection)
            try await serverControl.closeStream()

            let responseEnvelope = try await service.receiveSingleControlMessage(
                from: clientControl.incomingBytes,
                timeout: .seconds(1),
                timeoutMessage: "Timed out waiting for host bootstrap response from Loopback Host"
            )
            #expect(responseEnvelope.type == .sessionBootstrapResponse)
            let response = try responseEnvelope.decode(MirageWire.MirageSessionBootstrapResponse.self)
            #expect(response.accepted == false)
            #expect(response.rejectionReason == .hostBusy)
            #expect(await pair.client.state == .ready)
            #expect(await pair.server.state == .ready)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }
}
#endif
