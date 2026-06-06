//
//  AppStreamManager+Sessions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager session and slot bookkeeping.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
import AppKit
import Foundation

extension AppStreamManager {
    // MARK: - Session Management

    /// Stable dictionary key for app-stream session state.
    nonisolated func appSessionKey(for bundleIdentifier: String) -> String {
        bundleIdentifier.lowercased()
    }

    /// Start streaming an app to a client.
    /// - Parameters:
    ///   - bundleIdentifier: The app to stream.
    ///   - appName: Display name of the app.
    ///   - appPath: Path to the app bundle.
    ///   - clientID: The client receiving the stream.
    ///   - clientName: Display name of the client.
    ///   - requestedDisplayResolution: Requested logical display resolution in points.
    ///   - requestedClientScaleFactor: Optional client scale-factor override.
    ///   - maxVisibleSlots: Maximum concurrent visible windows for this session.
    ///   - bitrateBudgetBps: Client-wide app atlas bitrate budget.
    /// - Returns: The created session, or nil if app is not available.
    func startAppSession(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String,
        requestedDisplayResolution: CGSize,
        requestedClientScaleFactor: CGFloat?,
        maxVisibleSlots: Int,
        bitrateBudgetBps: Int?
    ) -> MirageAppStreamSession? {
        let key = appSessionKey(for: bundleIdentifier)

        if let existing = sessions[key], !existing.reservationExpired {
            logger.warning("App \(bundleIdentifier) already being streamed to \(existing.clientName)")
            return nil
        }

        let session = MirageAppStreamSession(
            id: id,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            appPath: appPath,
            clientID: clientID,
            clientName: clientName,
            requestedDisplayResolution: requestedDisplayResolution,
            requestedClientScaleFactor: requestedClientScaleFactor,
            maxVisibleSlots: max(1, maxVisibleSlots),
            bitrateBudgetBps: bitrateBudgetBps,
            state: .starting
        )

        sessions[key] = session
        startupFailureStateByBundleID.removeValue(forKey: key)
        logger.info(
            "Started app session: \(appName) -> \(clientName), maxVisibleSlots=\(session.maxVisibleSlots), atlasBitrateBudget=\(session.bitrateBudgetBps ?? 0)"
        )

        startMonitoringIfNeeded()
        return session
    }

    /// Raises the maximum number of visible slots for an existing app session.
    func raiseMaxVisibleSlots(bundleIdentifier: String, to requestedSlots: Int) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }
        let resolvedSlots = max(1, requestedSlots)
        guard resolvedSlots > session.maxVisibleSlots else { return }
        session.maxVisibleSlots = resolvedSlots
        sessions[key] = session
        logger.info("Raised app session slot cap for \(bundleIdentifier) to \(resolvedSlots)")
    }

    /// Marks an app session as fully streaming after startup completes.
    func markSessionStreaming(_ bundleIdentifier: String) {
        let key = appSessionKey(for: bundleIdentifier)
        sessions[key]?.state = .streaming
    }

    /// Returns the app session with the requested app-session ID.
    func session(appSessionID: UUID) -> MirageAppStreamSession? {
        sessions.values.first { $0.id == appSessionID }
    }

    /// Ends the app session with the requested app-session ID.
    func endSession(appSessionID: UUID) {
        guard let entry = sessions.first(where: { $0.value.id == appSessionID }) else { return }
        sessions.removeValue(forKey: entry.key)
        startupFailureStateByBundleID.removeValue(forKey: entry.key)
        logger.info("Ended app session: \(entry.value.appName)")
    }

    /// Add or update a visible window stream in an app session.
    /// Returns assigned slot index when the window was tracked successfully.
    func addWindowToSession(
        bundleIdentifier: String,
        windowID: WindowID,
        streamID: StreamID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool,
        slotIndex: Int? = nil,
        isActive: Bool = true,
        capturedClusterWindowIDs: [WindowID] = [],
        mediaStreamID: StreamID,
        atlasRegion: MirageMedia.MirageAppAtlasRegion? = nil
    ) -> Int? {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return nil }

        if let existingInfo = session.windowStreams[windowID],
           existingInfo.streamID != streamID {
            logger.error(
                "Refusing duplicate window binding for window \(windowID) in session \(bundleIdentifier); existing stream \(existingInfo.streamID), new stream \(streamID)"
            )
            return nil
        }

        let assignedSlotIndex = resolvedSlotIndex(
            session: session,
            streamID: streamID,
            preferredSlotIndex: slotIndex
        )
        guard let assignedSlotIndex else {
            logger.debug("No available visible slot for window \(windowID) in session \(bundleIdentifier)")
            return nil
        }

        // Keep one binding per stream ID.
        for (existingWindowID, info) in session.windowStreams where info.streamID == streamID && existingWindowID != windowID {
            session.windowStreams.removeValue(forKey: existingWindowID)
        }

        let windowInfo = WindowStreamInfo(
            streamID: streamID,
            mediaStreamID: mediaStreamID,
            slotIndex: assignedSlotIndex,
            title: title,
            width: width,
            height: height,
            isResizable: isResizable,
            isPaused: false,
            isActive: isActive,
            capturedClusterWindowIDs: capturedClusterWindowIDs,
            atlasRegion: atlasRegion
        )

        session.windowStreams[windowID] = windowInfo
        session.hiddenWindows.removeValue(forKey: windowID)
        session.knownWindowIDs.insert(windowID)
        session.streamActivityByStreamID[streamID] = isActive
        sessions[key] = session

        logger.debug("Added window \(windowID) to slot \(assignedSlotIndex) in session \(bundleIdentifier)")
        return assignedSlotIndex
    }

    /// Replace the window metadata bound to an existing visible stream ID.
    func replaceVisibleWindowForStream(
        bundleIdentifier: String,
        streamID: StreamID,
        newWindowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool,
        capturedClusterWindowIDs: [WindowID] = [],
        mediaStreamID: StreamID,
        atlasRegion: MirageMedia.MirageAppAtlasRegion? = nil
    ) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }
        guard let oldEntry = visibleWindowBinding(in: session, streamID: streamID) else { return }

        let slotIndex = oldEntry.info.slotIndex
        let isActive = oldEntry.info.isActive
        let oldWindowID = oldEntry.windowID
        session.windowStreams.removeValue(forKey: oldWindowID)
        session.hiddenWindows.removeValue(forKey: newWindowID)
        session.knownWindowIDs.insert(newWindowID)
        session.windowStreams[newWindowID] = WindowStreamInfo(
            streamID: streamID,
            mediaStreamID: mediaStreamID,
            slotIndex: slotIndex,
            title: title,
            width: width,
            height: height,
            isResizable: isResizable,
            isPaused: false,
            isActive: isActive,
            capturedClusterWindowIDs: capturedClusterWindowIDs,
            atlasRegion: atlasRegion ?? oldEntry.info.atlasRegion
        )
        session.streamActivityByStreamID[streamID] = isActive
        sessions[key] = session
    }

    /// Remove a tracked window from an app session (visible or hidden).
    func removeWindowFromSession(
        bundleIdentifier: String,
        windowID: WindowID
    ) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }

        let removedVisibleInfo = session.windowStreams.removeValue(forKey: windowID)
        session.hiddenWindows.removeValue(forKey: windowID)

        if let removedVisibleInfo {
            let removedStreamID = removedVisibleInfo.streamID
            let hasRemainingBindingForStream = session.windowStreams.values.contains { $0.streamID == removedStreamID }
            if !hasRemainingBindingForStream {
                session.streamActivityByStreamID.removeValue(forKey: removedStreamID)
                session.streamBitrateTargetsByStreamID.removeValue(forKey: removedStreamID)
            }
            logger.debug("Removed visible window \(windowID) from session \(bundleIdentifier)")
        } else {
            logger.debug("Removed hidden window \(windowID) from session \(bundleIdentifier)")
        }

        sessions[key] = session
    }

    /// Ends an app streaming session.
    func endSession(bundleIdentifier: String) {
        let key = appSessionKey(for: bundleIdentifier)
        if let session = sessions.removeValue(forKey: key) { logger.info("Ended app session: \(session.appName)") }
        startupFailureStateByBundleID.removeValue(forKey: key)
        knownAuxiliaryWindowIDs.removeValue(forKey: key)

        if sessions.isEmpty { stopMonitoring() }
    }

    /// Ends all sessions for a client.
    func endSessionsForClient(_ clientID: UUID) {
        let appsToRemove = sessions.values
            .filter { $0.clientID == clientID }
            .map(\.bundleIdentifier)

        for app in appsToRemove {
            endSession(bundleIdentifier: app)
        }
    }

    /// Ends any sessions that belong to clients that are no longer connected.
    func endSessionsNotOwned(by connectedClientIDs: Set<UUID>) {
        let orphanedApps = sessions.values
            .filter { !connectedClientIDs.contains($0.clientID) }
            .map(\.bundleIdentifier)

        for app in orphanedApps {
            endSession(bundleIdentifier: app)
        }
    }

    /// Returns the session for an app.
    func session(bundleIdentifier: String) -> MirageAppStreamSession? {
        sessions[appSessionKey(for: bundleIdentifier)]
    }

    /// Active app streaming sessions.
    func allSessions() -> [MirageAppStreamSession] {
        Array(sessions.values)
    }

    /// Session containing a specific window.
    func sessionForWindow(_ windowID: WindowID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams[windowID] != nil
        }
    }

    /// Session containing a specific stream ID.
    func sessionForStreamID(_ streamID: StreamID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams.values.contains { $0.streamID == streamID }
        }
    }

}

#endif
