//
//  AppStreamWindowRetryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App-stream startup retry bookkeeping policy.
//

@testable import MirageKitHost
import MirageKit
import Foundation
import Testing

#if os(macOS)
@Suite("App Stream Window Retry Policy")
struct AppStreamWindowRetryPolicyTests {
    @Test("Retryable failures schedule retries with backoff and gate attempts")
    func retryableFailuresScheduleBackoff() async {
        let manager = AppStreamManager()
        let bundleID = "com.apple.dt.Xcode"
        let windowID = WindowID(42)
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(await manager.canAttemptWindowStartup(bundleID: bundleID, windowID: windowID, now: start))

        let disposition = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "Window not found",
            now: start
        )

        guard case let .retryScheduled(attempt, retryAt) = disposition else {
            Issue.record("Expected retry schedule disposition, got \(disposition)")
            return
        }
        #expect(attempt == 1)
        #expect(abs(retryAt.timeIntervalSince(start) - 0.35) < 0.0001)

        let canAttemptEarly = await manager.canAttemptWindowStartup(
            bundleID: bundleID,
            windowID: windowID,
            now: start.addingTimeInterval(0.20)
        )
        #expect(!canAttemptEarly)

        let canAttemptAfterBackoff = await manager.canAttemptWindowStartup(
            bundleID: bundleID,
            windowID: windowID,
            now: start.addingTimeInterval(0.40)
        )
        #expect(canAttemptAfterBackoff)
    }

    @Test("Terminal failure is emitted once after retry budget is exhausted")
    func terminalFailureIsSingleShotAfterExhaustion() async {
        let manager = AppStreamManager()
        let bundleID = "com.apple.dt.Xcode"
        let windowID = WindowID(99)
        let start = Date(timeIntervalSince1970: 5_000)

        _ = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "attempt 1",
            now: start
        )
        _ = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "attempt 2",
            now: start.addingTimeInterval(1.1)
        )
        let terminal = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "attempt 3",
            now: start.addingTimeInterval(3.5)
        )
        #expect(terminal == .terminal(attempt: 3))

        let suppressed = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "attempt 4",
            now: start.addingTimeInterval(7.0)
        )
        #expect(suppressed == .suppressed)
        let canAttemptAfterTerminal = await manager.canAttemptWindowStartup(
            bundleID: bundleID,
            windowID: windowID,
            now: start.addingTimeInterval(8.0)
        )
        #expect(!canAttemptAfterTerminal)
    }

    @Test("Successful startup clears retry bookkeeping")
    func successfulStartupClearsRetryBookkeeping() async {
        let manager = AppStreamManager()
        let bundleID = "com.apple.dt.Xcode"
        let windowID = WindowID(123)
        let now = Date(timeIntervalSince1970: 9_000)

        _ = await manager.noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: true,
            reason: "Window not found",
            now: now
        )
        let canAttemptBeforeSuccess = await manager.canAttemptWindowStartup(
            bundleID: bundleID,
            windowID: windowID,
            now: now.addingTimeInterval(0.1)
        )
        #expect(!canAttemptBeforeSuccess)

        await manager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)

        #expect(await manager.canAttemptWindowStartup(
            bundleID: bundleID,
            windowID: windowID,
            now: now.addingTimeInterval(0.1)
        ))
    }
}
#endif
