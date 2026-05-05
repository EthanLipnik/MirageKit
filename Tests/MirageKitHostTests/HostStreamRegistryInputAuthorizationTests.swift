//
//  HostStreamRegistryInputAuthorizationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import Testing

@Suite("Host Stream Registry Input Authorization")
struct HostStreamRegistryInputAuthorizationTests {
    @Test("Input clients fail closed when unregistered")
    func inputClientsFailClosedWhenUnregistered() {
        let registry = HostStreamRegistry()
        let sessionID = UUID()
        let clientID = UUID()

        #expect(!registry.isInputSessionActive(sessionID, clientID: clientID))

        registry.registerInputSession(sessionID, clientID: clientID)
        #expect(registry.isInputSessionActive(sessionID, clientID: clientID))

        registry.unregisterInputSession(sessionID)
        #expect(!registry.isInputSessionActive(sessionID, clientID: clientID))
    }

    @Test("Input session checks reject other sessions for the same client")
    func inputSessionChecksRejectOtherSessionsForSameClient() {
        let registry = HostStreamRegistry()
        let activeSessionID = UUID()
        let staleSessionID = UUID()
        let clientID = UUID()

        registry.registerInputSession(activeSessionID, clientID: clientID)

        #expect(registry.isInputSessionActive(activeSessionID, clientID: clientID))
        #expect(!registry.isInputSessionActive(staleSessionID, clientID: clientID))
    }
}
#endif
