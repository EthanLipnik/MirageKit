//
//  SessionStateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/7/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import IOKit
import IOKit.pwr_mgt

/// Darwin notification functions
/// These are declared in notify.h but not exposed to Swift
@_silgen_name("notify_register_dispatch")
func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @convention(block) @Sendable (Int32) -> Void
)
    -> UInt32

@_silgen_name("notify_cancel")
func notify_cancel(_ token: Int32) -> UInt32

private let notifyStatusOK: UInt32 = 0

/// Monitors the Mac's session state (locked, unlocked, sleeping, at login screen)
/// Uses CGSession APIs, Darwin notifications, and IOKit for comprehensive detection
actor SessionStateMonitor {
    /// Current detected session state
    private(set) var currentState: HostSessionState = .active

    /// Callback for state changes
    private var onStateChange: (@Sendable (HostSessionState) -> Void)?

    /// Darwin notification tokens for cleanup
    private var notifyTokens: [Int32] = []

    /// Whether monitoring is active
    private var isMonitoring = false

    /// Dispatch queue for notifications
    private let notifyQueue = DispatchQueue(label: "com.mirage.sessionMonitor", qos: .userInitiated)

    // MARK: - Public API

    /// Start monitoring session state
    /// - Parameter onStateChange: Callback invoked when state changes (called on arbitrary queue)
    func start(onStateChange: @escaping @Sendable (HostSessionState) -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true
        self.onStateChange = onStateChange

        // Get initial state
        let initialState = detectCurrentState()
        if initialState != currentState {
            currentState = initialState
            onStateChange(initialState)
        }

        // Register for Darwin notifications
        registerNotifications()

        MirageLogger.log(.host, "SessionStateMonitor started, initial state: \(currentState)")
    }

    /// Stop monitoring session state
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        onStateChange = nil

        // Unregister Darwin notifications
        for token in notifyTokens {
            notify_cancel(token)
        }
        notifyTokens.removeAll()

        MirageLogger.log(.host, "SessionStateMonitor stopped")
    }

    /// Force a state refresh and return current state
    func refreshState(notify: Bool = true) -> HostSessionState {
        let newState = detectCurrentState()
        if newState != currentState {
            currentState = newState
            if notify { onStateChange?(newState) }
        }
        return currentState
    }

    // MARK: - State Detection

    /// Detect current session state using multiple sources
    private func detectCurrentState() -> HostSessionState {
        // Check if system is sleeping via IOKit
        if isSystemSleeping() { return .sleeping }

        let loginWindowVisible = isLoginWindowVisible()
        if loginWindowVisible { MirageLogger.log(.host, "Login window visible (lock/login screen detected)") }

        if let consoleUsers = getConsoleUserSessions(), !consoleUsers.isEmpty {
            let summary = consoleUsers.enumerated().map { index, info in
                "(#\(index) user=\(info.userName ?? "nil") loginDone=\(String(describing: info.loginDone)) onConsole=\(String(describing: info.onConsole)) locked=\(String(describing: info.locked)))"
            }.joined(separator: ", ")
            MirageLogger.log(.host, "Console sessions: [\(summary)]")

            let loginWindowUsers = consoleUsers.filter {
                let name = $0.userName?.lowercased() ?? ""
                return name == "loginwindow" || name == "loginwindow.app" || name == "login window"
            }
            let loggedInUsers = consoleUsers.filter {
                guard let name = $0.userName, !name.isEmpty else { return false }
                let lower = name.lowercased()
                return lower != "loginwindow" && lower != "loginwindow.app" && lower != "login window"
            }

            let hasLoggedInUser = !loggedInUsers.isEmpty
            let hasLoginWindowUser = !loginWindowUsers.isEmpty
            let anyLocked = consoleUsers.contains { $0.locked == true }
            let anyLoginDoneFalse = consoleUsers.contains { $0.loginDone == false }
            let anyOffConsole = loggedInUsers.contains { $0.onConsole == false }

            if loginWindowVisible || hasLoginWindowUser { return hasLoggedInUser ? .screenLocked : .loginScreen }

            if anyLoginDoneFalse, !hasLoggedInUser { return .loginScreen }

            if anyLocked { return .screenLocked }

            if anyOffConsole {
                let fallbackLocked = isScreenLocked()
                if fallbackLocked {
                    MirageLogger.log(.host, "User session not on console and lock detected - treating as screenLocked")
                    return .screenLocked
                }
                MirageLogger.log(
                    .host,
                    "User session not on console but no lock detected - treating as active (headless console session)"
                )
                return .active
            }

            if hasLoggedInUser { return .active }
        }

        // Use CGSession to check login and lock state
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No session dictionary - could be headless Mac or early boot
            // Try alternative detection: check if console user exists
            if let consoleUser = getConsoleUser(), !consoleUser.isEmpty, consoleUser != "loginwindow" {
                let locked = isScreenLocked()
                if locked {
                    MirageLogger.log(
                        .host,
                        "No CGSession dict but console user '\(consoleUser)' exists and lock detected - assuming screenLocked"
                    )
                    return .screenLocked
                }
                MirageLogger.log(
                    .host,
                    "No CGSession dict but console user '\(consoleUser)' exists without lock - assuming active (headless console session)"
                )
                return .active
            }
            return .loginScreen
        }

        // Debug: log the session dictionary keys
        MirageLogger.log(.host, "CGSession keys: \(sessionDict.keys.sorted())")

        // Check if at login window (no user has logged in)
        // kCGSessionLoginDoneKey is the canonical key (kCGSSessionLoginCompletedKey is legacy)
        // Also check kCGSSessionOnConsoleKey for console access
        let loginCompleted = sessionDict["kCGSessionLoginDoneKey"] as? Bool
            ?? sessionDict["kCGSSessionLoginCompletedKey"] as? Bool
            ?? sessionDict["kCGSSessionLoginDoneKey"] as? Bool
            ?? false
        let onConsole = sessionDict["kCGSSessionOnConsoleKey"] as? Bool ?? false
        let userName = sessionDict["kCGSSessionUserNameKey"] as? String

        let lockedFlag = sessionDict["CGSSessionScreenIsLocked"] as? Bool
            ?? sessionDict["kCGSSessionScreenIsLocked"] as? Bool
            ?? sessionDict["kCGSessionScreenIsLocked"] as? Bool
            ?? false
        let fallbackLocked = lockedFlag ? false : isScreenLocked()
        let isLocked = lockedFlag || fallbackLocked

        MirageLogger.log(
            .host,
            "Session: loginCompleted=\(loginCompleted), onConsole=\(onConsole), user=\(userName ?? "nil"), locked=\(isLocked)"
        )

        // Alternative check: if we have a username, user is logged in
        if let user = userName, !user.isEmpty {
            // User is logged in - check if screen is locked
            if isLocked { return .screenLocked }

            if !onConsole {
                if isLocked {
                    MirageLogger.log(.host, "User session not on console and lock detected - treating as screenLocked")
                    return .screenLocked
                }
                MirageLogger.log(
                    .host,
                    "User session not on console but not locked - treating as active (headless console session)"
                )
                return .active
            }

            // If loginCompleted is false but we have a user, it might be a headless Mac
            // where the display session hasn't fully initialized
            if !loginCompleted {
                MirageLogger.log(.host, "loginCompleted=false but user '\(user)' exists - treating as headless session")
                return .active // User logged in, not locked
            }

            return .active
        }

        if loginWindowVisible { return loginCompleted ? .screenLocked : .loginScreen }

        if !loginCompleted { return .loginScreen }

        // Check if screen is locked
        if isLocked { return .screenLocked }

        // User is logged in and screen is unlocked
        return .active
    }

    /// Read console session info from IOConsoleUsers (more reliable on headless Macs).
    private struct ConsoleUserSession {
        let userName: String?
        let loginDone: Bool?
        let onConsole: Bool?
        let locked: Bool?
    }

    private func getConsoleUserSessions() -> [ConsoleUserSession]? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOConsoleUsers")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }

        guard let usersRef = IORegistryEntryCreateCFProperty(
            entry,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
            let users = usersRef as? [[String: Any]],
            !users.isEmpty else {
            return nil
        }

        return users.map { user in
            let userName = user["kCGSSessionUserNameKey"] as? String
                ?? user["kCGSessionUserNameKey"] as? String
            let loginDone = user["kCGSessionLoginDoneKey"] as? Bool
                ?? user["kCGSSessionLoginCompletedKey"] as? Bool
                ?? user["kCGSSessionLoginDoneKey"] as? Bool
            let onConsole = user["kCGSSessionOnConsoleKey"] as? Bool
                ?? user["kCGSessionOnConsoleKey"] as? Bool
            let locked = user["CGSSessionScreenIsLocked"] as? Bool
                ?? user["kCGSSessionScreenIsLocked"] as? Bool
                ?? user["kCGSessionScreenIsLocked"] as? Bool
            return ConsoleUserSession(
                userName: userName,
                loginDone: loginDone,
                onConsole: onConsole,
                locked: locked
            )
        }
    }

    /// Get the current console user (works even on headless Macs)
    private func getConsoleUser() -> String? {
        // Use 'stat /dev/console' to get console owner
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        task.arguments = ["-f", "%Su", "/dev/console"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let user = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) { return user }
        } catch {
            // Ignore
        }

        // Fallback: current process user (may not be console user)
        return NSUserName()
    }

    /// Check if screen is locked via alternative method (screensaver/lock process)
    private func isScreenLocked() -> Bool {
        // Fast path: look for loginwindow/screen saver shielding windows
        if isLoginWindowVisible() { return true }

        // Check via ioreg for screen lock state
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ioreg")
        task.arguments = ["-r", "-c", "IODisplayWrangler", "-d", "1"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // If DeviceDesiresPower is 0, display is off/locked
                if output.contains("\"DevicePowerState\" = 0") { return true }
            }
        } catch {
            // Ignore errors
        }

        // Method 3: Check via defaults for screensaver state
        // defaults read com.apple.screensaver 2>/dev/null returns values if screensaver is active

        return false
    }

    /// Check for loginwindow or screensaver shielding windows (indicates locked UI)
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
            MirageLogger.log(.host, "Login window detected in off-screen window list")
            return true
        }

        return false
    }

    /// Check if the system is sleeping using IOKit
    private func isSystemSleeping() -> Bool {
        // Get the IOPMrootDomain
        let rootDomainEntry = IORegistryEntryFromPath(
            kIOMainPortDefault,
            "IOPower:/IOPowerConnection/IOPMrootDomain"
        )

        guard rootDomainEntry != MACH_PORT_NULL else { return false }

        defer { IOObjectRelease(rootDomainEntry) }

        // Check CurrentPowerState - 0 typically means sleeping
        if let powerState = IORegistryEntryCreateCFProperty(
            rootDomainEntry,
            "CurrentPowerState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int {
            // Power state 0 = off/sleeping, higher = awake
            return powerState == 0
        }

        return false
    }

    // MARK: - Darwin Notifications

    /// Register for system state change notifications
    private func registerNotifications() {
        // Screen lock/unlock notifications
        registerNotification("com.apple.screenIsLocked") { [weak self] in
            Task { await self?.handleStateChange() }
        }

        registerNotification("com.apple.screenIsUnlocked") { [weak self] in
            Task { await self?.handleStateChange() }
        }

        // Session login/logout
        registerNotification("com.apple.sessionDidLogin") { [weak self] in
            Task { await self?.handleStateChange() }
        }

        registerNotification("com.apple.sessionDidLogout") { [weak self] in
            Task { await self?.handleStateChange() }
        }

        // Display sleep/wake (indicates system wake)
        registerNotification("com.apple.screensaver.didstop") { [weak self] in
            Task { await self?.handleStateChange() }
        }

        registerNotification("com.apple.screensaver.didstart") { [weak self] in
            Task { await self?.handleStateChange() }
        }
    }

    /// Register a single Darwin notification
    private func registerNotification(_ name: String, handler: @escaping @Sendable () -> Void) {
        var token: Int32 = 0

        // Explicitly create the block as a typed escaping closure
        // This prevents "closure argument passed as @noescape to Objective-C has escaped" runtime error
        let block: @convention(block) @Sendable (Int32) -> Void = { _ in
            handler()
        }

        let status = notify_register_dispatch(
            name,
            &token,
            notifyQueue,
            block
        )

        if status == notifyStatusOK { notifyTokens.append(token) } else {
            MirageLogger.error(.host, "Failed to register notification: \(name), status: \(status)")
        }
    }

    /// Handle a state change notification
    private func handleStateChange() {
        let newState = detectCurrentState()
        if newState != currentState {
            let oldState = currentState
            currentState = newState
            MirageLogger.log(.host, "Session state changed: \(oldState) -> \(newState)")
            onStateChange?(newState)
        }
    }
}

#endif
