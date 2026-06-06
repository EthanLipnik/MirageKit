//
//  MirageKitClientPublicImportSurfaceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import Loom
@_spi(Labs) import MirageKitClient
import Foundation
import Testing
import MirageDiagnostics
import MirageIdentity
import MirageWire

@Suite("MirageKitClient Public Import Surface")
struct MirageKitClientPublicImportSurfaceTests {
    @Test("MirageKitClient and owner imports expose client value models")
    func mirageKitClientAndOwnerImportsExposeClientValueModels() throws {
        let drops = MirageDiagnostics.MirageHostQueuedUnreliableDropCounts(
            deadlineExpired: 1,
            queueLimit: 2,
            superseded: 3,
            unsupportedTransport: 4,
            closed: 5
        )
        #expect(drops.total == 15)
        let snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(decodedFPS: 30, receivedFPS: 29)
        #expect(snapshot.decodedFPS == 30)

        let plan = MirageDiagnostics.MirageQualityTestPlan(stages: [])
        #expect(plan.stages.isEmpty)

        let hostID = try #require(UUID(uuidString: "70000000-0000-0000-0000-000000000002"))
        let identity = MirageIdentity.MirageConnectedHostIdentity(
            acceptedHostID: hostID,
            identityKeyID: "identity-key"
        )
        let authorizationState: MirageIdentity.MirageAuthorizationState = .awaitingManualApproval
        let attemptSummary = MirageDiagnostics.MirageClientControlSessionAttemptSummary(
            observedAt: Date(timeIntervalSince1970: 0),
            phase: "planned",
            hostName: "Studio",
            transport: "udp",
            endpoint: "192.168.1.20:4489",
            candidateKind: "direct",
            routeTier: "preferred",
            endpointSource: "advertisement",
            requiredInterface: "en0",
            proximity: "none",
            outcome: "order=1/1"
        )
        let foregroundHealth = MirageDiagnostics.MirageForegroundStreamHealthSnapshot(
            streamID: 42,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 1,
            submittedSequence: 2,
            isAwaitingKeyframe: false
        )
        let clientLabRegistry = MirageClientLabRegistry.standard()
        #expect(identity.uuidAliases == [hostID])
        #expect(authorizationState == MirageAuthorizationState.awaitingManualApproval)
        #expect(attemptSummary.supportSummaryLine.contains("phase=planned"))
        #expect(foregroundHealth.streamID == 42)
        #expect(!foregroundHealth.isAwaitingKeyframe)
        #expect(clientLabRegistry.descriptors.isEmpty)
    }

    @MainActor
    @Test("MirageClientDelegate exposes Mirage session availability callback")
    func mirageClientDelegateExposesMirageSessionAvailabilityCallback() {
        let spy = ClientDelegateImportSpy()
        let delegate: any MirageClientDelegate = spy

        delegate.hostSessionAvailabilityChanged(.credentialsRequired)

        #expect(spy.availability == .credentialsRequired)
    }
}

private final class ClientDelegateImportSpy: MirageClientDelegate, @unchecked Sendable {
    var availability: MirageWire.MirageHostSessionAvailability?

    @MainActor
    func didDisconnectFromHost(_ reason: String) {}

    @MainActor
    func didEncounterError(_ error: Error) {}

    @MainActor
    func hostSessionAvailabilityChanged(_ availability: MirageWire.MirageHostSessionAvailability) {
        self.availability = availability
    }

    @MainActor
    func hostSessionStateChanged(_ state: LoomSessionAvailability) {}
}
