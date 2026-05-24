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
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 1,
            protocolMismatchClientVersion: 2
        )

        let info = service.protocolMismatchInfo(from: response)
        #expect(info?.reason == .protocolVersionMismatch)
        #expect(info?.hostProtocolVersion == 1)
        #expect(info?.clientProtocolVersion == 2)
    }

    @MainActor
    @Test("Protocol mismatch rejection maps to terminal connection rejection")
    func protocolMismatchRejectionMapsToTerminalConnectionRejection() {
        let service = MirageClientService()
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 3,
            protocolMismatchClientVersion: 4
        )

        let rejection = service.connectionRejection(from: response)

        #expect(rejection.reason == .protocolVersionMismatch)
        #expect(rejection.isTerminal)
        #expect(rejection.hostProtocolVersion == 3)
        #expect(rejection.clientProtocolVersion == 4)
        #expect(rejection.userFacingMessage == "Protocol mismatch (host 3, client 4).")
    }

    @Test("Malformed bootstrap rejection is terminal and user-facing")
    func malformedBootstrapRejectionIsTerminalAndUserFacing() {
        let rejection = MirageConnectionRejection(
            reason: .malformedBootstrap,
            hostName: "Host"
        )

        #expect(rejection.isTerminal)
        #expect(rejection.userFacingMessage == "Host: The host received an incompatible Mirage handshake. Update Mirage on both devices.")
    }

    @Test("Local network blocked rejection uses Proximity Connect wording")
    func localNetworkBlockedRejectionUsesProximityConnectWording() {
        let rejection = MirageConnectionRejection(
            reason: .localNetworkBlocked,
            hostName: "Host"
        )
        let message = rejection.userFacingMessage

        #expect(rejection.isTerminal)
        #expect(message.contains("Proximity Connect"))
        #expect(message.contains("Network settings"))
        #expect(!message.lowercased().contains("peer-to-peer"))
    }

    @MainActor
    @Test("Host update bootstrap rejection maps to update-in-progress message")
    func hostUpdateBootstrapRejectionMapsToUpdateInProgressMessage() {
        let service = MirageClientService()
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: .hostUpdateInProgress
        )

        #expect(service.connectionRejection(from: response).reason == .hostUpdateInProgress)
        #expect(
            service.bootstrapRejectionDescription(for: response, mismatchInfo: nil) ==
                "Host update is in progress."
        )
    }

    @MainActor
    @Test("Compatibility update bootstrap can use advertised host protocol")
    func compatibilityUpdateBootstrapCanUseAdvertisedHostProtocol() {
        let service = MirageClientService()
        let request = service.makeBootstrapRequest(protocolVersionOverride: 7)
        let defaultRequest = service.makeBootstrapRequest()

        #expect(request.protocolVersion == 7)
        #expect(defaultRequest.protocolVersion == Int(MirageKit.protocolVersion))
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
            automationMode: .metadataOnly,
            installDisposition: .updateAvailable,
            lastBlockReason: nil,
            lastInstallResultCode: .noUpdateAvailable,
            canCancelUpdate: true,
            downloadExpectedBytes: 2000,
            downloadReceivedBytes: 1000,
            extractionProgress: 0.5,
            lastErrorSummary: "Previous check failed.",
            lastErrorDetails: "Network timeout.",
            currentVersion: "1.0.0",
            availableVersion: "1.1.0",
            availableVersionTitle: "Mirage 1.1",
            releaseNotesSummary: "Stability updates",
            releaseNotesBody: "Fixed regressions.",
            releaseNotesFormat: .plainText,
            lastCheckedAtMs: 1_700_000_000_000
        )
        let envelope = try ControlMessage(type: .hostSoftwareUpdateStatus, content: message)

        service.handleHostSoftwareUpdateStatus(envelope)

        #expect(receivedStatus?.isSparkleAvailable == true)
        #expect(receivedStatus?.isCheckingForUpdates == false)
        #expect(receivedStatus?.isInstallInProgress == true)
        #expect(receivedStatus?.channel == .nightly)
        #expect(receivedStatus?.automationMode == .metadataOnly)
        #expect(receivedStatus?.installDisposition == .updateAvailable)
        #expect(receivedStatus?.canCancelUpdate == true)
        #expect(receivedStatus?.downloadExpectedBytes == 2000)
        #expect(receivedStatus?.downloadReceivedBytes == 1000)
        #expect(receivedStatus?.extractionProgress == 0.5)
        #expect(receivedStatus?.lastErrorSummary == "Previous check failed.")
        #expect(receivedStatus?.lastErrorDetails == "Network timeout.")
        #expect(receivedStatus?.currentVersion == "1.0.0")
        #expect(receivedStatus?.availableVersion == "1.1.0")
        #expect(receivedStatus?.releaseNotesFormat == .plainText)
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
            automationMode: .autoInstall,
            installDisposition: .installing,
            lastBlockReason: nil,
            lastInstallResultCode: .started,
            canCancelUpdate: false,
            downloadExpectedBytes: 4096,
            downloadReceivedBytes: 4096,
            extractionProgress: nil,
            lastErrorSummary: nil,
            lastErrorDetails: nil,
            currentVersion: "1.0.0",
            availableVersion: "1.1.0",
            availableVersionTitle: "Mirage 1.1",
            releaseNotesSummary: "Important fixes",
            releaseNotesBody: "Fixes and tuning.",
            releaseNotesFormat: .plainText,
            lastCheckedAtMs: 1_700_000_000_000
        )
        let resultMessage = HostSoftwareUpdateInstallResultMessage(
            message: "Install started.",
            resultCode: .started,
            blockReason: nil,
            remediationHint: nil,
            status: status
        )
        let envelope = try ControlMessage(type: .hostSoftwareUpdateInstallResult, content: resultMessage)

        service.handleHostSoftwareUpdateInstallResult(envelope)

        #expect(receivedResult?.accepted == true)
        #expect(receivedResult?.message == "Install started.")
        #expect(receivedResult?.resultCode == .started)
        #expect(receivedResult?.status.isInstallInProgress == true)
        #expect(receivedResult?.status.channel == .release)
        #expect(receivedResult?.status.installDisposition == .installing)
        #expect(receivedResult?.status.downloadReceivedBytes == 4096)
    }

    @MainActor
    @Test("Host restart-result message updates client callback state")
    func hostRestartResultCallbackReceivesMappedPayload() throws {
        let service = MirageClientService()
        var receivedResult: MirageClientService.HostApplicationRestartResult?
        service.onHostApplicationRestartResult = { result in
            receivedResult = result
        }

        let resultMessage = HostApplicationRestartResultMessage(
            accepted: true,
            message: "Restarting Mirage Host."
        )
        let envelope = try ControlMessage(type: .hostApplicationRestartResult, content: resultMessage)

        service.handleHostApplicationRestartResult(envelope)

        #expect(receivedResult?.accepted == true)
        #expect(receivedResult?.message == "Restarting Mirage Host.")
    }
}
