//
//  HostClientLivenessTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

#if os(macOS)
import Foundation
@testable import MirageKitHost
import Testing

@Suite("Host Client Liveness")
struct HostClientLivenessTests {
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

    @Test("Audio media activity defers disconnect")
    func audioMediaActivityDefersDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 21,
                mediaIdleSeconds: 1,
                hasActiveStreams: true,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8
            ) == .deferForActiveMedia
        )
    }

    @Test("Active background lease defers disconnect")
    func activeBackgroundLeaseDefersDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 25,
                mediaIdleSeconds: nil,
                hasActiveStreams: false,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8,
                hasActiveBackgroundLease: true
            ) == .deferForBackgroundLease
        )
    }

    @Test("Timed background lease clamp allows two minutes")
    func timedBackgroundLeaseClampAllowsTwoMinutes() {
        #expect(MirageHostService.clampedBackgroundLeaseDuration(120) == 120)
        #expect(MirageHostService.clampedBackgroundLeaseDuration(300) == 120)
    }

    @Test("Suspended background lease requires active stream state")
    func suspendedBackgroundLeaseRequiresActiveStreamState() {
        let now = Date(timeIntervalSinceReferenceDate: 100)

        #expect(
            hostHasActiveBackgroundLease(
                timedExpiration: now.addingTimeInterval(1),
                hasSuspendedLease: true,
                hasActiveStreams: true,
                now: now
            )
        )
        #expect(
            !hostHasActiveBackgroundLease(
                timedExpiration: now.addingTimeInterval(1),
                hasSuspendedLease: true,
                hasActiveStreams: false,
                now: now
            )
        )
        #expect(
            !hostHasActiveBackgroundLease(
                timedExpiration: now.addingTimeInterval(-1),
                hasSuspendedLease: true,
                hasActiveStreams: true,
                now: now
            )
        )
        #expect(
            !hostHasActiveBackgroundLease(
                timedExpiration: nil,
                hasSuspendedLease: true,
                hasActiveStreams: true,
                now: now
            )
        )
    }

    @Test("Timed background lease defers only before expiration")
    func timedBackgroundLeaseDefersOnlyBeforeExpiration() {
        let now = Date(timeIntervalSinceReferenceDate: 100)

        #expect(
            hostHasActiveBackgroundLease(
                timedExpiration: now.addingTimeInterval(1),
                hasSuspendedLease: false,
                hasActiveStreams: false,
                now: now
            )
        )
        #expect(
            !hostHasActiveBackgroundLease(
                timedExpiration: now.addingTimeInterval(-1),
                hasSuspendedLease: false,
                hasActiveStreams: true,
                now: now
            )
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

    @Test("Active recent control work defers disconnect")
    func activeRecentControlWorkDefersDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 21,
                mediaIdleSeconds: nil,
                hasActiveStreams: false,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8,
                controlWorkIdleSeconds: 2,
                hasActiveControlWork: true,
                activeControlWorkGraceThreshold: 8
            ) == .deferForActiveControlWork
        )
    }

    @Test("Stale control work does not defer disconnect")
    func staleControlWorkDoesNotDeferDisconnect() {
        #expect(
            hostClientLivenessDecision(
                controlIdleSeconds: 21,
                mediaIdleSeconds: nil,
                hasActiveStreams: false,
                pingThreshold: 10,
                disconnectThreshold: 20,
                activeMediaGraceThreshold: 8,
                controlWorkIdleSeconds: 9,
                hasActiveControlWork: true,
                activeControlWorkGraceThreshold: 8
            ) == .disconnect
        )
    }
}
#endif
