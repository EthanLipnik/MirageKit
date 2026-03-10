import Loom
#if os(macOS)

//
//  UnlockManager+API.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Unlock API

    /// Attempt to unlock the Mac using Authorization Services
    /// - Parameters:
    ///   - username: Username to unlock (required when at login screen)
    ///   - password: Password to verify and use for unlock
    ///   - requiresUserIdentifier: Whether login screen requires a username entry
    ///   - clientID: Client ID for rate limiting
    /// - Returns: Result of the unlock attempt with retry information
    func attemptUnlock(
        username: String?,
        password: String,
        requiresUserIdentifier: Bool,
        clientID: UUID
    )
    async -> (result: UnlockResult, retriesRemaining: Int?, retryAfterSeconds: Int?) {
        // Check rate limit
        let limit = checkRateLimit(clientID: clientID)
        if limit.isLimited { return (.failure(.rateLimited, "Too many attempts. Try again later."), limit.remaining, limit.retryAfter) }

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

        // Record this attempt
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

        // Step 1: Verify credentials using Authorization Services
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

        defer { Task { await self.releaseDisplayAssertion() } }

        // Step 2: Wake display
        wakeDisplayNonBlocking()
        try? await Task.sleep(for: .milliseconds(400))

        // Loginwindow can appear after the display wakes on headless Macs.
        // A second readiness check reduces queued HID events.
        let loginReadyAfterWake = await waitForLoginWindowReady(timeout: 6.0)
        if !loginReadyAfterWake { MirageLogger.host("Login window not detected after wake; continuing with non-HID unlock checks") }

        // Step 3: Try multiple unlock methods
        var unlocked = false

        // Method 1: Try session switch via SkyLight
        MirageLogger.host("Trying SkyLight session switch...")
        let skylightResult = trySkyLightUnlock(username: resolvedUsername)
        if skylightResult {
            try? await Task.sleep(for: .milliseconds(300))
            if await sessionMonitor.refreshState() == .ready { unlocked = true }
        }

        // Method 2: HID-level typing (login screen or lock screen)
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

        if !unlocked {
            MirageLogger.host("Unlock methods did not activate session")
            return (
                .failure(.timeout, "Unable to reach lock screen for credential entry. Try again."),
                remaining,
                nil
            )
        }

        // Poll for unlock completion instead of fixed wait
        // This handles cases where unlock takes longer than expected on headless Macs
        let newState = await pollForUnlockCompletion(timeout: 25.0, pollInterval: 0.35)

        if newState == .ready {
            MirageLogger.host("Unlock successful!")
            return (.success, remaining, nil)
        } else {
            // Even though password was correct, unlock might have failed
            // This can happen if keyboard simulation didn't work or loginwindow didn't receive events
            MirageLogger.host("Password correct but session still locked (state: \(newState))")
            return (.failure(.invalidCredentials, "Password verified but unlock failed. Try again."), remaining, nil)
        }
    }
}

#endif
