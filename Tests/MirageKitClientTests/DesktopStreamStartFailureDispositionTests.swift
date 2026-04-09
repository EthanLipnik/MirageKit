//
//  DesktopStreamStartFailureDispositionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Desktop Stream Start Failure Disposition")
struct DesktopStreamStartFailureDispositionTests {
    @Test("Pending desktop starts clear for any explicit pre-activation host error")
    func pendingDesktopStartsClearForAnyExplicitPreActivationHostError() {
        #expect(
            desktopStreamStartFailureDisposition(
                errorCode: .invalidMessage,
                desktopStartPending: true,
                hasActiveDesktopStream: false
            ) == .clearPendingStart
        )
        #expect(
            desktopStreamStartFailureDisposition(
                errorCode: .networkError,
                desktopStartPending: true,
                hasActiveDesktopStream: false
            ) == .clearPendingStart
        )
    }

    @Test("Active desktop streams do not clear pending state from unrelated errors")
    func activeDesktopStreamsDoNotClearPendingStateFromUnrelatedErrors() {
        #expect(
            desktopStreamStartFailureDisposition(
                errorCode: .virtualDisplayStartFailed,
                desktopStartPending: true,
                hasActiveDesktopStream: true
            ) == .noChange
        )
    }
}
