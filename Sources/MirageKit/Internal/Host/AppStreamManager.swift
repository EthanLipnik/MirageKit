//
//  AppStreamManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import OSLog
import ScreenCaptureKit

/// Manages app-centric streaming sessions on the host
/// Tracks which apps are being streamed to which clients,
/// handles window monitoring, cooldowns, and exclusive access
public actor AppStreamManager {
    private let logger = Logger(subsystem: "MirageKit", category: "AppStreamManager")

    /// Active app streaming sessions keyed by bundle identifier
    private var sessions: [String: MirageAppStreamSession] = [:]

    /// Cooldown duration when host closes a window (seconds)
    public var windowCooldownDuration: TimeInterval = 10.0

    /// Reservation duration after unexpected disconnect (seconds)
    public var disconnectReservationDuration: TimeInterval = 30.0

    /// Callbacks for notifying the host service of events
    private var _onNewWindowDetected: (@Sendable (String, SCWindow) async -> Void)?
    private var _onWindowClosed: (@Sendable (String, WindowID) async -> Void)?
    private var _onAppTerminated: (@Sendable (String) async -> Void)?
    private var _onCooldownExpired: (@Sendable (String, WindowID) async -> Void)?

    /// Setters for callbacks (allows setting from outside the actor)
    public func setOnNewWindowDetected(_ callback: @escaping @Sendable (String, SCWindow) async -> Void) {
        _onNewWindowDetected = callback
    }

    public func setOnWindowClosed(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        _onWindowClosed = callback
    }

    public func setOnAppTerminated(_ callback: @escaping @Sendable (String) async -> Void) {
        _onAppTerminated = callback
    }

    public func setOnCooldownExpired(_ callback: @escaping @Sendable (String, WindowID) async -> Void) {
        _onCooldownExpired = callback
    }

    /// Application scanner for getting installed apps
    private let applicationScanner: ApplicationScanner

    /// Timer for periodic window monitoring
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false

    public init() {
        self.applicationScanner = ApplicationScanner()
    }

    // MARK: - App List

    /// Get list of installed apps with streaming status
    public func getInstalledApps(includeIcons: Bool = true) async -> [MirageInstalledApp] {
        let runningApps = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier?.lowercased() }
        )

        let streamingApps = Set(sessions.keys.map { $0.lowercased() })

        return await applicationScanner.scanInstalledApps(
            includeIcons: includeIcons,
            runningApps: runningApps,
            streamingApps: streamingApps
        )
    }

    /// Check if an app is available for streaming (not already being streamed)
    public func isAppAvailableForStreaming(_ bundleIdentifier: String) -> Bool {
        let key = bundleIdentifier.lowercased()

        guard let session = sessions[key] else {
            return true // Not being streamed
        }

        // Check if reservation has expired
        if session.reservationExpired {
            return true
        }

        return false
    }

    /// Get the client ID that has exclusive access to an app (if any)
    public func clientStreamingApp(_ bundleIdentifier: String) -> UUID? {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key], !session.reservationExpired else {
            return nil
        }
        return session.clientID
    }

    // MARK: - Session Management

    /// Start streaming an app to a client
    /// - Parameters:
    ///   - bundleIdentifier: The app to stream
    ///   - appName: Display name of the app
    ///   - appPath: Path to the app bundle
    ///   - clientID: The client receiving the stream
    ///   - clientName: Display name of the client
    /// - Returns: The created session, or nil if app is not available
    public func startAppSession(
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String
    ) -> MirageAppStreamSession? {
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
    public func markSessionStreaming(_ bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        sessions[key]?.state = .streaming
    }

    /// Add a window stream to an app session
    public func addWindowToSession(
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
    public func removeWindowFromSession(
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
    public func cancelCooldown(bundleIdentifier: String, windowID: WindowID) {
        let key = bundleIdentifier.lowercased()
        sessions[key]?.windowsInCooldown.removeValue(forKey: windowID)
    }

    /// Handle client disconnect (start reservation period)
    public func handleClientDisconnect(clientID: UUID) {
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
    public func handleClientReconnect(clientID: UUID) -> [String] {
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
    public func endSession(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        if let session = sessions.removeValue(forKey: key) {
            logger.info("Ended app session: \(session.appName)")
        }

        // Stop monitoring if no more sessions
        if sessions.isEmpty {
            stopMonitoring()
        }
    }

    /// End all sessions for a client
    public func endSessionsForClient(_ clientID: UUID) {
        let appsToRemove = sessions.values
            .filter { $0.clientID == clientID }
            .map { $0.bundleIdentifier }

        for app in appsToRemove {
            endSession(bundleIdentifier: app)
        }
    }

    /// Get session for an app
    public func getSession(bundleIdentifier: String) -> MirageAppStreamSession? {
        sessions[bundleIdentifier.lowercased()]
    }

    /// Get all active sessions
    public func getAllSessions() -> [MirageAppStreamSession] {
        Array(sessions.values)
    }

    /// Get session containing a specific window
    public func getSessionForWindow(_ windowID: WindowID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams[windowID] != nil || session.windowsInCooldown[windowID] != nil
        }
    }

    // MARK: - Stream Pause/Resume

    /// Pause a stream (client window lost focus)
    public func pauseStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        for (windowID, var info) in sessions[key]?.windowStreams ?? [:] {
            if info.streamID == streamID {
                info.isPaused = true
                sessions[key]?.windowStreams[windowID] = info
                logger.debug("Paused stream \(streamID) for \(bundleIdentifier)")
                break
            }
        }
    }

    /// Resume a stream (client window regained focus)
    public func resumeStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        for (windowID, var info) in sessions[key]?.windowStreams ?? [:] {
            if info.streamID == streamID {
                info.isPaused = false
                sessions[key]?.windowStreams[windowID] = info
                logger.debug("Resumed stream \(streamID) for \(bundleIdentifier)")
                break
            }
        }
    }

    // MARK: - Window Monitoring

    private func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitoringTask = Task { [weak self] in
            await self?.monitoringLoop()
        }

        logger.debug("Started window monitoring")
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        logger.debug("Stopped window monitoring")
    }

    private func monitoringLoop() async {
        while !Task.isCancelled && isMonitoring {
            await checkForWindowChanges()
            await checkForExpiredCooldowns()
            await checkForExpiredReservations()

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func checkForWindowChanges() async {
        guard !sessions.isEmpty else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            for (bundleID, var session) in sessions {
                guard case .streaming = session.state else { continue }

                // Get windows for this app
                let appWindows = content.windows.filter { window in
                    guard let app = window.owningApplication else { return false }
                    return app.bundleIdentifier.lowercased() == bundleID
                }

                // Filter to valid windows (using existing filtering criteria)
                let validWindows = appWindows.filter { window in
                    let hasMinSize = window.frame.width >= 200 && window.frame.height >= 150
                    let isNormalLayer = window.windowLayer == 0
                    let hasOwner = window.owningApplication != nil
                    return hasMinSize && isNormalLayer && hasOwner
                }

                let currentStreamingIDs = Set(session.windowStreams.keys)
                let currentValidIDs = Set(validWindows.map { WindowID($0.windowID) })

                // Check for new windows - only windows we haven't seen before AND are on-screen
                var sessionUpdated = false
                for window in validWindows {
                    let windowID = WindowID(window.windowID)
                    // Only notify for truly NEW windows (not seen before) that are on-screen
                    if !session.knownWindowIDs.contains(windowID) && window.isOnScreen {
                        logger.info("New window detected: \(window.title ?? "untitled") for \(bundleID)")
                        session.knownWindowIDs.insert(windowID)
                        sessionUpdated = true
                        await _onNewWindowDetected?(bundleID, window)
                    }
                }

                // Update session if we added new known windows
                if sessionUpdated {
                    sessions[bundleID] = session
                }

                // Check for closed windows (only windows that were actively streaming)
                for windowID in currentStreamingIDs {
                    if !currentValidIDs.contains(windowID) {
                        logger.info("Window closed: \(windowID) for \(bundleID)")
                        await _onWindowClosed?(bundleID, windowID)
                    }
                }

                // Check if app terminated (no windows and app not running)
                if validWindows.isEmpty {
                    let appIsRunning = NSWorkspace.shared.runningApplications.contains { app in
                        app.bundleIdentifier?.lowercased() == bundleID
                    }

                    if !appIsRunning && session.hasActiveWindows {
                        logger.info("App terminated: \(bundleID)")
                        await _onAppTerminated?(bundleID)
                    }
                }
            }
        } catch {
            logger.error("Failed to check window changes: \(error)")
        }
    }

    private func checkForExpiredCooldowns() async {
        for (bundleID, session) in sessions {
            for windowID in session.expiredCooldowns {
                sessions[bundleID]?.windowsInCooldown.removeValue(forKey: windowID)
                logger.debug("Cooldown expired for window \(windowID) in \(bundleID)")
                await _onCooldownExpired?(bundleID, windowID)
            }
        }
    }

    private func checkForExpiredReservations() async {
        let expiredSessions = sessions.filter { $0.value.reservationExpired }

        for (bundleID, session) in expiredSessions {
            logger.info("Reservation expired for \(session.appName), ending session")
            sessions.removeValue(forKey: bundleID)
        }

        // Stop monitoring if no more sessions
        if sessions.isEmpty {
            stopMonitoring()
        }
    }

    // MARK: - App Launching

    /// Launch an app if not running
    /// - Parameter bundleIdentifier: The app to launch
    /// - Returns: True if app was launched or already running
    public func launchAppIfNeeded(_ bundleIdentifier: String, path: String) async -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }

        if isRunning {
            logger.debug("App \(bundleIdentifier) already running")
            return true
        }

        do {
            let url = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            logger.info("Launched app: \(bundleIdentifier)")
            return true
        } catch {
            logger.error("Failed to launch app \(bundleIdentifier): \(error)")
            return false
        }
    }

    /// Request a new window from an app (for apps that are running but have no windows)
    public func requestNewWindow(bundleIdentifier: String) async {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) else {
            return
        }

        // Activate the app first
        app.activate()

        // Try to send "New Window" command via Apple Events
        let script = """
        tell application id "\(bundleIdentifier)"
            try
                make new document
            on error
                try
                    activate
                end try
            end try
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                logger.warning("Apple Script error requesting new window: \(error)")
            }
        }
    }
}

// MARK: - Window Resizability Check

public extension AppStreamManager {
    /// Check if a window is resizable using Accessibility API
    /// Checks if the kAXSizeAttribute is settable for the window
    nonisolated func checkWindowResizability(windowID: WindowID, processID: Int32) -> Bool {
        let appElement = AXUIElementCreateApplication(processID)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return true // Assume resizable if we can't check
        }

        // For simplicity, check the first window - in practice we'd need to match by window ID
        // which requires private API. Most apps have consistent resizability across windows.
        guard let axWindow = windows.first else {
            return true
        }

        // Check if size attribute is settable
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSettable)

        if result == .success {
            return isSettable.boolValue
        }

        return true // Default to resizable
    }
}
#endif
