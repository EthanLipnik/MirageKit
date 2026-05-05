//
//  HostSoftwareUpdateFlowTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Coverage for host-side software update mismatch and control-flow handling.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Software Update Flow")
struct HostSoftwareUpdateFlowTests {
    @MainActor
    @Test("Protocol mismatch metadata round-trips in bootstrap rejection payload")
    func protocolMismatchMetadataRoundTrip() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            selectedFeatures: [],
            mediaEncryptionEnabled: false,
            udpRegistrationToken: Data(),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 7,
            protocolMismatchClientVersion: 8,
            protocolMismatchUpdateTriggerAccepted: true,
            protocolMismatchUpdateTriggerMessage: "Update request accepted."
        )
        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)

        #expect(!decoded.accepted)
        #expect(decoded.rejectionReason == .protocolVersionMismatch)
        #expect(decoded.protocolMismatchHostVersion == 7)
        #expect(decoded.protocolMismatchClientVersion == 8)
        #expect(decoded.protocolMismatchUpdateTriggerAccepted == true)
        #expect(decoded.protocolMismatchUpdateTriggerMessage == "Update request accepted.")
    }

    @MainActor
    @Test("Protocol mismatch update trigger acceptance is authorization-gated")
    func protocolMismatchUpdateTriggerIsAuthorizationGated() async {
        let host = MirageHostService()
        let controller = MockHostSoftwareUpdateController()
        host.softwareUpdateController = controller

        let peerIdentity = makePeerIdentity()
        let mismatchRequest = makeBootstrapRequest(requestHostUpdateOnProtocolMismatch: true)

        controller.authorizeResult = true
        controller.installResult = .init(
            accepted: true,
            message: "Install started.",
            code: .started,
            blockReason: nil,
            remediationHint: nil,
            status: controller.snapshot
        )

        let acceptedResult = await host.handleProtocolMismatchUpdateRequestIfNeeded(
            request: mismatchRequest,
            peerIdentity: peerIdentity
        )
        #expect(acceptedResult?.accepted == true)
        #expect(acceptedResult?.message == "Install started.")

        controller.authorizeResult = false
        let deniedResult = await host.handleProtocolMismatchUpdateRequestIfNeeded(
            request: mismatchRequest,
            peerIdentity: peerIdentity
        )
        #expect(deniedResult?.accepted == false)
        #expect(deniedResult?.message == "Remote update request denied for this device.")

        let noRequestRequest = makeBootstrapRequest(requestHostUpdateOnProtocolMismatch: nil)
        let noRequestResult = await host.handleProtocolMismatchUpdateRequestIfNeeded(
            request: noRequestRequest,
            peerIdentity: peerIdentity
        )
        #expect(noRequestResult == nil)
    }

    @MainActor
    @Test("Connected install request returns denied result for unauthorized peers")
    func connectedInstallRequestDeniedForUnauthorizedPeer() async {
        let host = MirageHostService()
        let controller = MockHostSoftwareUpdateController()
        host.softwareUpdateController = controller
        controller.authorizeResult = false

        let result = await host.resolveHostSoftwareUpdateInstallResult(
            for: makePeerIdentity(),
            trigger: .manual
        )

        #expect(result.accepted == false)
        #expect(result.message == "Approve this client on the host before requesting a remote update.")
        #expect(result.status?.currentVersion == controller.snapshot.currentVersion)
        #expect(result.resultCode == .denied)
        #expect(result.blockReason == .authorizationRequired)
        #expect(result.remediationHint == "Open Mirage Host on the Mac and approve or trust this client, then try again.")
    }

}

@MainActor
private final class MockHostSoftwareUpdateController: MirageHostSoftwareUpdateController, @unchecked Sendable {
    var snapshot = MirageHostSoftwareUpdateStatusSnapshot(
        isSparkleAvailable: true,
        isCheckingForUpdates: false,
        isInstallInProgress: false,
        channel: .release,
        automationMode: .metadataOnly,
        installDisposition: .idle,
        lastBlockReason: nil,
        lastInstallResultCode: nil,
        canCancelUpdate: false,
        downloadExpectedBytes: nil,
        downloadReceivedBytes: 0,
        extractionProgress: nil,
        lastErrorSummary: nil,
        lastErrorDetails: nil,
        currentVersion: "1.0.0",
        availableVersion: "1.1.0",
        availableVersionTitle: "Mirage 1.1",
        releaseNotesSummary: nil,
        releaseNotesBody: nil,
        releaseNotesFormat: nil,
        lastCheckedAtMs: 1_700_000_000_000
    )
    var installResult = MirageHostSoftwareUpdateInstallResult(
        accepted: true,
        message: "Install started.",
        code: .started,
        blockReason: nil,
        remediationHint: nil,
        status: MirageHostSoftwareUpdateStatusSnapshot(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: true,
            channel: .release,
            automationMode: .autoInstall,
            installDisposition: .installing,
            lastBlockReason: nil,
            lastInstallResultCode: .started,
            canCancelUpdate: false,
            downloadExpectedBytes: nil,
            downloadReceivedBytes: 0,
            extractionProgress: nil,
            lastErrorSummary: nil,
            lastErrorDetails: nil,
            currentVersion: "1.0.0",
            availableVersion: "1.1.0",
            availableVersionTitle: "Mirage 1.1",
            releaseNotesSummary: "Fixes",
            releaseNotesBody: "Critical bug fixes.",
            releaseNotesFormat: .plainText,
            lastCheckedAtMs: 1_700_000_000_000
        )
    )
    var authorizeResult = true
    var lastStatusForceRefresh: Bool?

    func hostService(
        _: MirageHostService,
        softwareUpdateStatusFor _: LoomPeerIdentity,
        forceRefresh: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot {
        lastStatusForceRefresh = forceRefresh
        return snapshot
    }

    func hostService(
        _: MirageHostService,
        shouldAuthorizeSoftwareUpdateRequestFrom _: LoomPeerIdentity,
        trigger _: MirageHostSoftwareUpdateInstallTrigger
    ) async -> Bool {
        authorizeResult
    }

    func hostService(
        _: MirageHostService,
        performSoftwareUpdateInstallFor _: LoomPeerIdentity,
        trigger _: MirageHostSoftwareUpdateInstallTrigger
    ) async -> MirageHostSoftwareUpdateInstallResult {
        installResult
    }
}

private func makePeerIdentity() -> LoomPeerIdentity {
    LoomPeerIdentity(
        deviceID: UUID(),
        name: "Trusted iPad",
        deviceType: .iPad,
        iCloudUserID: "ck-user",
        identityKeyID: "peer-key",
        identityPublicKey: Data([0x01, 0x02]),
        isIdentityAuthenticated: true,
        endpoint: "127.0.0.1"
    )
}

private func makeBootstrapRequest(requestHostUpdateOnProtocolMismatch: Bool?) -> MirageSessionBootstrapRequest {
    MirageSessionBootstrapRequest(
        protocolVersion: Int(MirageKit.protocolVersion),
        requestedFeatures: mirageSupportedFeatures,
        clientRequiresMediaEncryption: false,
        requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
    )
}
#endif
