//
//  MirageLoginSessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation

#if os(macOS)
import CoreGraphics
import IOKit

/// Reads macOS login-window and console-session state used by bootstrap unlock flows.
package enum MirageLoginSessionState {
    /// A single entry from the `IOConsoleUsers` registry array.
    package struct ConsoleUserSession {
        package let userName: String?
        package let loginDone: Bool?
        package let onConsole: Bool?
        package let locked: Bool?
    }

    /// Returns true for system pseudo-users that represent the login window.
    package static func isLoginWindowUserName(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "loginwindow" || normalized == "loginwindow.app" || normalized == "login window"
    }

    /// Reads the console-user sessions published by IOKit.
    package static func consoleUserSessions() -> [ConsoleUserSession]? {
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

    /// Returns the `/dev/console` owner, falling back to `NSUserName()` when `stat` fails.
    package static func currentConsoleUser(ignoringRoot: Bool = false) -> String? {
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
               !(ignoringRoot && user == "root") {
                return user
            }
        } catch {
            return NSUserName()
        }

        return NSUserName()
    }

    /// Returns true when the login window or screen saver owns a shielding-level window.
    package static func isLoginWindowVisible(includeOffscreenWindows: Bool = false) -> Bool {
        containsLoginWindow(in: .optionOnScreenOnly) ||
            (includeOffscreenWindows && containsLoginWindow(in: .optionAll))
    }

    private static func containsLoginWindow(in options: CGWindowListOption) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let shieldingLevel = CGShieldingWindowLevel()
        let screenSaverLevel = CGWindowLevelForKey(.screenSaverWindow)

        for window in windows {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0

            if ownerName == "loginwindow" || ownerName == "LoginWindow" {
                if layer >= shieldingLevel { return true }
            }

            if ownerName == "ScreenSaverEngine", layer >= screenSaverLevel { return true }
        }

        return false
    }
}
#endif
