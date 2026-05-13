//
//  SessionStateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CoreGraphics
import Foundation
import MirageKit
import Loom

#if os(macOS)
import IOKit
import IOKit.pwr_mgt

/// Darwin notification functions declared in `notify.h` but not exposed to Swift.
@_silgen_name("notify_register_dispatch")
func notify_register_dispatch(
    _: UnsafePointer<CChar>,
    _: UnsafeMutablePointer<Int32>,
    _: DispatchQueue,
    _: @convention(block) @Sendable (Int32) -> Void
)
    -> UInt32

@_silgen_name("notify_cancel")
func notify_cancel(_: Int32) -> UInt32

private let notifyStatusOK: UInt32 = 0

package actor SessionStateMonitor {
    package private(set) var currentState: LoomSessionAvailability = .ready

    private var onStateChange: (@Sendable (LoomSessionAvailability) -> Void)?
    private var notifyTokens: [Int32] = []
    private var isMonitoring = false
    private let notifyQueue = DispatchQueue(label: "com.mirage.sessionMonitor", qos: .userInitiated)

    package init() {}

    package func start(onStateChange: @escaping @Sendable (LoomSessionAvailability) -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true
        self.onStateChange = onStateChange

        let initialState = detectCurrentState()
        if initialState != currentState {
            currentState = initialState
            onStateChange(initialState)
        }

        registerNotifications()
        MirageLogger.log(.host, "SessionStateMonitor started, initial state: \(currentState)")
    }

    package func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        onStateChange = nil

        for token in notifyTokens {
            _ = notify_cancel(token)
        }
        notifyTokens.removeAll()

        MirageLogger.log(.host, "SessionStateMonitor stopped")
    }

    package func refreshState(notify: Bool = true) -> LoomSessionAvailability {
        let newState = detectCurrentState()
        if newState != currentState {
            currentState = newState
            if notify {
                onStateChange?(newState)
            }
        }
        return currentState
    }

    private func detectCurrentState() -> LoomSessionAvailability {
        if isSystemSleeping() {
            return .unavailable
        }

        let loginWindowVisible = MirageLoginSessionState.isLoginWindowVisible()
        if loginWindowVisible {
            MirageLogger.log(.host, "Login window visible (lock/login screen detected)")
        }

        if let consoleUsers = MirageLoginSessionState.consoleUserSessions(), !consoleUsers.isEmpty {
            let summary = consoleUsers.enumerated().map { index, info in
                "(#\(index) user=\(info.userName ?? "nil") loginDone=\(String(describing: info.loginDone)) onConsole=\(String(describing: info.onConsole)) locked=\(String(describing: info.locked)))"
            }.joined(separator: ", ")
            MirageLogger.log(.host, "Console sessions: [\(summary)]")

            let loginWindowUsers = consoleUsers.filter { MirageLoginSessionState.isLoginWindowUserName($0.userName) }
            let loggedInUsers = consoleUsers.filter {
                guard let name = $0.userName, !name.isEmpty else { return false }
                return !MirageLoginSessionState.isLoginWindowUserName(name)
            }

            let hasLoggedInUser = !loggedInUsers.isEmpty
            let hasLoginWindowUser = !loginWindowUsers.isEmpty
            let anyLocked = consoleUsers.contains { $0.locked == true }
            let anyLoginDoneFalse = consoleUsers.contains { $0.loginDone == false }
            let anyOffConsole = loggedInUsers.contains { $0.onConsole == false }

            if loginWindowVisible || hasLoginWindowUser {
                return hasLoggedInUser ? .credentialsRequired : .credentialsAndUserIdentifierRequired
            }

            if anyLoginDoneFalse, !hasLoggedInUser {
                return .credentialsAndUserIdentifierRequired
            }

            if anyLocked {
                return .credentialsRequired
            }

            if anyOffConsole {
                let fallbackLocked = isScreenLocked()
                if fallbackLocked {
                    MirageLogger.log(.host, "User session not on console and lock detected - treating as screenLocked")
                    return .credentialsRequired
                }
                MirageLogger.log(
                    .host,
                    "User session not on console but no lock detected - treating as active (headless console session)"
                )
                return .ready
            }

            if hasLoggedInUser {
                return .ready
            }
        }

        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            if let consoleUser = MirageLoginSessionState.currentConsoleUser(),
               !consoleUser.isEmpty,
               !MirageLoginSessionState.isLoginWindowUserName(consoleUser) {
                let locked = isScreenLocked()
                if locked {
                    MirageLogger.log(
                        .host,
                        "No CGSession dict but console user '\(consoleUser)' exists and lock detected - assuming screenLocked"
                    )
                    return .credentialsRequired
                }
                MirageLogger.log(
                    .host,
                    "No CGSession dict but console user '\(consoleUser)' exists without lock - assuming active (headless console session)"
                )
                return .ready
            }
            return .credentialsAndUserIdentifierRequired
        }

        MirageLogger.log(.host, "CGSession keys: \(sessionDict.keys.sorted())")

        let loginCompleted = sessionDict["kCGSessionLoginDoneKey"] as? Bool ?? false
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

        if let user = userName, !user.isEmpty {
            if isLocked {
                return .credentialsRequired
            }

            if !onConsole {
                MirageLogger.log(
                    .host,
                    "User session not on console but not locked - treating as active (headless console session)"
                )
                return .ready
            }

            if !loginCompleted {
                MirageLogger.log(.host, "loginCompleted=false but user '\(user)' exists - treating as headless session")
                return .ready
            }

            return .ready
        }

        if loginWindowVisible {
            return loginCompleted ? .credentialsRequired : .credentialsAndUserIdentifierRequired
        }

        if !loginCompleted {
            return .credentialsAndUserIdentifierRequired
        }

        if isLocked {
            return .credentialsRequired
        }

        return .ready
    }

    private func isScreenLocked() -> Bool {
        if MirageLoginSessionState.isLoginWindowVisible() {
            return true
        }

        if let consoleUsers = MirageLoginSessionState.consoleUserSessions(), !consoleUsers.isEmpty {
            if consoleUsers.contains(where: { $0.locked == true }) {
                return true
            }
            if consoleUsers.contains(where: { MirageLoginSessionState.isLoginWindowUserName($0.userName) }) {
                return true
            }
        }

        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            let lockedFlag = sessionDict["CGSSessionScreenIsLocked"] as? Bool
                ?? sessionDict["kCGSSessionScreenIsLocked"] as? Bool
                ?? sessionDict["kCGSessionScreenIsLocked"] as? Bool
                ?? false
            if lockedFlag {
                return true
            }
        }

        return false
    }

    private func isSystemSleeping() -> Bool {
        let rootDomainEntry = IORegistryEntryFromPath(
            kIOMainPortDefault,
            "IOPower:/IOPowerConnection/IOPMrootDomain"
        )

        guard rootDomainEntry != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(rootDomainEntry) }

        if let powerState = IORegistryEntryCreateCFProperty(
            rootDomainEntry,
            "CurrentPowerState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int {
            return powerState == 0
        }

        return false
    }

    private func registerNotifications() {
        registerNotification("com.apple.screenIsLocked") { [weak self] in
            Task { await self?.handleStateChange() }
        }
        registerNotification("com.apple.screenIsUnlocked") { [weak self] in
            Task { await self?.handleStateChange() }
        }
        registerNotification("com.apple.sessionDidLogin") { [weak self] in
            Task { await self?.handleStateChange() }
        }
        registerNotification("com.apple.sessionDidLogout") { [weak self] in
            Task { await self?.handleStateChange() }
        }
        registerNotification("com.apple.screensaver.didstop") { [weak self] in
            Task { await self?.handleStateChange() }
        }
        registerNotification("com.apple.screensaver.didstart") { [weak self] in
            Task { await self?.handleStateChange() }
        }
    }

    private func registerNotification(_ name: String, handler: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        let block: @convention(block) @Sendable (Int32) -> Void = { _ in
            handler()
        }

        let status = notify_register_dispatch(
            name,
            &token,
            notifyQueue,
            block
        )

        if status == notifyStatusOK {
            notifyTokens.append(token)
        } else {
            MirageLogger.error(.host, "Failed to register notification: \(name), status: \(status)")
        }
    }

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
