//
//  MirageKitHostPublicImportSurfaceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import Foundation
import Loom
import MirageKitHost
import Testing
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire

@Suite("MirageKitHost Public Import Surface")
struct MirageKitHostPublicImportSurfaceTests {
    @Test("MirageKitHost and owner imports expose host value models")
    func mirageKitHostAndOwnerImportsExposeHostValueModels() {
        var settings = MirageStreamingSettings()
        settings.setAllowStreaming(false, for: "COM.EXAMPLE.Editor")

        #expect(settings.blockedApps == ["com.example.editor"])
        #expect(settings.encoderLowPowerModePreference == .auto)

        let clientID = UUID()
        let authenticatedPeer = MirageAuthenticatedPeerIdentity(
            deviceID: clientID,
            displayName: "Studio iPad",
            deviceType: .iPad,
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true
        )
        let trustEvaluation = MirageTrustEvaluationSnapshot(
            decision: .trusted,
            shouldShowAutoTrustNotice: true
        )
        let connectedClient = MirageConnectedClient(
            id: clientID,
            name: "Studio iPad",
            deviceType: .iPad,
            connectedAt: Date(timeIntervalSinceReferenceDate: 0),
            identityKeyID: "identity-key",
            authenticatedPeerIdentity: authenticatedPeer,
            trustEvaluation: trustEvaluation,
            autoTrustGranted: true
        )

        #expect(connectedClient.authenticatedPeerIdentity == authenticatedPeer)
        #expect(connectedClient.mirageDeviceType == .iPad)
        #expect(connectedClient.authenticatedPeerIdentity.deviceType == .iPad)
        #expect(connectedClient.trustEvaluation == trustEvaluation)
        #expect(connectedClient.trustEvaluation?.authorizesBusyHostTakeover == true)
        #expect(
            String(describing: (any MirageHostSoftwareUpdateIdentityController).self)
                .contains("MirageHostSoftwareUpdateIdentityController")
        )
    }

    @MainActor
    @Test("MirageHostDelegate exposes Mirage session availability callback")
    func mirageHostDelegateExposesMirageSessionAvailabilityCallback() {
        let spy = HostDelegateImportSpy()
        let delegate: any MirageHostDelegate = spy

        delegate.sessionAvailabilityDidChange(.credentialsAndUserIdentifierRequired)

        #expect(spy.availability == .credentialsAndUserIdentifierRequired)
    }
}

private final class HostDelegateImportSpy: MirageHostDelegate, @unchecked Sendable {
    var availability: MirageWire.MirageHostSessionAvailability?

    @MainActor
    func shouldAcceptConnection(
        from deviceInfo: LoomPeerDeviceInfo,
        origin: MirageHostConnectionOrigin,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        completion(true)
    }

    @MainActor
    func didConnectClient(_ client: MirageConnectedClient) {}

    @MainActor
    func didDisconnectClient(_ client: MirageConnectedClient) {}

    @MainActor
    func activeStreamsDidChange() {}

    @MainActor
    func didReceiveInputEvent(
        _ event: MirageInput.MirageInputEvent,
        forWindow window: MirageMedia.MirageWindow
    ) {}

    @MainActor
    func sessionStateDidChange(_ state: LoomSessionAvailability) {}

    @MainActor
    func sessionAvailabilityDidChange(_ availability: MirageWire.MirageHostSessionAvailability) {
        self.availability = availability
    }

    @MainActor
    func didDiscoverPeer(advertisement: LoomPeerAdvertisement) {}
}
