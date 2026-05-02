//
//  HostDisconnectSessionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Disconnect Session Policy")
struct HostDisconnectSessionPolicyTests {
    @Test("Missing expected session still proceeds with client cleanup")
    func missingExpectedSessionStillProceedsWithClientCleanup() {
        #expect(
            MirageHostService.shouldIgnoreDisconnectForExpectedSession(
                resolvedClientID: nil,
                requestedClientID: UUID()
            ) == false
        )
    }

    @Test("Different active expected session is ignored")
    func differentActiveExpectedSessionIsIgnored() {
        #expect(
            MirageHostService.shouldIgnoreDisconnectForExpectedSession(
                resolvedClientID: UUID(),
                requestedClientID: UUID()
            )
        )
    }

    @Test("Matching expected session proceeds")
    func matchingExpectedSessionProceeds() {
        let clientID = UUID()

        #expect(
            MirageHostService.shouldIgnoreDisconnectForExpectedSession(
                resolvedClientID: clientID,
                requestedClientID: clientID
            ) == false
        )
    }
}
#endif
