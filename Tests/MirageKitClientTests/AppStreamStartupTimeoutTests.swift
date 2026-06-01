//
//  AppStreamStartupTimeoutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

@Suite("App Stream Startup Timeout")
struct AppStreamStartupTimeoutTests {
    @MainActor
    @Test("App stream startup timeout clears pending setup and reports failure")
    func appStreamStartupTimeoutClearsPendingSetupAndReportsFailure() async throws {
        let service = MirageClientService(deviceName: "App Timeout Test")
        let appSessionID = UUID()
        var failure: MirageClientService.AppStreamStartupFailure?
        service.onAppStreamStartupFailed = { failure = $0 }
        service.pendingStreamSetupRequestID = UUID()
        service.pendingStreamSetupKind = .app
        service.pendingStreamSetupAppSessionID = appSessionID

        service.scheduleAppStreamStartTimeout(
            appSessionID: appSessionID,
            bundleIdentifier: "com.example.Editor",
            timeout: .milliseconds(20)
        )

        try await waitUntil(timeout: .seconds(10)) {
            failure != nil
        }

        #expect(failure?.bundleIdentifier == "com.example.Editor")
        #expect(failure?.message.contains("timed out") == true)
        #expect(service.pendingStreamSetupRequestID == nil)
        #expect(service.pendingStreamSetupKind == nil)
        #expect(service.pendingStreamSetupAppSessionID == nil)
        #expect(service.appStreamStartTimeoutTask == nil)
    }

    @MainActor
    @Test("App stream started cancels startup timeout")
    func appStreamStartedCancelsStartupTimeout() async throws {
        let service = MirageClientService(deviceName: "App Timeout Cancel Test")
        let appSessionID = UUID()
        var failure: MirageClientService.AppStreamStartupFailure?
        service.onAppStreamStartupFailed = { failure = $0 }
        service.pendingStreamSetupRequestID = UUID()
        service.pendingStreamSetupKind = .app
        service.pendingStreamSetupAppSessionID = appSessionID

        service.scheduleAppStreamStartTimeout(
            appSessionID: appSessionID,
            bundleIdentifier: "com.example.Editor",
            timeout: .milliseconds(80)
        )

        let started = AppStreamStartedMessage(
            appSessionID: appSessionID,
            startupRequestID: service.pendingStreamSetupRequestID,
            bundleIdentifier: "com.example.Editor",
            appName: "Editor",
            windows: []
        )
        service.handleAppStreamStarted(try ControlMessage(type: .appStreamStarted, content: started))
        try await Task.sleep(for: .milliseconds(120))

        #expect(failure == nil)
        #expect(service.appStreamStartTimeoutTask == nil)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for app stream startup timeout")
    }
}
