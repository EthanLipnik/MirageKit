//
//  MessageTypes+AppStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - App-Centric Streaming Messages

/// Request for list of installed apps (Client → Host)
package struct AppListRequestMessage: Codable {
    /// Whether to include app icons in the response
    package let includeIcons: Bool

    package init(includeIcons: Bool) {
        self.includeIcons = includeIcons
    }
}

/// List of installed apps available for streaming (Host → Client)
package struct AppListMessage: Codable {
    /// Available apps (filtered by host's allow/blocklist, excludes apps already streaming)
    package let apps: [MirageInstalledApp]

    package init(apps: [MirageInstalledApp]) {
        self.apps = apps
    }
}

/// Request to stream an app (Client → Host)
package struct SelectAppMessage: Codable {
    /// Bundle identifier of the app to stream
    package let bundleIdentifier: String
    /// Client's data port for video
    package let dataPort: UInt16?
    /// Client's display scale factor
    package let scaleFactor: CGFloat?
    /// Client's display dimensions
    package let displayWidth: Int?
    package let displayHeight: Int?
    /// Client refresh rate override in Hz (60/120 based on client capability)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    package let maxRefreshRate: Int
    /// Client-requested keyframe interval in frames
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream bit depth.
    package var bitDepth: MirageVideoBitDepth?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    package let streamScale: CGFloat?
    /// Client audio streaming configuration
    package let audioConfiguration: MirageAudioConfiguration?
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case dataPort
        case scaleFactor
        case displayWidth
        case displayHeight
        case maxRefreshRate
        case keyFrameInterval
        case captureQueueDepth
        case bitDepth
        case bitrate
        case latencyMode
        case allowRuntimeQualityAdjustment
        case disableResolutionCap
        case streamScale
        case audioConfiguration
    }

    package init(
        bundleIdentifier: String,
        dataPort: UInt16? = nil,
        scaleFactor: CGFloat? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        maxRefreshRate: Int,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.dataPort = dataPort
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.maxRefreshRate = maxRefreshRate
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
    }
}

/// Confirmation that app streaming has started (Host → Client)
public struct AppStreamStartedMessage: Codable {
    /// Bundle identifier of the app being streamed
    public let bundleIdentifier: String
    /// App display name
    public let appName: String
    /// Initial windows that are now streaming
    public let windows: [AppStreamWindow]

    public struct AppStreamWindow: Codable {
        public let streamID: StreamID
        public let windowID: WindowID
        public let title: String?
        public let width: Int
        public let height: Int
        public let isResizable: Bool

        package init(
            streamID: StreamID,
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool
        ) {
            self.streamID = streamID
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
        }
    }

    package init(bundleIdentifier: String, appName: String, windows: [AppStreamWindow]) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windows = windows
    }
}

/// New window added to the app stream (Host → Client)
public struct WindowAddedToStreamMessage: Codable {
    /// Bundle identifier of the app
    public let bundleIdentifier: String
    /// Details of the new window
    public let streamID: StreamID
    public let windowID: WindowID
    public let title: String?
    public let width: Int
    public let height: Int
    public let isResizable: Bool

    package init(
        bundleIdentifier: String,
        streamID: StreamID,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.streamID = streamID
        self.windowID = windowID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
    }
}

/// Window removed from app stream (Host → Client)
package struct WindowRemovedFromStreamMessage: Codable {
    /// Bundle identifier of the app
    package let bundleIdentifier: String
    /// The window that was removed
    package let windowID: WindowID
    /// Why it was removed
    package let reason: RemovalReason

    package enum RemovalReason: String, Codable {
        /// Host closed the window
        case hostClosed
        /// Client requested close
        case clientClosed
        /// Window became invisible
        case windowHidden
    }

    package init(bundleIdentifier: String, windowID: WindowID, reason: RemovalReason) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.reason = reason
    }
}

/// Window cooldown started (Host → Client)
/// Sent when host closes a window - client should show cooldown UI
public struct WindowCooldownStartedMessage: Codable {
    /// The window that entered cooldown
    public let windowID: WindowID
    /// Cooldown duration in seconds
    public let durationSeconds: Int
    /// Human-readable message
    public let message: String

    package init(windowID: WindowID, durationSeconds: Int, message: String) {
        self.windowID = windowID
        self.durationSeconds = durationSeconds
        self.message = message
    }
}

/// Window cooldown cancelled (Host → Client)
/// Sent when a new window appears during cooldown - redirect stream to it
public struct WindowCooldownCancelledMessage: Codable {
    /// The old window that was in cooldown
    public let oldWindowID: WindowID
    /// The new window to stream to
    public let newStreamID: StreamID
    public let newWindowID: WindowID
    public let title: String?
    public let width: Int
    public let height: Int
    public let isResizable: Bool

    package init(
        oldWindowID: WindowID,
        newStreamID: StreamID,
        newWindowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        self.oldWindowID = oldWindowID
        self.newStreamID = newStreamID
        self.newWindowID = newWindowID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
    }
}

/// Return to app selection (Host → Client)
/// Sent when cooldown expires with no new window
public struct ReturnToAppSelectionMessage: Codable {
    /// The window that should return to app selection
    public let windowID: WindowID
    /// Bundle identifier of the app that was streaming
    public let bundleIdentifier: String
    /// Human-readable message
    public let message: String

    package init(windowID: WindowID, bundleIdentifier: String, message: String) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.message = message
    }
}

/// Request to close a window on the host (Client → Host)
package struct CloseWindowRequestMessage: Codable {
    /// The window to close
    package let windowID: WindowID

    package init(windowID: WindowID) {
        self.windowID = windowID
    }
}

/// Stream paused notification (Client → Host)
/// Sent when client window loses focus (e.g., Stage Manager)
package struct StreamPausedMessage: Codable {
    /// The stream to pause
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// Stream resumed notification (Client → Host)
/// Sent when client window regains focus
package struct StreamResumedMessage: Codable {
    /// The stream to resume
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// Cancel cooldown and close immediately (Client → Host)
package struct CancelCooldownMessage: Codable {
    /// The window to close (was in cooldown)
    package let windowID: WindowID

    package init(windowID: WindowID) {
        self.windowID = windowID
    }
}

/// Window resizability changed (Host → Client)
package struct WindowResizabilityChangedMessage: Codable {
    /// The window whose resizability changed
    package let windowID: WindowID
    /// New resizability state
    package let isResizable: Bool

    package init(windowID: WindowID, isResizable: Bool) {
        self.windowID = windowID
        self.isResizable = isResizable
    }
}

/// App terminated notification (Host → Client)
/// Sent when the streamed app quits or crashes
public struct AppTerminatedMessage: Codable {
    /// Bundle identifier of the app that terminated
    public let bundleIdentifier: String
    /// Window IDs that were streaming from this app
    public let closedWindowIDs: [WindowID]
    /// Whether there are any remaining windows on this client
    public let hasRemainingWindows: Bool

    package init(bundleIdentifier: String, closedWindowIDs: [WindowID], hasRemainingWindows: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.closedWindowIDs = closedWindowIDs
        self.hasRemainingWindows = hasRemainingWindows
    }
}
