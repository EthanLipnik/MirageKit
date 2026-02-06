//
//  AppStreamManager+Sessions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager extensions.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation

public extension AppStreamManager {
    // MARK: - Session Management

    /// Start streaming an app to a client
    /// - Parameters:
    ///   - bundleIdentifier: The app to stream
    ///   - appName: Display name of the app
    ///   - appPath: Path to the app bundle
    ///   - clientID: The client receiving the stream
    ///   - clientName: Display name of the client
    /// - Returns: The created session, or nil if app is not available
    func startAppSession(
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String
    )
    -> MirageAppStreamSession? {
        let key = bundleIdentifier.lowercased()

        // Check if already streaming (and not expired reservation)
        if let existing = sessions[key], !existing.reservationExpired {
            logger.warning("App \(bundleIdentifier) already being streamed to \(existing.clientName)")
            return nil
        }

        let session = MirageAppStreamSession(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            appPath: appPath,
            clientID: clientID,
            clientName: clientName,
            state: .starting
        )

        sessions[key] = session
        logger.info("Started app session: \(appName) -> \(clientName)")

        // Start monitoring if not already running
        startMonitoringIfNeeded()

        return session
    }

    /// Update session state to streaming
    func markSessionStreaming(_ bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        sessions[key]?.state = .streaming
    }

    /// Add a window stream to an app session
    func addWindowToSession(
        bundleIdentifier: String,
        windowID: WindowID,
        streamID: StreamID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        let windowInfo = WindowStreamInfo(
            streamID: streamID,
            title: title,
            width: width,
            height: height,
            isResizable: isResizable
        )

        sessions[key]?.windowStreams[windowID] = windowInfo
        sessions[key]?.windowsInCooldown.removeValue(forKey: windowID)
        sessions[key]?.knownWindowIDs.insert(windowID)

        logger.debug("Added window \(windowID) to session \(bundleIdentifier)")
    }

    /// Remove a window from an app session (entering cooldown)
    func removeWindowFromSession(
        bundleIdentifier: String,
        windowID: WindowID,
        enterCooldown: Bool
    ) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        sessions[key]?.windowStreams.removeValue(forKey: windowID)

        if enterCooldown {
            let expiresAt = Date().addingTimeInterval(windowCooldownDuration)
            sessions[key]?.windowsInCooldown[windowID] = expiresAt
            logger.debug("Window \(windowID) entering cooldown until \(expiresAt)")
        }
    }

    /// Cancel cooldown for a window (e.g., user clicked "Close Now")
    func cancelCooldown(bundleIdentifier: String, windowID: WindowID) {
        let key = bundleIdentifier.lowercased()
        sessions[key]?.windowsInCooldown.removeValue(forKey: windowID)
    }

    /// Handle client disconnect (start reservation period)
    func handleClientDisconnect(clientID: UUID) {
        for (key, session) in sessions {
            if session.clientID == clientID {
                let reservationExpires = Date().addingTimeInterval(disconnectReservationDuration)
                sessions[key]?.state = .disconnected(reservationExpiresAt: reservationExpires)
                sessions[key]?.disconnectedAt = Date()
                logger.info("Client \(session.clientName) disconnected, reservation until \(reservationExpires)")
            }
        }
    }

    /// Handle client reconnect (resume session if within reservation)
    func handleClientReconnect(clientID: UUID) -> [String] {
        var resumedApps: [String] = []

        for (key, session) in sessions {
            if session.clientID == clientID, !session.reservationExpired {
                sessions[key]?.state = .streaming
                sessions[key]?.disconnectedAt = nil
                resumedApps.append(session.bundleIdentifier)
                logger.info("Client \(session.clientName) reconnected, resuming \(session.appName)")
            }
        }

        return resumedApps
    }

    /// End an app streaming session
    func endSession(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        if let session = sessions.removeValue(forKey: key) { logger.info("Ended app session: \(session.appName)") }

        // Stop monitoring if no more sessions
        if sessions.isEmpty { stopMonitoring() }
    }

    /// End all sessions for a client
    func endSessionsForClient(_ clientID: UUID) {
        let appsToRemove = sessions.values
            .filter { $0.clientID == clientID }
            .map(\.bundleIdentifier)

        for app in appsToRemove {
            endSession(bundleIdentifier: app)
        }
    }

    /// Get session for an app
    func getSession(bundleIdentifier: String) -> MirageAppStreamSession? {
        sessions[bundleIdentifier.lowercased()]
    }

    /// Get all active sessions
    func getAllSessions() -> [MirageAppStreamSession] {
        Array(sessions.values)
    }

    /// Get session containing a specific window
    func getSessionForWindow(_ windowID: WindowID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams[windowID] != nil || session.windowsInCooldown[windowID] != nil
        }
    }
}

#endif
