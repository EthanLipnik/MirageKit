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

package struct UnlockEnvironment: Sendable {
    package let displayBoundsProvider: @Sendable () async -> CGRect
    package let prepareForCredentialEntry: @Sendable () async -> Void
    package let cleanupAfterCredentialEntry: @Sendable () async -> Void
    package let postHIDEvent: @Sendable (CGEvent) -> Void

    package init(
        displayBoundsProvider: @escaping @Sendable () async -> CGRect = { CGDisplayBounds(CGMainDisplayID()) },
        prepareForCredentialEntry: @escaping @Sendable () async -> Void = {},
        cleanupAfterCredentialEntry: @escaping @Sendable () async -> Void = {},
        postHIDEvent: @escaping @Sendable (CGEvent) -> Void = { event in
            event.post(tap: .cghidEventTap)
        }
    ) {
        self.displayBoundsProvider = displayBoundsProvider
        self.prepareForCredentialEntry = prepareForCredentialEntry
        self.cleanupAfterCredentialEntry = cleanupAfterCredentialEntry
        self.postHIDEvent = postHIDEvent
    }
}

/// Dynamically call `SLSSessionSwitchToUser` from the private SkyLight framework.
func callSLSSessionSwitchToUser(_ username: String) -> Int32? {
    guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
    defer { dlclose(skylight) }

    guard let sym = dlsym(skylight, "SLSSessionSwitchToUser") else { return nil }

    typealias SLSSessionSwitchToUserFunc = @convention(c) (UnsafePointer<CChar>) -> Int32
    let functionPointer = unsafeBitCast(sym, to: SLSSessionSwitchToUserFunc.self)

    return username.withCString { usernamePtr in
        functionPointer(usernamePtr)
    }
}

package actor UnlockManager {
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
    private let maxAttempts = 5
    private let rateLimitWindow: TimeInterval = 300
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
        let remaining = getRemainingAttempts(clientID: clientID)

        let resolvedUsername: String
        if requiresUsernameForAttempt {
            guard let requestedUser = username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedUser.isEmpty else {
                return (.failure(.invalidCredentials, "Username is required for login"), remaining, nil)
            }
            resolvedUsername = requestedUser
        } else {
            guard let consoleUser = getConsoleUser() else {
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
        try? await Task.sleep(for: .milliseconds(400))

        let loginReadyAfterWake = await waitForLoginWindowReady(timeout: 6.0)
        if !loginReadyAfterWake {
            MirageLogger.host("Login window not detected after wake; continuing with non-HID unlock checks")
        }

        var unlocked = false

        MirageLogger.host("Trying SkyLight session switch...")
        let skylightResult = trySkyLightUnlock(username: resolvedUsername)
        if skylightResult {
            try? await Task.sleep(for: .milliseconds(300))
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
                let lockUIReady: Bool
                if loginReadyAfterWake {
                    lockUIReady = true
                } else {
                    lockUIReady = await waitForLoginWindowReady(timeout: 1.5)
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

    private enum CredentialVerificationResult: Equatable {
        case valid
        case invalid
        case timedOut
        case failedToRun(String)
    }

    private func verifyCredentialsViaAuthorization(
        username: String,
        password: String,
        timeout: Duration = .seconds(8)
    ) async -> CredentialVerificationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = ["/Local/Default", "-authonly", username, password]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to run dscl: ")
            return .failedToRun(error.localizedDescription)
        }

        let result = await waitForProcessExitOrTimeout(process, timeout: timeout)
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.timedOut {
            MirageLogger.error(.host, "dscl auth timed out after \(timeout)")
            return .timedOut
        }

        if result.status == 0 {
            return .valid
        }

        if let errorOutput, !errorOutput.isEmpty {
            MirageLogger.error(.host, "dscl auth failed: \(errorOutput)")
        } else {
            MirageLogger.error(.host, "dscl auth failed with status \(result.status)")
        }
        return .invalid
    }

    private func waitForProcessExitOrTimeout(
        _ process: Process,
        timeout: Duration
    ) async -> (status: Int32, timedOut: Bool) {
        let timeoutTask = Task<Bool, Never> { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return false }
            guard process.isRunning else { return false }
            await self?.terminateProcess(process)
            return true
        }

        let status = await waitForProcessExit(process)
        timeoutTask.cancel()
        let didTimeout = await timeoutTask.value
        return (status, didTimeout)
    }

    private func waitForProcessExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }

            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
    }

    private func terminateProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: .milliseconds(250))
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private func wakeDisplayNonBlocking() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "3"]
        try? process.run()

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

    private func getConsoleUser() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        task.arguments = ["-f", "%Su", "/dev/console"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let user = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !user.isEmpty,
               user != "root" {
                return user
            }
        } catch {
        }

        return NSUserName()
    }

    private func focusLoginField() async {
        let bounds = await environment.displayBoundsProvider()
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        postMouseClick(at: point)
        try? await Task.sleep(for: .milliseconds(120))
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
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func postKeyEvent(for character: Character) {
        guard let keyInfo = keyCodeForCharacter(character) else { return }
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

    private func keyCodeForCharacter(_ char: Character) -> (keyCode: UInt16, needsShift: Bool)? {
        let charString = String(char)

        if let num = Int(charString), num >= 0, num <= 9 {
            let codes: [UInt16] = [
                UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4),
                UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
            ]
            return (codes[num], false)
        }

        let lowerChar = char.lowercased().first!
        let needsShift = char.isUppercase

        let letterCodes: [Character: UInt16] = [
            "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C), "d": UInt16(kVK_ANSI_D),
            "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F), "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H),
            "i": UInt16(kVK_ANSI_I), "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
            "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O), "p": UInt16(kVK_ANSI_P),
            "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R), "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T),
            "u": UInt16(kVK_ANSI_U), "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
            "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        ]

        if let code = letterCodes[lowerChar] {
            return (code, needsShift)
        }

        let specialCodes: [Character: (UInt16, Bool)] = [
            " ": (UInt16(kVK_Space), false),
            "-": (UInt16(kVK_ANSI_Minus), false),
            "=": (UInt16(kVK_ANSI_Equal), false),
            "[": (UInt16(kVK_ANSI_LeftBracket), false),
            "]": (UInt16(kVK_ANSI_RightBracket), false),
            "\\": (UInt16(kVK_ANSI_Backslash), false),
            ";": (UInt16(kVK_ANSI_Semicolon), false),
            "'": (UInt16(kVK_ANSI_Quote), false),
            ",": (UInt16(kVK_ANSI_Comma), false),
            ".": (UInt16(kVK_ANSI_Period), false),
            "/": (UInt16(kVK_ANSI_Slash), false),
            "`": (UInt16(kVK_ANSI_Grave), false),
            "!": (UInt16(kVK_ANSI_1), true),
            "@": (UInt16(kVK_ANSI_2), true),
            "#": (UInt16(kVK_ANSI_3), true),
            "$": (UInt16(kVK_ANSI_4), true),
            "%": (UInt16(kVK_ANSI_5), true),
            "^": (UInt16(kVK_ANSI_6), true),
            "&": (UInt16(kVK_ANSI_7), true),
            "*": (UInt16(kVK_ANSI_8), true),
            "(": (UInt16(kVK_ANSI_9), true),
            ")": (UInt16(kVK_ANSI_0), true),
            "_": (UInt16(kVK_ANSI_Minus), true),
            "+": (UInt16(kVK_ANSI_Equal), true),
            "{": (UInt16(kVK_ANSI_LeftBracket), true),
            "}": (UInt16(kVK_ANSI_RightBracket), true),
            "|": (UInt16(kVK_ANSI_Backslash), true),
            ":": (UInt16(kVK_ANSI_Semicolon), true),
            "\"": (UInt16(kVK_ANSI_Quote), true),
            "<": (UInt16(kVK_ANSI_Comma), true),
            ">": (UInt16(kVK_ANSI_Period), true),
            "?": (UInt16(kVK_ANSI_Slash), true),
            "~": (UInt16(kVK_ANSI_Grave), true),
        ]

        return specialCodes[char]
    }

    private func isLoginWindowVisible() -> Bool {
        let shieldingLevel = CGShieldingWindowLevel()
        let screenSaverLevel = CGWindowLevelForKey(.screenSaverWindow)

        func containsLoginWindow(in windowList: [[String: Any]]) -> Bool {
            for window in windowList {
                guard let ownerName = window[kCGWindowOwnerName as String] as? String else { continue }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0

                if ownerName == "loginwindow" || ownerName == "LoginWindow" {
                    if layer >= shieldingLevel { return true }
                }

                if ownerName == "ScreenSaverEngine", layer >= screenSaverLevel { return true }
            }
            return false
        }

        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: onScreen) {
            return true
        }

        if let allWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: allWindows) {
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
            try? await Task.sleep(for: .milliseconds(200))
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
            try? await Task.sleep(for: .milliseconds(80))
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
            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
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
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []

        if recentAttempts.count >= maxAttempts {
            if let oldest = recentAttempts.min() {
                let retryAfter = Int(oldest.addingTimeInterval(rateLimitWindow).timeIntervalSince(now)) + 1
                return (true, 0, retryAfter)
            }
            return (true, 0, Int(rateLimitWindow))
        }

        return (false, maxAttempts - recentAttempts.count, nil)
    }

    private func recordAttempt(clientID: UUID) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        var attempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        attempts.append(now)
        attemptsByClient[clientID] = attempts
    }

    private func getRemainingAttempts(clientID: UUID) -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        return max(0, maxAttempts - recentAttempts.count)
    }
}

#endif
