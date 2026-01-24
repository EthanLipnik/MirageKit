//
//  UnlockManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/7/26.
//

import Foundation
import CoreGraphics
import Security

#if os(macOS)
import IOKit.pwr_mgt
import Carbon.HIToolbox

// Private SkyLight functions for session management - loaded dynamically at runtime
// These are used by loginwindow and other system components
// Using dlsym instead of @_silgen_name to avoid linker errors with private symbols

/// Dynamically call SLSSessionSwitchToUser from the private SkyLight framework
/// Returns 0 on success, non-zero on failure, or nil if the function isn't available
private func callSLSSessionSwitchToUser(_ username: String) -> Int32? {
    // Get handle to SkyLight framework
    guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
        return nil
    }
    defer { dlclose(skylight) }

    // Get function pointer
    guard let sym = dlsym(skylight, "SLSSessionSwitchToUser") else {
        return nil
    }

    // Cast to function type and call
    typealias SLSSessionSwitchToUserFunc = @convention(c) (UnsafePointer<CChar>) -> Int32
    let func_ptr = unsafeBitCast(sym, to: SLSSessionSwitchToUserFunc.self)

    return username.withCString { usernamePtr in
        func_ptr(usernamePtr)
    }
}

/// Manages programmatic unlock for locked Macs using Authorization Services
/// Verifies credentials via PAM/Authorization and attempts to unlock the session
actor UnlockManager {
    /// Result of an unlock attempt
    enum UnlockResult: Equatable {
        case success
        case failure(UnlockErrorCode, String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var error: UnlockError? {
            if case .failure(let code, let message) = self {
                return UnlockError(code: code, message: message)
            }
            return nil
        }

        var canRetry: Bool {
            if case .failure(let code, _) = self {
                return code != .rateLimited && code != .notAuthorized
            }
            return false
        }
    }

    /// Session state monitor for verifying unlock success
    private let sessionMonitor: SessionStateMonitor

    /// Rate limiting: track attempts per client
    private var attemptsByClient: [UUID: [Date]] = [:]

    /// Maximum attempts per window
    private let maxAttempts = 5

    /// Rate limit window in seconds
    private let rateLimitWindow: TimeInterval = 300 // 5 minutes

    /// Power assertion ID for keeping display awake
    private var powerAssertionID: IOPMAssertionID = 0

    init(sessionMonitor: SessionStateMonitor) {
        self.sessionMonitor = sessionMonitor
    }

    // MARK: - Unlock API

    /// Attempt to unlock the Mac using Authorization Services
    /// - Parameters:
    ///   - username: Username to unlock (required when at login screen)
    ///   - password: Password to verify and use for unlock
    ///   - requiresUsername: Whether login screen requires a username entry
    ///   - clientID: Client ID for rate limiting
    /// - Returns: Result of the unlock attempt with retry information
    func attemptUnlock(
        username: String?,
        password: String,
        requiresUsername: Bool,
        clientID: UUID
    ) async -> (result: UnlockResult, retriesRemaining: Int?, retryAfterSeconds: Int?) {
        // Check rate limit
        let limit = checkRateLimit(clientID: clientID)
        if limit.isLimited {
            return (.failure(.rateLimited, "Too many attempts. Try again later."), limit.remaining, limit.retryAfter)
        }

        // Record this attempt
        recordAttempt(clientID: clientID)
        let remaining = getRemainingAttempts(clientID: clientID)

        let resolvedUsername: String
        if requiresUsername {
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

        // Step 1: Verify credentials using Authorization Services
        let credentialsValid = verifyCredentialsViaAuthorization(username: resolvedUsername, password: password)

        if !credentialsValid {
            MirageLogger.host("Password verification failed for user \(username)")
            return (.failure(.invalidCredentials, "Incorrect password"), remaining, nil)
        }

        MirageLogger.host("Password verified successfully for user \(username)")

        // Step 2: Ensure virtual display exists (for headless Macs)
        await ensureVirtualDisplay()

        // Step 3: Wake display
        wakeDisplayNonBlocking()
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // Step 4: Try multiple unlock methods
        var unlocked = false

        // Method 1: Try session switch via SkyLight
        MirageLogger.host("Trying SkyLight session switch...")
        let skylightResult = trySkyLightUnlock(username: resolvedUsername)
        if skylightResult {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await sessionMonitor.refreshState() == .active {
                unlocked = true
            }
        }

        // Method 2: HID-level typing (login screen or lock screen)
        if !unlocked {
            MirageLogger.host("Typing credentials via HID...")
            unlocked = await tryHIDUnlock(
                username: requiresUsername ? resolvedUsername : nil,
                password: password,
                requiresUsername: requiresUsername
            )
        }

        // Poll for unlock completion instead of fixed wait
        // This handles cases where unlock takes longer than expected on headless Macs
        let newState = await pollForUnlockCompletion(timeout: 10.0, pollInterval: 0.3)

        if newState == .active {
            MirageLogger.host("Unlock successful!")
            await releaseVirtualDisplay()
            return (.success, remaining, nil)
        } else {
            // Even though password was correct, unlock might have failed
            // This can happen if keyboard simulation didn't work or loginwindow didn't receive events
            MirageLogger.host("Password correct but session still locked (state: \(newState))")
            await releaseVirtualDisplay()
            return (.failure(.invalidCredentials, "Password verified but unlock failed. Try again."), remaining, nil)
        }
    }

    // MARK: - Credential Verification

    /// Verify credentials using macOS Authorization Services
    /// This uses PAM under the hood and is the same mechanism used by the login window
    private func verifyCredentialsViaAuthorization(username: String, password: String) -> Bool {
        // Use /usr/bin/dscl to verify password
        // This is more reliable than Authorization APIs for local accounts
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = ["/Local/Default", "-authonly", username, password]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return true
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                MirageLogger.error(.host, "dscl auth failed: \(errorOutput)")
                return false
            }
        } catch {
            MirageLogger.error(.host, "Failed to run dscl: \(error)")
            return false
        }
    }

    // MARK: - Unlock Methods

    /// Try to unlock via SkyLight session management (private API)
    private func trySkyLightUnlock(username: String) -> Bool {
        // Try to switch to the user's session
        // This may dismiss the lock screen if the session already exists
        guard let result = callSLSSessionSwitchToUser(username) else {
            MirageLogger.host("SLSSessionSwitchToUser not available")
            return false
        }

        MirageLogger.host("SLSSessionSwitchToUser result: \(result)")
        return result == 0
    }

    /// Try to unlock via HID-level keyboard simulation (with verified password)
    private func tryHIDUnlock(username: String?, password: String, requiresUsername: Bool) async -> Bool {
        await focusLoginField()

        if requiresUsername, let username {
            await typeStringViaCGEvent(username)
            postKeyEvent(keyCode: UInt16(kVK_Tab), shift: false)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        await typeStringViaCGEvent(password)
        postKeyEvent(keyCode: UInt16(kVK_Return), shift: false)

        return true
    }

    // MARK: - Virtual Display Management

    /// Ensure virtual display exists for keyboard input on headless Macs
    /// Uses the shared virtual display manager for consistent resolution
    /// Also waits for loginwindow to render on the display before returning
    private func ensureVirtualDisplay() async {
        do {
            let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(.unlockKeyboard)
            MirageLogger.host("Using shared virtual display \(context.displayID) for unlock")

            // Wait for display to be ready (basic display initialization)
            try? await Task.sleep(for: .milliseconds(300))

            // Wait for loginwindow to actually render on the display
            // This is critical on headless Macs - without this, HID events get queued
            // and delivered later when another display (like Jump Desktop) connects
            let loginWindowReady = await waitForLoginWindowReady(timeout: 5.0)
            if !loginWindowReady {
                MirageLogger.error(.host, "Proceeding with unlock despite loginwindow not being detected - HID events may be queued")
            }
        } catch {
            MirageLogger.error(.host, "Failed to acquire shared virtual display for unlock: \(error)")
        }
    }

    /// Release virtual display
    private func releaseVirtualDisplay() async {
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.unlockKeyboard)
        MirageLogger.host("Released shared virtual display for unlock")
    }

    // MARK: - Helper Methods

    /// Get the current console user
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
               !user.isEmpty, user != "root" {
                return user
            }
        } catch {
            // Ignore
        }

        return NSUserName()
    }

    // MARK: - Login Window Detection

    /// Check if loginwindow or screensaver windows are visible at shielding level
    /// This indicates the lock/login screen is ready to receive input
    private func isLoginWindowVisible() -> Bool {
        let shieldingLevel = CGShieldingWindowLevel()
        let screenSaverLevel = CGWindowLevelForKey(.screenSaverWindow)

        func containsLoginWindow(in windowList: [[String: Any]]) -> Bool {
            for window in windowList {
                guard let ownerName = window[kCGWindowOwnerName as String] as? String else { continue }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0

                if ownerName == "loginwindow" || ownerName == "LoginWindow" {
                    if layer >= shieldingLevel {
                        return true
                    }
                }

                if ownerName == "ScreenSaverEngine", layer >= screenSaverLevel {
                    return true
                }
            }
            return false
        }

        // Check on-screen windows first
        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: onScreen) {
            return true
        }

        // Also check all windows (loginwindow may not be "on screen" on virtual displays)
        if let allWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: allWindows) {
            MirageLogger.host("Login window detected in off-screen window list")
            return true
        }

        return false
    }

    /// Wait for loginwindow to render on the virtual display
    /// This ensures HID events will be delivered to loginwindow instead of being queued
    private func waitForLoginWindowReady(timeout: TimeInterval = 5.0) async -> Bool {
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

    // MARK: - Unlock State Polling

    /// Poll session state until unlock is detected or timeout
    /// This replaces the fixed 1.5s wait with dynamic polling
    private func pollForUnlockCompletion(
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.3
    ) async -> HostSessionState {
        let startTime = Date()
        var lastState = await sessionMonitor.refreshState(notify: false)
        var pollCount = 0

        MirageLogger.host("Starting unlock polling (timeout: \(timeout)s, interval: \(pollInterval)s)")

        while Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
            pollCount += 1

            let newState = await sessionMonitor.refreshState(notify: false)

            if newState == .active {
                let elapsed = Date().timeIntervalSince(startTime)
                MirageLogger.host("Unlock detected after \(String(format: "%.2f", elapsed))s (\(pollCount) polls)")
                return newState
            }

            // Log state changes during polling
            if newState != lastState {
                MirageLogger.host("State changed during unlock polling: \(lastState) -> \(newState)")
                lastState = newState
            }
        }

        MirageLogger.host("Unlock polling timed out after \(timeout)s (\(pollCount) polls), final state: \(lastState)")
        return lastState
    }

    // MARK: - Display Wake

    /// Wake the display without blocking
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

    /// Release the power assertion
    func releaseDisplayAssertion() async {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
            MirageLogger.host("Released power assertion")
        }
    }

    // MARK: - Keyboard Input

    private func focusLoginField() async {
        // Get bounds from shared display manager, fallback to main display
        let bounds: CGRect
        if let sharedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
            bounds = sharedBounds
        } else {
            bounds = CGDisplayBounds(CGMainDisplayID())
        }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)

        postMouseClick(at: point)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func postMouseClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// Type text using CGEvent (HID-level)
    private func typeStringViaCGEvent(_ text: String) async {
        MirageLogger.host("Typing text via CGEvent (\(text.count) characters)")

        for char in text {
            postKeyEvent(for: char)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func postKeyEvent(for character: Character) {
        guard let keyInfo = keyCodeForCharacter(character) else {
            return
        }
        postKeyEvent(keyCode: keyInfo.keyCode, shift: keyInfo.needsShift)
    }

    private func postKeyEvent(keyCode: UInt16, shift: Bool) {
        if shift {
            if let shiftDown = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Shift), keyDown: true) {
                shiftDown.post(tap: .cghidEventTap)
            }
        }

        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }

        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }

        if shift {
            if let shiftUp = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Shift), keyDown: false) {
                shiftUp.post(tap: .cghidEventTap)
            }
        }
    }

    private func keyCodeForCharacter(_ char: Character) -> (keyCode: UInt16, needsShift: Bool)? {
        let charString = String(char)

        if let num = Int(charString), num >= 0 && num <= 9 {
            let codes: [UInt16] = [
                UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4),
                UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
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
            "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z)
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
            "~": (UInt16(kVK_ANSI_Grave), true)
        ]

        if let (code, shift) = specialCodes[char] {
            return (code, shift)
        }

        return nil
    }

    // MARK: - Rate Limiting

    func checkRateLimit(clientID: UUID) -> (isLimited: Bool, remaining: Int?, retryAfter: Int?) {
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

    func recordAttempt(clientID: UUID) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        var attempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        attempts.append(now)
        attemptsByClient[clientID] = attempts
    }

    func getRemainingAttempts(clientID: UUID) -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        return max(0, maxAttempts - recentAttempts.count)
    }
}

#endif
