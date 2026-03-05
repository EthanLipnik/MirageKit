//
//  HostAppListRequestDeferralPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Interactive workload deferral policy coverage for host app-list requests.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host App List Request Deferral Policy")
struct HostAppListRequestDeferralPolicyTests {
    @Test("Defers app-list processing when any interactive workload signal is active")
    func defersWhenAnyInteractiveSignalIsActive() {
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: true,
                hasDesktopStream: false,
                hasLoginDisplayStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: true,
                hasLoginDisplayStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
                hasLoginDisplayStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
                hasLoginDisplayStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
                hasLoginDisplayStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: true
            )
        )
    }

    @Test("Does not defer when workload is fully idle")
    func doesNotDeferWhenIdle() {
        #expect(
            !MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
                hasLoginDisplayStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
    }

    @Test("Deferral transition is deterministic for begin/stay/resume states")
    func deterministicDeferralTransitions() {
        #expect(
            MirageHostService.appListRequestDeferralTransition(
                wasDeferred: false,
                shouldDefer: false
            ) == .remainIdle
        )
        #expect(
            MirageHostService.appListRequestDeferralTransition(
                wasDeferred: false,
                shouldDefer: true
            ) == .beginDeferral
        )
        #expect(
            MirageHostService.appListRequestDeferralTransition(
                wasDeferred: true,
                shouldDefer: true
            ) == .remainDeferred
        )
        #expect(
            MirageHostService.appListRequestDeferralTransition(
                wasDeferred: true,
                shouldDefer: false
            ) == .resumeDeferred
        )
    }
}
#endif
