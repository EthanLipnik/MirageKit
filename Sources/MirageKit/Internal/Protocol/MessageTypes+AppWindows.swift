//
//  MessageTypes+AppWindows.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  App-window protocol message definitions.
//

import Foundation

/// Host-to-client snapshot of visible and hidden windows for an app session.
public struct AppWindowInventoryMessage: Codable, Sendable {
    /// App-window metadata that is independent of slot assignment.
    public struct WindowMetadata: Codable, Sendable, Equatable {
        /// Host window ID.
        public let windowID: WindowID

        /// Host window title, when available.
        public let title: String?

        /// Window width in points.
        public let width: Int

        /// Window height in points.
        public let height: Int

        /// Whether the source window can be resized by Mirage.
        public let isResizable: Bool

        /// Creates app-window metadata.
        package init(
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool
        ) {
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
        }
    }

    /// Visible app-window slot currently backed by a stream.
    public struct Slot: Codable, Sendable, Equatable {
        /// Visible slot index.
        public let slotIndex: Int

        /// Logical stream ID for input and lifecycle routing.
        public let streamID: StreamID

        /// Physical media stream carrying this slot.
        public let mediaStreamID: StreamID

        /// Window assigned to the slot.
        public let window: WindowMetadata

        /// Atlas region carrying this slot, when atlas media is used.
        public let atlasRegion: MirageAppAtlasRegion?

        /// Creates a visible app-window slot.
        package init(
            slotIndex: Int,
            streamID: StreamID,
            mediaStreamID: StreamID,
            window: WindowMetadata,
            atlasRegion: MirageAppAtlasRegion? = nil
        ) {
            self.slotIndex = slotIndex
            self.streamID = streamID
            self.mediaStreamID = mediaStreamID
            self.window = window
            self.atlasRegion = atlasRegion
        }
    }

    /// Bundle identifier for the app inventory.
    public let bundleIdentifier: String

    /// App-session identifier, when known.
    public let appSessionID: UUID?

    /// Maximum number of concurrent visible slots.
    public let maxVisibleSlots: Int

    /// Visible streamed window slots.
    public let slots: [Slot]

    /// Stream-eligible windows not currently assigned to a visible slot.
    public let hiddenWindows: [WindowMetadata]

    /// Atlas layouts carrying the visible slots, if atlas media is used.
    public let atlasLayouts: [MirageAppAtlasLayout]?

    /// Creates an app-window inventory snapshot.
    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        maxVisibleSlots: Int,
        slots: [Slot],
        hiddenWindows: [WindowMetadata],
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.maxVisibleSlots = max(1, maxVisibleSlots)
        self.slots = slots
        self.hiddenWindows = hiddenWindows
        self.atlasLayouts = atlasLayouts
    }

    /// Returns an inventory snapshot with `windowID` removed, or `nil` when no windows remain.
    public func removingWindow(windowID: WindowID) -> AppWindowInventoryMessage? {
        let remainingSlots = slots.filter { $0.window.windowID != windowID }
        let remainingHiddenWindows = hiddenWindows.filter { $0.windowID != windowID }

        guard !remainingSlots.isEmpty || !remainingHiddenWindows.isEmpty else {
            return nil
        }

        let remainingAtlasLayouts = atlasLayouts?.compactMap { layout -> MirageAppAtlasLayout? in
            let remainingRegions = layout.regions.filter { $0.windowID != windowID }
            guard !remainingRegions.isEmpty else { return nil }
            return MirageAppAtlasLayout(
                mediaStreamID: layout.mediaStreamID,
                layoutEpoch: layout.layoutEpoch,
                width: layout.width,
                height: layout.height,
                regions: remainingRegions
            )
        }

        return AppWindowInventoryMessage(
            bundleIdentifier: bundleIdentifier,
            appSessionID: appSessionID,
            maxVisibleSlots: maxVisibleSlots,
            slots: remainingSlots,
            hiddenWindows: remainingHiddenWindows,
            atlasLayouts: remainingAtlasLayouts
        )
    }
}

/// Client-to-host request to replace the window shown in an app-stream slot.
package struct AppWindowSwapRequestMessage: Codable {
    /// Bundle identifier for the app session.
    package let bundleIdentifier: String

    /// Slot stream to replace.
    package let targetSlotStreamID: StreamID

    /// Hidden or alternate window to show in the target slot.
    package let targetWindowID: WindowID

    /// Creates an app-window slot swap request.
    package init(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetSlotStreamID = targetSlotStreamID
        self.targetWindowID = targetWindowID
    }
}

/// Host-to-client result for an app-window slot swap request.
public struct AppWindowSwapResultMessage: Codable, Sendable {
    /// Bundle identifier for the app session.
    public let bundleIdentifier: String

    /// Slot stream targeted by the request.
    public let targetSlotStreamID: StreamID

    /// Physical media stream now carrying the slot.
    public let mediaStreamID: StreamID

    /// Window now assigned to the slot.
    public let windowID: WindowID

    /// Whether the swap succeeded.
    public let success: Bool

    /// Failure reason when `success` is false.
    public let reason: String?

    /// Atlas region carrying the swapped slot, if atlas media is used.
    public let atlasRegion: MirageAppAtlasRegion?

    /// Updated atlas layouts after the swap.
    public let atlasLayouts: [MirageAppAtlasLayout]?

    /// Creates an app-window swap result payload.
    package init(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        mediaStreamID: StreamID,
        windowID: WindowID,
        success: Bool,
        reason: String?,
        atlasRegion: MirageAppAtlasRegion? = nil,
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetSlotStreamID = targetSlotStreamID
        self.mediaStreamID = mediaStreamID
        self.windowID = windowID
        self.success = success
        self.reason = reason
        self.atlasRegion = atlasRegion
        self.atlasLayouts = atlasLayouts
    }
}

/// Host-to-client notification that a new window was added to an app stream.
public struct WindowAddedToStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app.
    public let bundleIdentifier: String

    /// App-session identifier for the stream being expanded.
    public let appSessionID: UUID?

    /// Logical stream ID for routing input and lifecycle events.
    public let streamID: StreamID

    /// Physical media stream carrying this window.
    public let mediaStreamID: StreamID

    /// Host window ID.
    public let windowID: WindowID

    /// Host window title, when available.
    public let title: String?

    /// Window width in points.
    public let width: Int

    /// Window height in points.
    public let height: Int

    /// Whether the source window can be resized by Mirage.
    public let isResizable: Bool

    /// Atlas region carrying this logical window, if atlas media is used.
    public let atlasRegion: MirageAppAtlasRegion?

    /// Updated atlas layouts after the window was added.
    public let atlasLayouts: [MirageAppAtlasLayout]?

    /// Creates a window-added payload.
    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        streamID: StreamID,
        mediaStreamID: StreamID,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool,
        atlasRegion: MirageAppAtlasRegion? = nil,
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
        self.windowID = windowID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
        self.atlasRegion = atlasRegion
        self.atlasLayouts = atlasLayouts
    }
}

/// Host-to-client notification that a window was removed from an app stream.
public struct WindowRemovedFromStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app.
    public let bundleIdentifier: String

    /// App-session identifier for the removed window, when known.
    public let appSessionID: UUID?

    /// The stream that was removed.
    public let streamID: StreamID?

    /// Window that was removed.
    public let windowID: WindowID

    /// Why it was removed.
    public let reason: RemovalReason

    /// Reason a streamed app window disappeared.
    public enum RemovalReason: String, Codable, Sendable {
        /// Host closed the window.
        case hostClosed

        /// Window no longer matches stream-eligible criteria.
        case noLongerEligible

        /// Host-side app terminated.
        case appTerminated
    }

    /// Creates a window-removed payload.
    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        streamID: StreamID? = nil,
        windowID: WindowID,
        reason: RemovalReason
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.streamID = streamID
        self.windowID = windowID
        self.reason = reason
    }
}

/// Host-to-client notification that a window stream failed.
public struct WindowStreamFailedMessage: Codable, Sendable {
    /// Stable failure category for client recovery policy.
    public enum FailureCode: String, Codable, Sendable {
        /// The host could not classify the failure more specifically.
        case unknown

        /// The requested host window no longer exists.
        case windowNotFound

        /// The requested host window is already bound to another stream.
        case windowAlreadyBound

        /// A virtual display was required but unavailable.
        case virtualDisplayUnavailable

        /// Virtual display creation failed.
        case virtualDisplayCreationFailed

        /// The host could not place the source window for capture.
        case windowPlacementFailed

        /// Runtime conditions, such as lock state, blocked startup.
        case runtimeConditionBlocked
    }

    /// Bundle identifier of the app.
    public let bundleIdentifier: String
    /// Host window identifier that failed to stream.
    public let windowID: WindowID
    /// Optional host window title.
    public let title: String?
    /// Failure reason suitable for diagnostics and user-facing notice text.
    public let reason: String
    /// Stable failure code for client recovery policy.
    public let failureCode: FailureCode
    /// Short user-facing message for client recovery UI.
    public let userMessage: String

    package init(
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        reason: String,
        failureCode: FailureCode = .unknown,
        userMessage: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.title = title
        self.reason = reason
        self.failureCode = failureCode
        self.userMessage = userMessage
    }
}

/// Host-to-client notification that a streamed app quit or crashed.
public struct AppTerminatedMessage: Codable, Sendable {
    /// Bundle identifier of the app that terminated.
    public let bundleIdentifier: String

    /// Window IDs that were streaming from this app.
    public let closedWindowIDs: [WindowID]

    /// Whether this client still has streamed windows after termination handling.
    public let hasRemainingWindows: Bool

    /// Creates an app-terminated notification.
    package init(bundleIdentifier: String, closedWindowIDs: [WindowID], hasRemainingWindows: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.closedWindowIDs = closedWindowIDs
        self.hasRemainingWindows = hasRemainingWindows
    }
}
