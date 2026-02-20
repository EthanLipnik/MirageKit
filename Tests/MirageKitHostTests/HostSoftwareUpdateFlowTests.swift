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
    @Test("Protocol mismatch metadata round-trips in hello rejection payload")
    func protocolMismatchMetadataRoundTrip() throws {
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
            protocolMismatchHostVersion: 7,
            protocolMismatchClientVersion: 8,
            protocolMismatchUpdateTriggerAccepted: true,
            protocolMismatchUpdateTriggerMessage: "Update request accepted."
        )
        let envelope = try ControlMessage(type: .helloResponse, content: response)
        let (decodedEnvelope, _) = try #require(ControlMessage.deserialize(from: envelope.serialize()))
        let decoded = try decodedEnvelope.decode(HelloResponseMessage.self)

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

        let deviceInfo = makeDeviceInfo()
        let mismatchHello = makeHelloMessage(requestHostUpdateOnProtocolMismatch: true)

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
            hello: mismatchHello,
            deviceInfo: deviceInfo
        )
        #expect(acceptedResult?.accepted == true)
        #expect(acceptedResult?.message == "Install started.")

        controller.authorizeResult = false
        let deniedResult = await host.handleProtocolMismatchUpdateRequestIfNeeded(
            hello: mismatchHello,
            deviceInfo: deviceInfo
        )
        #expect(deniedResult?.accepted == false)
        #expect(deniedResult?.message == "Remote update request denied for this device.")

        let noRequestHello = makeHelloMessage(requestHostUpdateOnProtocolMismatch: nil)
        let noRequestResult = await host.handleProtocolMismatchUpdateRequestIfNeeded(
            hello: noRequestHello,
            deviceInfo: deviceInfo
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
        #expect(result.message == "Remote update request denied for this device.")
        #expect(result.status?.currentVersion == controller.snapshot.currentVersion)
        #expect(result.resultCode == .denied)
        #expect(result.blockReason == .policyDenied)
    }

    @MainActor
    @Test("Status request maps host controller snapshot fields")
    func statusRequestMapsSnapshotFields() async {
        let host = MirageHostService()
        let controller = MockHostSoftwareUpdateController()
        host.softwareUpdateController = controller

        controller.snapshot = MirageHostSoftwareUpdateStatusSnapshot(
            isSparkleAvailable: true,
            isCheckingForUpdates: true,
            isInstallInProgress: true,
            channel: .nightly,
            automationMode: .autoDownload,
            installDisposition: .installing,
            lastBlockReason: nil,
            lastInstallResultCode: .started,
            currentVersion: "1.1.0",
            availableVersion: "1.2.0",
            availableVersionTitle: "Mirage 1.2",
            releaseNotesSummary: "Host release notes",
            releaseNotesBody: "<ul><li>Performance improvements</li></ul>",
            releaseNotesFormat: .html,
            lastCheckedAtMs: 1_700_000_000_000
        )

        let status = await host.resolveHostSoftwareUpdateStatus(
            for: makePeerIdentity(),
            forceRefresh: true
        )

        #expect(status.isSparkleAvailable == true)
        #expect(status.isCheckingForUpdates == true)
        #expect(status.isInstallInProgress == true)
        #expect(status.channel == .nightly)
        #expect(status.automationMode == .autoDownload)
        #expect(status.installDisposition == .installing)
        #expect(status.currentVersion == "1.1.0")
        #expect(status.availableVersion == "1.2.0")
        #expect(status.availableVersionTitle == "Mirage 1.2")
        #expect(status.releaseNotesFormat == .html)
        #expect(status.lastCheckedAtMs == 1_700_000_000_000)
        #expect(controller.lastStatusForceRefresh == true)
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
        softwareUpdateStatusFor _: MiragePeerIdentity,
        forceRefresh: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot {
        lastStatusForceRefresh = forceRefresh
        return snapshot
    }

    func hostService(
        _: MirageHostService,
        shouldAuthorizeSoftwareUpdateRequestFrom _: MiragePeerIdentity,
        trigger _: MirageHostSoftwareUpdateInstallTrigger
    ) async -> Bool {
        authorizeResult
    }

    func hostService(
        _: MirageHostService,
        performSoftwareUpdateInstallFor _: MiragePeerIdentity,
        trigger _: MirageHostSoftwareUpdateInstallTrigger
    ) async -> MirageHostSoftwareUpdateInstallResult {
        installResult
    }
}

private func makePeerIdentity() -> MiragePeerIdentity {
    MiragePeerIdentity(
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

private func makeDeviceInfo() -> MirageDeviceInfo {
    MirageDeviceInfo(
        id: UUID(),
        name: "Trusted iPad",
        deviceType: .iPad,
        endpoint: "127.0.0.1",
        iCloudUserID: "ck-user",
        identityKeyID: "peer-key",
        identityPublicKey: Data([0x01, 0x02]),
        isIdentityAuthenticated: true
    )
}

private func makeHelloMessage(requestHostUpdateOnProtocolMismatch: Bool?) -> HelloMessage {
    HelloMessage(
        deviceID: UUID(),
        deviceName: "Trusted iPad",
        deviceType: .iPad,
        protocolVersion: Int(MirageKit.protocolVersion),
        capabilities: MirageHostCapabilities(),
        negotiation: MirageProtocolNegotiation.clientHello(
            protocolVersion: Int(MirageKit.protocolVersion),
            supportedFeatures: mirageSupportedFeatures
        ),
        identity: MirageIdentityEnvelope(
            keyID: "peer-key",
            publicKey: Data([0x01, 0x02]),
            timestampMs: 123_456_789,
            nonce: "nonce",
            signature: Data([0x03, 0x04])
        ),
        requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
    )
}
#endif
