import MirageKit
#if os(macOS)

//
//  UnlockManager+Methods.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Unlock Methods

    /// Try to unlock via SkyLight session management (private API)
    func trySkyLightUnlock(username: String) -> Bool {
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
    func tryHIDUnlock(username: String?, password: String, requiresUsername: Bool) async -> Bool {
        await focusLoginField()

        if requiresUsername, let username {
            await typeStringViaCGEvent(username)
            postKeyEvent(keyCode: UInt16(kVK_Tab), shift: false)
            try? await Task.sleep(for: .milliseconds(80))
        }

        await typeStringViaCGEvent(password)
        postKeyEvent(keyCode: UInt16(kVK_Return), shift: false)

        return true
    }
}

#endif
