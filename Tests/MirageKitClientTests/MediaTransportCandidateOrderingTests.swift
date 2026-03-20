//
//  MediaTransportCandidateOrderingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitClient
@testable import MirageKit
import Network
import Testing

#if os(macOS)
@Suite("Network Endpoint Utilities")
struct MediaTransportCandidateOrderingTests {
    @Test("Qualified Bonjour names are not duplicated with another local suffix")
    func qualifiedBonjourNamesAreNotDuplicated() {
        let hosts = MirageClientService.expandedBonjourHosts(for: NWEndpoint.Host("altair.local"))

        let hostStrings = hosts.map { String(describing: $0) }
        #expect(hostStrings.contains("altair.local"))
        #expect(!hostStrings.contains("altair.local.local"))
    }

    @Test("Short hostname gets .local suffix")
    func shortHostnameGetsLocalSuffix() {
        let hosts = MirageClientService.expandedBonjourHosts(for: NWEndpoint.Host("Altair"))
        let hostStrings = hosts.map { String(describing: $0) }
        #expect(hostStrings.contains("Altair.local"))
    }
}
#endif
