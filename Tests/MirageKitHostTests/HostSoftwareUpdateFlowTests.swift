//
//  HostSoftwareUpdateFlowTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Coverage for host-side software update control-flow handling.
//

@testable import MirageKit
@testable import MirageKitHost
import Loom
import MirageIdentity
import Foundation
import Testing

#if os(macOS)
@Suite("Host Software Update Flow")
struct HostSoftwareUpdateFlowTests {
    @MainActor
    @Test("Connected install request returns denied result for unauthorized peers")
    func connectedInstallRequestDeniedForUnauthorizedPeer() async {
        let host = MirageHostService()
        let controller = MockHostSoftwareUpdateController()
        host.softwareUpdateController = controller
        controller.installResult = MirageHostSoftwareUpdateInstallResult(
            accepted: false,
            message: "Approve this client on the host before requesting a remote update.",
            code: .denied,
            blockReason: .authorizationRequired,
            remediationHint: "Open Mirage Host on the Mac and approve or trust this client, then try again.",
            status: controller.snapshot
        )

        let result = await host.resolveHostSoftwareUpdateInstallResult(
            for: makePeerIdentity()
        )

        #expect(result.message == "Approve this client on the host before requesting a remote update.")
        #expect(result.status.currentVersion == controller.snapshot.currentVersion)
        #expect(result.resultCode == .denied)
        #expect(result.blockReason == .authorizationRequired)
        #expect(result.remediationHint == "Open Mirage Host on the Mac and approve or trust this client, then try again.")
    }

    @MainActor
    @Test("Install request prefers Mirage authenticated peer identity when controller supports it")
    func installRequestPrefersMirageAuthenticatedPeerIdentity() async {
        let host = MirageHostService()
        let controller = MockHostSoftwareUpdateIdentityController()
        host.softwareUpdateController = controller
        let peerIdentity = makePeerIdentity()

        let result = await host.resolveHostSoftwareUpdateInstallResult(
            for: peerIdentity
        )

        #expect(result.resultCode == .started)
        #expect(controller.receivedMiragePeer?.deviceID == peerIdentity.deviceID)
        #expect(controller.receivedMiragePeer?.displayName == peerIdentity.name)
        #expect(controller.receivedMiragePeer?.identityKeyID == peerIdentity.identityKeyID)
        #expect(controller.receivedLoomPeer == nil)
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

    func softwareUpdateStatus(
        forceRefresh _: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot {
        snapshot
    }

    func performSoftwareUpdateInstall(
        for _: LoomPeerIdentity
    ) async -> MirageHostSoftwareUpdateInstallResult {
        installResult
    }
}

@MainActor
private final class MockHostSoftwareUpdateIdentityController: MirageHostSoftwareUpdateIdentityController,
    @unchecked Sendable
{
    private(set) var receivedMiragePeer: MirageAuthenticatedPeerIdentity?
    private(set) var receivedLoomPeer: LoomPeerIdentity?

    func softwareUpdateStatus(
        forceRefresh _: Bool
    ) async -> MirageHostSoftwareUpdateStatusSnapshot {
        makeSoftwareUpdateStatusSnapshot()
    }

    func performSoftwareUpdateInstall(
        for peer: MirageAuthenticatedPeerIdentity
    ) async -> MirageHostSoftwareUpdateInstallResult {
        receivedMiragePeer = peer
        return MirageHostSoftwareUpdateInstallResult(
            accepted: true,
            message: "Install started.",
            code: .started,
            blockReason: nil,
            remediationHint: nil,
            status: makeSoftwareUpdateStatusSnapshot()
        )
    }

    func performSoftwareUpdateInstall(
        for peer: LoomPeerIdentity
    ) async -> MirageHostSoftwareUpdateInstallResult {
        receivedLoomPeer = peer
        return MirageHostSoftwareUpdateInstallResult(
            accepted: false,
            message: "Unexpected compatibility path.",
            code: .denied,
            blockReason: .policyDenied,
            remediationHint: nil,
            status: makeSoftwareUpdateStatusSnapshot()
        )
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

private func makeSoftwareUpdateStatusSnapshot() -> MirageHostSoftwareUpdateStatusSnapshot {
    MirageHostSoftwareUpdateStatusSnapshot(
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
}

#endif
