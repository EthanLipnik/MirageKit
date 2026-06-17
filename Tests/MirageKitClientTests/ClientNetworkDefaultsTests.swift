//
//  ClientNetworkDefaultsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Loom
import Testing

@Suite("Client Network Defaults")
struct ClientNetworkDefaultsTests {
    @MainActor
    @Test("Client default configuration uses MirageKit service type")
    func defaultConfigurationUsesMirageKitServiceType() {
        let service = MirageClientService(deviceName: "Network Defaults Client")

        #expect(service.networkConfig.serviceType == MirageKit.serviceType)
        #expect(service.networkConfig.serviceType != MirageKit.mirageAppServiceType)
    }

    @MainActor
    @Test("Client preserves explicit Mirage app service type")
    func preservesExplicitMirageAppServiceType() {
        let configuration = LoomNetworkConfiguration(
            serviceType: MirageKit.mirageAppServiceType
        )

        let service = MirageClientService(
            deviceName: "Mirage App Compatibility Client",
            loomConfiguration: configuration
        )

        #expect(service.networkConfig.serviceType == MirageKit.mirageAppServiceType)
    }
}
