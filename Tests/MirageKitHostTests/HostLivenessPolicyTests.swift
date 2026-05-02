//
//  HostLivenessPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Liveness Policy")
struct HostLivenessPolicyTests {
    @Test("Idle clients are pinged before disconnect threshold")
    func idleClientsArePingedBeforeDisconnectThreshold() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 12,
                mediaIdleSeconds: nil,
                hasActiveStreams: false,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8
            ) == .ping
        )
    }

    @Test("Active recent media defers disconnect")
    func activeRecentMediaDefersDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 21,
                mediaIdleSeconds: 2,
                hasActiveStreams: true,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8
            ) == .deferForActiveMedia
        )
    }

    @Test("Stale media does not defer disconnect")
    func staleMediaDoesNotDeferDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 21,
                mediaIdleSeconds: 9,
                hasActiveStreams: true,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8
            ) == .disconnect
        )
    }
}
#endif
