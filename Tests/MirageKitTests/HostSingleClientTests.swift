//
//  HostSingleClientTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Single-client enforcement for host connections.
//

import Testing
@testable import MirageKit

#if os(macOS)
import Network

@Suite("Host Single-Client")
struct HostSingleClientTests {
    @Test("Single-client slot is exclusive")
    @MainActor
    func singleClientSlotIsExclusive() {
        let host = MirageHostService()

        let connectionA = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .tcp
        )
        let connectionB = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .tcp
        )

        let connectionIDA = ObjectIdentifier(connectionA)
        let connectionIDB = ObjectIdentifier(connectionB)

        #expect(host.reserveSingleClientSlot(for: connectionIDA))
        #expect(host.singleClientConnectionID == connectionIDA)
        #expect(!host.reserveSingleClientSlot(for: connectionIDB))

        host.releaseSingleClientSlot(for: connectionIDA)
        #expect(host.singleClientConnectionID == nil)
        #expect(host.reserveSingleClientSlot(for: connectionIDB))
    }
}
#endif
