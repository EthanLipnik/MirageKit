//
//  ClientSoftwareUpdateHandlingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Coverage for client-side protocol mismatch and software update message handling.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Client Software Update Handling")
struct ClientSoftwareUpdateHandlingTests {
    @MainActor
    @Test("Protocol mismatch rejection maps to deterministic mismatch info")
    func protocolMismatchRejectionMapsToMismatchInfo() {
        let service = MirageClientService()
        let response = HelloResponseMessage(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            requiresAuth: false,
            dataPort: 9848,
            negotiation: MirageProtocolNegotiation.clientHello(
                protocolVersion: Int(MirageKit.protocolVersion),
                supportedFeatures: mirageSupportedFeatures
            ),
            requestNonce: "req-nonce",
            mediaEncryptionEnabled: false,
            udpRegistrationToken: Data(),
            identity: MirageIdentityEnvelope(
                keyID: "host-key",
                publicKey: Data([0x01, 0x02]),
                timestampMs: 987_654_321,
                nonce: "host-nonce",
                signature: Data([0x03, 0x04])
            ),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 1,
            protocolMismatchClientVersion: 2,
            protocolMismatchUpdateTriggerAccepted: false,
            protocolMismatchUpdateTriggerMessage: "Denied"
        )

        let info = service.protocolMismatchInfo(from: response)
        #expect(info?.reason == .protocolVersionMismatch)
        #expect(info?.hostProtocolVersion == 1)
        #expect(info?.clientProtocolVersion == 2)
        #expect(info?.hostUpdateTriggerAccepted == false)
        #expect(info?.hostUpdateTriggerMessage == "Denied")
    }

    @MainActor
    @Test("Host software update status message updates client callback state")
    func hostSoftwareUpdateStatusCallbackReceivesMappedPayload() throws {
        let service = MirageClientService()
        var receivedStatus: MirageClientService.HostSoftwareUpdateStatus?
        service.onHostSoftwareUpdateStatus = { status in
            receivedStatus = status
        }

        let message = HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: true,
            channel: .nightly,
            currentVersion: "1.0.0",
            availableVersion: "1.1.0",
            availableVersionTitle: "Mirage 1.1",
            lastCheckedAtMs: 1_700_000_000_000
        )
        let envelope = try ControlMessage(type: .hostSoftwareUpdateStatus, content: message)

        service.handleHostSoftwareUpdateStatus(envelope)

        #expect(receivedStatus?.isSparkleAvailable == true)
        #expect(receivedStatus?.isCheckingForUpdates == false)
        #expect(receivedStatus?.isInstallInProgress == true)
        #expect(receivedStatus?.channel == .nightly)
        #expect(receivedStatus?.currentVersion == "1.0.0")
        #expect(receivedStatus?.availableVersion == "1.1.0")
    }

    @MainActor
    @Test("Host install-result message updates client callback state")
    func hostInstallResultCallbackReceivesMappedPayload() throws {
        let service = MirageClientService()
        var receivedResult: MirageClientService.HostSoftwareUpdateInstallResult?
        service.onHostSoftwareUpdateInstallResult = { result in
            receivedResult = result
        }

        let status = HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: true,
            isInstallInProgress: true,
            channel: .release,
            currentVersion: "1.0.0",
            availableVersion: "1.1.0",
            availableVersionTitle: "Mirage 1.1",
            lastCheckedAtMs: 1_700_000_000_000
        )
        let resultMessage = HostSoftwareUpdateInstallResultMessage(
            accepted: true,
            message: "Install started.",
            status: status
        )
        let envelope = try ControlMessage(type: .hostSoftwareUpdateInstallResult, content: resultMessage)

        service.handleHostSoftwareUpdateInstallResult(envelope)

        #expect(receivedResult?.accepted == true)
        #expect(receivedResult?.message == "Install started.")
        #expect(receivedResult?.status?.isInstallInProgress == true)
        #expect(receivedResult?.status?.channel == .release)
    }
}
