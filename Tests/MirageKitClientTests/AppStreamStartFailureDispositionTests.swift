//
//  AppStreamStartFailureDispositionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("App Stream Start Failure Disposition")
struct AppStreamStartFailureDispositionTests {
    @Test("Pending app start without an active stream clears the primary claim")
    func pendingAppStartClearsPrimaryClaim() {
        let disposition = appStreamStartFailureDisposition(
            appStartPending: true,
            hasActiveStream: false
        )

        #expect(disposition == .clearPendingPrimaryClaim)
    }

    @Test("Active app stream keeps the existing claim state")
    func activeAppStreamKeepsClaimState() {
        let disposition = appStreamStartFailureDisposition(
            appStartPending: true,
            hasActiveStream: true
        )

        #expect(disposition == .noChange)
    }

    @Test("No pending app start leaves claim state unchanged")
    func noPendingAppStartLeavesClaimStateUnchanged() {
        let disposition = appStreamStartFailureDisposition(
            appStartPending: false,
            hasActiveStream: false
        )

        #expect(disposition == .noChange)
    }
}
#endif
