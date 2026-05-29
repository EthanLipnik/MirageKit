//
//  ControlPathStatusTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Control Path Status")
struct ControlPathStatusTests {
    @MainActor
    @Test("Control path update publishes stored status and history")
    func controlPathUpdatePublishesStoredStatusAndHistory() throws {
        let service = MirageClientService(deviceName: "Control Path Test")
        let snapshot = Self.snapshot(interfaceNames: ["en0"], usesWiFi: true)

        service.handleControlPathUpdate(snapshot)

        let status = try #require(service.currentControlPathStatus)
        #expect(service.currentControlPathKind == .wifi)
        #expect(status.kind == .wifi)
        #expect(status.interfaceNames == ["en0"])
        #expect(service.controlPathHistory.map(\.status) == [status])

        service.handleControlPathUpdate(snapshot)

        #expect(service.controlPathHistory.map(\.status) == [status])
    }

    @MainActor
    @Test("Clearing control path resets stored status and history")
    func clearingControlPathResetsStoredStatusAndHistory() {
        let service = MirageClientService(deviceName: "Control Path Clear Test")
        service.handleControlPathUpdate(Self.snapshot(interfaceNames: ["en0"], usesWiFi: true))

        service.clearControlPathState()

        #expect(service.currentControlPathKind == nil)
        #expect(service.currentControlPathStatus == nil)
        #expect(service.controlPathHistory.isEmpty)
    }

    @MainActor
    @Test("Stored status preserves USB-C proximity classification")
    func storedStatusPreservesUSBCProximityClassification() throws {
        let service = MirageClientService(deviceName: "Control Path Proximity Test")
        let snapshot = Self.snapshot(interfaceNames: ["anpi0"], usesOther: true)

        service.handleControlPathUpdate(snapshot)

        let status = try #require(service.currentControlPathStatus)
        #expect(service.currentControlPathKind == .awdl)
        #expect(status.usesUSBProximityInterface)
        #expect(status.usesProximityWiredLikePolicy)
    }

    private static func snapshot(
        interfaceNames: [String],
        usesWiFi: Bool = false,
        usesWired: Bool = false,
        usesCellular: Bool = false,
        usesLoopback: Bool = false,
        usesOther: Bool = false
    ) -> MirageNetworkPathSnapshot {
        MirageNetworkPathClassifier.classify(
            interfaceNames: interfaceNames,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
    }
}
