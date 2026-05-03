//
//  HostAppListRequestDeferralPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Interactive workload deferral policy coverage for host app-list requests.
//

@testable import MirageKitHost
import Foundation
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
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false
            )
        )
        #expect(
            MirageHostService.shouldDeferAppListRequestsForInteractiveWorkload(
                hasActiveAppStreams: false,
                hasDesktopStream: false,
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

    @MainActor
    @Test("Cancelling app-list work invalidates stale progress batches")
    func cancellationInvalidatesStaleProgressBatches() async {
        let service = MirageHostService(hostName: "Test Host", deviceID: UUID())
        let clientID = UUID()
        service.pendingAppListRequest = MirageHostService.PendingAppListRequest(
            clientID: clientID,
            requestID: UUID(),
            requestedForceRefresh: true,
            forceIconReset: false,
            priorityBundleIdentifiers: [],
            knownIconBundleIdentifiers: []
        )
        let originalToken = service.appListRequestToken
        service.appListRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
        }

        service.cancelAppListRequestForInteractiveWorkload(logCancellation: false)

        #expect(service.pendingAppListRequest?.clientID == clientID)
        #expect(service.appListRequestTask == nil)
        #expect(service.appListRequestToken != originalToken)
    }
}
#endif
