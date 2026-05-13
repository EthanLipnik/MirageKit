//
//  UnlockManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import MirageKit
import Loom

#if os(macOS)
import IOKit.pwr_mgt

package actor UnlockManager {
    /// Number of failed unlock attempts allowed per client within the rate-limit window.
    private static let maxAttempts = 5

    /// Rolling window used to rate-limit repeated unlock attempts from one client.
    private static let rateLimitWindow: TimeInterval = 300

    package enum UnlockResult: Equatable {
        case success
        case failure(LoomCredentialSubmissionErrorCode, String)

        package var canRetry: Bool {
            if case let .failure(code, _) = self {
                return code != .rateLimited && code != .notAuthorized
            }
            return false
        }
    }

    package let sessionMonitor: SessionStateMonitor

    private let environment: UnlockEnvironment
    private var attemptsByClient: [UUID: [Date]] = [:]
    private var powerAssertionID: IOPMAssertionID = 0

    package init(
        sessionMonitor: SessionStateMonitor,
        environment: UnlockEnvironment = .init()
    ) {
        self.sessionMonitor = sessionMonitor
        self.environment = environment
    }

    package func attemptUnlock(
        username: String?,
        password: String,
        requiresUserIdentifier: Bool,
        clientID: UUID
    ) async -> (result: UnlockResult, retriesRemaining: Int?, retryAfterSeconds: Int?) {
        let limit = checkRateLimit(clientID: clientID)
        if limit.isLimited {
            return (.failure(.rateLimited, "Too many attempts. Try again later."), limit.remaining, limit.retryAfter)
        }

        let detectedState = await sessionMonitor.refreshState(notify: false)
        guard detectedState.requiresCredentials else {
            MirageLogger.host("Skipping unlock attempt because host session is already active")
            return (.failure(.notReady, "Host session is already unlocked."), limit.remaining, nil)
        }

        let requiresUsernameForAttempt = detectedState.requiresUserIdentifier
        if requiresUsernameForAttempt != requiresUserIdentifier {
            MirageLogger.host(
                "Unlock request username requirement mismatch (request: \(requiresUserIdentifier), detected: \(requiresUsernameForAttempt)); using detected state"
            )
        }

        recordAttempt(clientID: clientID)
        let remaining = remainingAttempts(for: clientID)

        let resolvedUsername: String
        if requiresUsernameForAttempt {
            guard let requestedUser = username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedUser.isEmpty else {
                return (.failure(.invalidCredentials, "Username is required for login"), remaining, nil)
            }
            resolvedUsername = requestedUser
        } else {
            guard let consoleUser = MirageLoginSessionState.currentConsoleUser(ignoringRoot: true) else {
                MirageLogger.error(.host, "No console user found")
                return (.failure(.notAuthorized, "No user session to unlock"), remaining, nil)
            }
            resolvedUsername = consoleUser
        }

        MirageLogger.host("Attempting unlock for user: \(resolvedUsername)")

        let verificationResult = await verifyCredentialsViaAuthorization(username: resolvedUsername, password: password)
        switch verificationResult {
        case .valid:
            break
        case .invalid:
            MirageLogger.host("Password verification failed for user \(resolvedUsername)")
            return (.failure(.invalidCredentials, "Incorrect password"), remaining, nil)
        case .timedOut:
            MirageLogger.error(.host, "Password verification timed out for user \(resolvedUsername)")
            return (.failure(.timeout, "Credential verification timed out. Try again."), remaining, nil)
        case let .failedToRun(reason):
            MirageLogger.error(.host, "Password verification failed to run: \(reason)")
            return (.failure(.internalError, "Unable to verify credentials on the host."), remaining, nil)
        }

        MirageLogger.host("Password verified successfully for user \(resolvedUsername)")

        await environment.prepareForCredentialEntry()
        defer {
            Task {
                await self.environment.cleanupAfterCredentialEntry()
                await self.releaseDisplayAssertion()
            }
        }

        wakeDisplayNonBlocking()
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return (.failure(.internalError, "Unlock was cancelled."), remaining, nil)
        }

        let loginReadyAfterWake = await waitForLoginWindowReady(timeout: 6.0)
        if !loginReadyAfterWake {
            MirageLogger.host("Login window not detected after wake; continuing with non-HID unlock checks")
        }

        var unlocked = false

        MirageLogger.host("Trying SkyLight session switch...")
        let skylightResult = trySkyLightUnlock(username: resolvedUsername)
        if skylightResult {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return (.failure(.internalError, "Unlock was cancelled."), remaining, nil)
            }
            if await sessionMonitor.refreshState() == .ready {
                unlocked = true
            }
        }

        if !unlocked {
            let stateBeforeHID = await sessionMonitor.refreshState(notify: false)
            if !stateBeforeHID.requiresCredentials {
                MirageLogger.host("Skipping HID unlock because host session became active")
                unlocked = true
            } else {
                let lockUIReady: Bool = if loginReadyAfterWake {
                    true
                } else {
                    await waitForLoginWindowReady(timeout: 1.5)
                }
                guard lockUIReady else {
                    MirageLogger.error(.host, "Skipping HID unlock because lock UI is not visible")
                    return (
                        .failure(.timeout, "Lock screen is not ready for credential entry. Try again."),
                        remaining,
                        nil
                    )
                }

                MirageLogger.host("Typing credentials via HID...")
                unlocked = await tryHIDUnlock(
                    username: requiresUsernameForAttempt ? resolvedUsername : nil,
                    password: password,
                    requiresUserIdentifier: requiresUsernameForAttempt
                )
            }
        }

        guard unlocked else {
            MirageLogger.host("Unlock methods did not activate session")
            return (
                .failure(.timeout, "Unable to reach lock screen for credential entry. Try again."),
                remaining,
                nil
            )
        }

        let newState = await pollForUnlockCompletion(timeout: 25.0, pollInterval: 0.35)
        if newState == .ready {
            MirageLogger.host("Unlock successful!")
            return (.success, remaining, nil)
        }

        MirageLogger.host("Password correct but session still locked (state: \(newState))")
        return (.failure(.invalidCredentials, "Password verified but unlock failed. Try again."), remaining, nil)
    }

    package func releaseDisplayAssertion() async {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
            MirageLogger.host("Released power assertion")
        }
    }

    private func wakeDisplayNonBlocking() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "3"]
        do {
            try process.run()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to wake display with caffeinate: ")
        }

        if powerAssertionID == 0 {
            let assertionName = "MirageUnlock" as CFString
            let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString

            let result = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                assertionName,
                &powerAssertionID
            )

            if result == kIOReturnSuccess {
                MirageLogger.host("Created power assertion for unlock")
            }
        }
    }

    private func focusLoginField() async {
        let bounds = await environment.displayBoundsProvider()
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        postMouseClick(at: point)
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
    }

    private func postMouseClick(at point: CGPoint) {
        if let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            environment.postHIDEvent(down)
        }
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            environment.postHIDEvent(up)
        }
    }

    private func typeStringViaCGEvent(_ text: String) async {
        MirageLogger.host("Typing text via CGEvent (\(text.count) characters)")

        for char in text {
            postKeyEvent(for: char)
            do {
                try await Task.sleep(for: .milliseconds(30))
            } catch {
                return
            }
        }
    }

    private func postKeyEvent(for character: Character) {
        guard let keyInfo = UnlockKeyCodeMapper.keyCode(for: character) else { return }
        postKeyEvent(keyCode: keyInfo.keyCode, shift: keyInfo.needsShift)
    }

    private func postKeyEvent(keyCode: UInt16, shift: Bool) {
        if shift,
           let shiftDown = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Shift), keyDown: true) {
            environment.postHIDEvent(shiftDown)
        }

        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            environment.postHIDEvent(keyDown)
        }

        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            environment.postHIDEvent(keyUp)
        }

        if shift,
           let shiftUp = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Shift), keyDown: false) {
            environment.postHIDEvent(shiftUp)
        }
    }

    private func isLoginWindowVisible() -> Bool {
        if MirageLoginSessionState.isLoginWindowVisible() {
            return true
        }

        if MirageLoginSessionState.isLoginWindowVisible(includeOffscreenWindows: true) {
            MirageLogger.host("Login window detected in off-screen window list")
            return true
        }

        return false
    }

    private func waitForLoginWindowReady(timeout: TimeInterval = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var pollCount = 0

        MirageLogger.host("Waiting for loginwindow to render (timeout: \(timeout)s)")

        while Date() < deadline {
            pollCount += 1
            if isLoginWindowVisible() {
                MirageLogger.host("Login window ready after \(pollCount) polls")
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }

        MirageLogger.error(.host, "Login window not detected after \(timeout)s (\(pollCount) polls)")
        return false
    }

    private func trySkyLightUnlock(username: String) -> Bool {
        guard let result = callSLSSessionSwitchToUser(username) else {
            MirageLogger.host("SLSSessionSwitchToUser not available")
            return false
        }

        MirageLogger.host("SLSSessionSwitchToUser result: \(result)")
        return result == 0
    }

    private func tryHIDUnlock(username: String?, password: String, requiresUserIdentifier: Bool) async -> Bool {
        let stateBeforeInput = await sessionMonitor.refreshState(notify: false)
        guard stateBeforeInput.requiresCredentials else {
            MirageLogger.host("Skipping HID unlock because session no longer requires unlock")
            return false
        }

        await focusLoginField()

        if requiresUserIdentifier, let username {
            await typeStringViaCGEvent(username)
            postKeyEvent(keyCode: UInt16(kVK_Tab), shift: false)
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return false
            }
        }

        await typeStringViaCGEvent(password)
        postKeyEvent(keyCode: UInt16(kVK_Return), shift: false)

        return true
    }

    private func pollForUnlockCompletion(
        timeout: TimeInterval = 25.0,
        pollInterval: TimeInterval = 0.35
    ) async -> LoomSessionAvailability {
        let startTime = Date()
        var lastState = await sessionMonitor.refreshState(notify: false)
        var pollCount = 0

        MirageLogger.host("Starting unlock polling (timeout: \(timeout)s, interval: \(pollInterval)s)")

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
            } catch {
                return lastState
            }
            pollCount += 1

            let newState = await sessionMonitor.refreshState(notify: false)
            if newState == .ready {
                let elapsedText = Date().timeIntervalSince(startTime)
                    .formatted(.number.precision(.fractionLength(2)))
                MirageLogger.host("Unlock detected after \(elapsedText)s (\(pollCount) polls)")
                return newState
            }

            if newState != lastState {
                MirageLogger.host("State changed during unlock polling: \(lastState) -> \(newState)")
                lastState = newState
            }
        }

        MirageLogger.host("Unlock polling timed out after \(timeout)s (\(pollCount) polls), final state: \(lastState)")
        return lastState
    }

    private func checkRateLimit(clientID: UUID) -> (isLimited: Bool, remaining: Int?, retryAfter: Int?) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []

        if recentAttempts.count >= Self.maxAttempts {
            if let oldest = recentAttempts.min() {
                let retryAfter = Int(oldest.addingTimeInterval(Self.rateLimitWindow).timeIntervalSince(now)) + 1
                return (true, 0, retryAfter)
            }
            return (true, 0, Int(Self.rateLimitWindow))
        }

        return (false, Self.maxAttempts - recentAttempts.count, nil)
    }

    private func recordAttempt(clientID: UUID) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.rateLimitWindow)
        var attempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        attempts.append(now)
        attemptsByClient[clientID] = attempts
    }

    private func remainingAttempts(for clientID: UUID) -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        return max(0, Self.maxAttempts - recentAttempts.count)
    }
}

#endif
