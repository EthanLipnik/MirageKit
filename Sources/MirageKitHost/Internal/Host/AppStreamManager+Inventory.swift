//
//  AppStreamManager+Inventory.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  App-stream window inventory queries and client-facing snapshots.
//

import MirageKit

#if os(macOS)
import Foundation

extension AppStreamManager {
    /// Inserts or updates a hidden window in an app session inventory.
    func upsertHiddenWindow(
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        let key = appSessionKey(for: bundleIdentifier)
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

    /// Returns hidden-window metadata for an app session.
    func hiddenWindowInfo(bundleIdentifier: String, windowID: WindowID) -> AppStreamHiddenWindowInfo? {
        sessions[appSessionKey(for: bundleIdentifier)]?.hiddenWindows[windowID]
    }

    /// Returns whether a window is tracked as visible or hidden for an app session.
    func hasTrackedWindow(bundleIdentifier: String, windowID: WindowID) -> Bool {
        let key = appSessionKey(for: bundleIdentifier)
        guard let session = sessions[key] else { return false }
        return session.windowStreams[windowID] != nil || session.hiddenWindows[windowID] != nil
    }

    /// Returns whether an app session can show another visible window.
    func hasVisibleSlotCapacity(bundleIdentifier: String) -> Bool {
        let key = appSessionKey(for: bundleIdentifier)
        guard let session = sessions[key] else { return false }
        return session.windowStreams.count < session.maxVisibleSlots
    }

    /// Returns the first unused visible slot index for an app session.
    func availableVisibleSlotIndex(bundleIdentifier: String) -> Int? {
        let key = appSessionKey(for: bundleIdentifier)
        guard let session = sessions[key] else { return nil }
        return firstAvailableVisibleSlot(in: session)
    }

    /// Returns the visible window ID bound to a stream ID.
    func windowIDForStream(bundleIdentifier: String, streamID: StreamID) -> WindowID? {
        guard let session = sessions[appSessionKey(for: bundleIdentifier)] else { return nil }
        return visibleWindowBinding(in: session, streamID: streamID)?.windowID
    }

    /// Returns the stream ID bound to a visible window ID.
    func streamIDForWindow(bundleIdentifier: String, windowID: WindowID) -> StreamID? {
        sessions[appSessionKey(for: bundleIdentifier)]?.windowStreams[windowID]?.streamID
    }

    /// Returns the visible stream that captures a clustered child window.
    func streamIDForCapturedClusterWindow(
        bundleIdentifier: String,
        windowID: WindowID
    ) -> StreamID? {
        sessions[appSessionKey(for: bundleIdentifier)]?.windowStreams.values.first { info in
            info.capturedClusterWindowIDs.contains(windowID)
        }?.streamID
    }

    /// Updates clustered window IDs captured by a visible stream.
    func setCapturedClusterWindowIDs(
        bundleIdentifier: String,
        streamID: StreamID,
        capturedClusterWindowIDs: [WindowID]
    ) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }
        guard var binding = visibleWindowBinding(in: session, streamID: streamID) else { return }

        binding.info.capturedClusterWindowIDs = capturedClusterWindowIDs
        session.windowStreams[binding.windowID] = binding.info
        sessions[key] = session
    }

    /// Updates active/paused state for a stream in an app session.
    func markStreamActivity(bundleIdentifier: String, streamID: StreamID, isActive: Bool) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }
        session.streamActivityByStreamID[streamID] = isActive
        if var binding = visibleWindowBinding(in: session, streamID: streamID) {
            binding.info.isActive = isActive
            binding.info.isPaused = !isActive
            session.windowStreams[binding.windowID] = binding.info
        }
        sessions[key] = session
    }

    /// Returns active/paused state for a stream in an app session.
    func streamActivity(bundleIdentifier: String, streamID: StreamID) -> Bool? {
        sessions[appSessionKey(for: bundleIdentifier)]?.streamActivityByStreamID[streamID]
    }

    /// Returns all stream activity state for an app session.
    func streamActivityMap(bundleIdentifier: String) -> [StreamID: Bool] {
        sessions[appSessionKey(for: bundleIdentifier)]?.streamActivityByStreamID ?? [:]
    }

    /// Stores current bitrate targets by stream ID for an app session.
    func setStreamBitrateTargets(bundleIdentifier: String, targets: [StreamID: Int]) {
        let key = appSessionKey(for: bundleIdentifier)
        guard var session = sessions[key] else { return }
        session.streamBitrateTargetsByStreamID = targets
        sessions[key] = session
    }

    /// Returns the shared bitrate budget for an app session.
    func sharedBitrateBudget(bundleIdentifier: String) -> Int? {
        sessions[appSessionKey(for: bundleIdentifier)]?.bitrateBudgetBps
    }

    /// Builds a client-facing inventory message for visible and hidden app windows.
    func inventoryMessage(bundleIdentifier: String) -> AppWindowInventoryMessage? {
        let key = appSessionKey(for: bundleIdentifier)
        guard let session = sessions[key] else { return nil }

        let slots: [AppWindowInventoryMessage.Slot] = session.windowStreams
            .map { windowID, info in
                AppWindowInventoryMessage.Slot(
                    slotIndex: info.slotIndex,
                    streamID: info.streamID,
                    mediaStreamID: info.mediaStreamID,
                    window: AppWindowInventoryMessage.WindowMetadata(
                        windowID: windowID,
                        title: info.title,
                        width: info.width,
                        height: info.height,
                        isResizable: info.isResizable
                    ),
                    atlasRegion: info.atlasRegion
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
            .sorted(by: hiddenInventoryWindowPrecedes)

        return AppWindowInventoryMessage(
            bundleIdentifier: session.bundleIdentifier,
            appSessionID: session.id,
            maxVisibleSlots: session.maxVisibleSlots,
            slots: slots,
            hiddenWindows: hiddenWindows
        )
    }
}
#endif
