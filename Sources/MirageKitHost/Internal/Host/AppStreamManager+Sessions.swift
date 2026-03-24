//
//  AppStreamManager+Sessions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager session and slot bookkeeping.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation

public extension AppStreamManager {
    // MARK: - Session Management

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
    ///   - bitrateBudgetBps: Shared bitrate budget for visible slots.
    ///   - bitrateAllocationPolicy: Shared bitrate allocation policy across visible slots.
    /// - Returns: The created session, or nil if app is not available.
    @discardableResult
    func startAppSession(
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String,
        requestedDisplayResolution: CGSize,
        requestedClientScaleFactor: CGFloat?,
        maxVisibleSlots: Int,
        bitrateBudgetBps: Int?,
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy = .prioritizeActiveWindow
    ) -> MirageAppStreamSession? {
        let key = bundleIdentifier.lowercased()

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
            requestedDisplayResolution: requestedDisplayResolution,
            requestedClientScaleFactor: requestedClientScaleFactor,
            maxVisibleSlots: max(1, maxVisibleSlots),
            bitrateBudgetBps: bitrateBudgetBps,
            bitrateAllocationPolicy: bitrateAllocationPolicy,
            state: .starting
        )

        sessions[key] = session
        startupFailureStateByBundleID.removeValue(forKey: key)
        logger.info(
            "Started app session: \(appName) -> \(clientName), maxVisibleSlots=\(session.maxVisibleSlots), bitrateBudget=\(session.bitrateBudgetBps ?? 0), allocationPolicy=\(session.bitrateAllocationPolicy.rawValue)"
        )

        startMonitoringIfNeeded()
        return session
    }

    func setSessionBitrateBudget(bundleIdentifier: String, bitrateBudgetBps: Int?) {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return }
        session.bitrateBudgetBps = bitrateBudgetBps
        sessions[key] = session
    }

    func markSessionStreaming(_ bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        sessions[key]?.state = .streaming
    }

    /// Add or update a visible window stream in an app session.
    /// Returns assigned slot index when the window was tracked successfully.
    @discardableResult
    func addWindowToSession(
        bundleIdentifier: String,
        windowID: WindowID,
        streamID: StreamID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool,
        slotIndex: Int? = nil,
        isActive: Bool = true
    ) -> Int? {
        let key = bundleIdentifier.lowercased()
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
            slotIndex: assignedSlotIndex,
            title: title,
            width: width,
            height: height,
            isResizable: isResizable,
            isPaused: false,
            isActive: isActive
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
    /// Returns the prior window ID and slot index when successful.
    @discardableResult
    func replaceVisibleWindowForStream(
        bundleIdentifier: String,
        streamID: StreamID,
        newWindowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) -> (oldWindowID: WindowID, slotIndex: Int, isActive: Bool)? {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return nil }
        guard let oldEntry = session.windowStreams.first(where: { $0.value.streamID == streamID }) else {
            return nil
        }

        let slotIndex = oldEntry.value.slotIndex
        let isActive = oldEntry.value.isActive
        let oldWindowID = oldEntry.key
        session.windowStreams.removeValue(forKey: oldWindowID)
        session.hiddenWindows.removeValue(forKey: newWindowID)
        session.knownWindowIDs.insert(newWindowID)
        session.windowStreams[newWindowID] = WindowStreamInfo(
            streamID: streamID,
            slotIndex: slotIndex,
            title: title,
            width: width,
            height: height,
            isResizable: isResizable,
            isPaused: false,
            isActive: isActive
        )
        session.streamActivityByStreamID[streamID] = isActive
        sessions[key] = session

        return (oldWindowID, slotIndex, isActive)
    }

    /// Remove a tracked window from an app session (visible or hidden).
    /// Returns visible-window stream info when the removed window was currently visible.
    @discardableResult
    func removeWindowFromSession(
        bundleIdentifier: String,
        windowID: WindowID
    ) -> WindowStreamInfo? {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return nil }

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
        return removedVisibleInfo
    }

    func upsertHiddenWindow(
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return }
        guard session.windowStreams[windowID] == nil else { return }

        session.hiddenWindows[windowID] = AppStreamHiddenWindowInfo(
            title: title,
            width: width,
            height: height,
            isResizable: isResizable
        )
        session.knownWindowIDs.insert(windowID)
        sessions[key] = session
    }

    func hiddenWindowInfo(bundleIdentifier: String, windowID: WindowID) -> AppStreamHiddenWindowInfo? {
        sessions[bundleIdentifier.lowercased()]?.hiddenWindows[windowID]
    }

    func hiddenWindowIDs(bundleIdentifier: String) -> [WindowID] {
        guard let hiddenWindows = sessions[bundleIdentifier.lowercased()]?.hiddenWindows else { return [] }
        return Array(hiddenWindows.keys)
    }

    func hasTrackedWindow(bundleIdentifier: String, windowID: WindowID) -> Bool {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key] else { return false }
        return session.windowStreams[windowID] != nil || session.hiddenWindows[windowID] != nil
    }

    func hasVisibleSlotCapacity(bundleIdentifier: String) -> Bool {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key] else { return false }
        return session.windowStreams.count < session.maxVisibleSlots
    }

    func availableVisibleSlotIndex(bundleIdentifier: String) -> Int? {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key] else { return nil }
        let used = Set(session.windowStreams.values.map(\.slotIndex))
        return (0 ..< session.maxVisibleSlots).first { !used.contains($0) }
    }

    func slotIndexForStream(bundleIdentifier: String, streamID: StreamID) -> Int? {
        sessions[bundleIdentifier.lowercased()]?
            .windowStreams
            .first(where: { $0.value.streamID == streamID })?
            .value
            .slotIndex
    }

    func windowIDForStream(bundleIdentifier: String, streamID: StreamID) -> WindowID? {
        sessions[bundleIdentifier.lowercased()]?
            .windowStreams
            .first(where: { $0.value.streamID == streamID })?
            .key
    }

    func streamIDForWindow(bundleIdentifier: String, windowID: WindowID) -> StreamID? {
        sessions[bundleIdentifier.lowercased()]?.windowStreams[windowID]?.streamID
    }

    func markStreamActivity(bundleIdentifier: String, streamID: StreamID, isActive: Bool) {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return }
        session.streamActivityByStreamID[streamID] = isActive
        if let windowID = session.windowStreams.first(where: { $0.value.streamID == streamID })?.key,
           var info = session.windowStreams[windowID] {
            info.isActive = isActive
            info.isPaused = !isActive
            session.windowStreams[windowID] = info
        }
        sessions[key] = session
    }

    func streamActivity(bundleIdentifier: String, streamID: StreamID) -> Bool? {
        sessions[bundleIdentifier.lowercased()]?.streamActivityByStreamID[streamID]
    }

    func streamActivityMap(bundleIdentifier: String) -> [StreamID: Bool] {
        sessions[bundleIdentifier.lowercased()]?.streamActivityByStreamID ?? [:]
    }

    func streamBitrateTargets(bundleIdentifier: String) -> [StreamID: Int] {
        sessions[bundleIdentifier.lowercased()]?.streamBitrateTargetsByStreamID ?? [:]
    }

    func setStreamBitrateTargets(bundleIdentifier: String, targets: [StreamID: Int]) {
        let key = bundleIdentifier.lowercased()
        guard var session = sessions[key] else { return }
        session.streamBitrateTargetsByStreamID = targets
        sessions[key] = session
    }

    func sharedBitrateBudget(bundleIdentifier: String) -> Int? {
        sessions[bundleIdentifier.lowercased()]?.bitrateBudgetBps
    }

    func maxVisibleSlots(bundleIdentifier: String) -> Int {
        sessions[bundleIdentifier.lowercased()]?.maxVisibleSlots ?? 1
    }

    func inventoryMessage(bundleIdentifier: String) -> AppWindowInventoryMessage? {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key] else { return nil }

        let slots: [AppWindowInventoryMessage.Slot] = session.windowStreams
            .map { windowID, info in
                AppWindowInventoryMessage.Slot(
                    slotIndex: info.slotIndex,
                    streamID: info.streamID,
                    window: AppWindowInventoryMessage.WindowMetadata(
                        windowID: windowID,
                        title: info.title,
                        width: info.width,
                        height: info.height,
                        isResizable: info.isResizable
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.slotIndex != rhs.slotIndex { return lhs.slotIndex < rhs.slotIndex }
                return lhs.streamID < rhs.streamID
            }

        let hiddenWindows: [AppWindowInventoryMessage.WindowMetadata] = session.hiddenWindows
            .map { windowID, info in
                AppWindowInventoryMessage.WindowMetadata(
                    windowID: windowID,
                    title: info.title,
                    width: info.width,
                    height: info.height,
                    isResizable: info.isResizable
                )
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rhsTitle = rhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if lhsTitle.caseInsensitiveCompare(rhsTitle) != .orderedSame {
                    return lhsTitle.caseInsensitiveCompare(rhsTitle) == .orderedAscending
                }
                return lhs.windowID < rhs.windowID
            }

        return AppWindowInventoryMessage(
            bundleIdentifier: session.bundleIdentifier,
            maxVisibleSlots: session.maxVisibleSlots,
            slots: slots,
            hiddenWindows: hiddenWindows
        )
    }

    /// Handle client disconnect (start reservation period).
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

    /// Handle client reconnect (resume session if within reservation).
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

    /// End an app streaming session.
    func endSession(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        if let session = sessions.removeValue(forKey: key) { logger.info("Ended app session: \(session.appName)") }
        startupFailureStateByBundleID.removeValue(forKey: key)
        knownAuxiliaryWindowIDs.removeValue(forKey: key)

        if sessions.isEmpty { stopMonitoring() }
    }

    /// End all sessions for a client.
    func endSessionsForClient(_ clientID: UUID) {
        let appsToRemove = sessions.values
            .filter { $0.clientID == clientID }
            .map(\.bundleIdentifier)

        for app in appsToRemove {
            endSession(bundleIdentifier: app)
        }
    }

    /// End any sessions that belong to clients that are no longer connected.
    func endSessionsNotOwned(by connectedClientIDs: Set<UUID>) {
        let orphanedApps = sessions.values
            .filter { !connectedClientIDs.contains($0.clientID) }
            .map(\.bundleIdentifier)

        for app in orphanedApps {
            endSession(bundleIdentifier: app)
        }
    }

    /// Get session for an app.
    func getSession(bundleIdentifier: String) -> MirageAppStreamSession? {
        sessions[bundleIdentifier.lowercased()]
    }

    /// Get all active sessions.
    func getAllSessions() -> [MirageAppStreamSession] {
        Array(sessions.values)
    }

    /// Get session containing a specific window.
    func getSessionForWindow(_ windowID: WindowID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams[windowID] != nil
        }
    }

    /// Get session containing a specific stream ID.
    func getSessionForStreamID(_ streamID: StreamID) -> MirageAppStreamSession? {
        sessions.values.first { session in
            session.windowStreams.values.contains { $0.streamID == streamID }
        }
    }

    private func resolvedSlotIndex(
        session: MirageAppStreamSession,
        streamID: StreamID,
        preferredSlotIndex: Int?
    ) -> Int? {
        if let existingSlot = session.windowStreams
            .first(where: { $0.value.streamID == streamID })?
            .value
            .slotIndex {
            return existingSlot
        }

        let usedSlots = Set(session.windowStreams.values.map(\.slotIndex))
        if let preferredSlotIndex,
           preferredSlotIndex >= 0,
           preferredSlotIndex < session.maxVisibleSlots,
           !usedSlots.contains(preferredSlotIndex) {
            return preferredSlotIndex
        }

        return (0 ..< session.maxVisibleSlots).first { !usedSlots.contains($0) }
    }
}

#endif
