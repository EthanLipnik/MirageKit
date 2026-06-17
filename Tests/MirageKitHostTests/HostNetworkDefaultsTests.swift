//
//  HostNetworkDefaultsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Loom
import Testing

#if os(macOS)
@Suite("Host Network Defaults")
struct HostNetworkDefaultsTests {
    @MainActor
    @Test("Host default configuration uses MirageKit service type")
    func defaultConfigurationUsesMirageKitServiceType() {
        let service = MirageHostService(hostName: "Network Defaults Host")

        #expect(service.networkConfig.serviceType == MirageKit.serviceType)
        #expect(service.networkConfig.serviceType != MirageKit.mirageAppServiceType)
    }

    @MainActor
    @Test("Host preserves explicit Mirage app service type")
    func preservesExplicitMirageAppServiceType() {
        let configuration = LoomNetworkConfiguration(
            serviceType: MirageKit.mirageAppServiceType
        )

        let service = MirageHostService(
            hostName: "Mirage App Compatibility Host",
            loomConfiguration: configuration
        )

        #expect(service.networkConfig.serviceType == MirageKit.mirageAppServiceType)
    }
}
#endif
