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
struct AppListRequestMessage: Codable {
    /// Whether to include app icons in the response
    let includeIcons: Bool
}

/// List of installed apps available for streaming (Host → Client)
struct AppListMessage: Codable {
    /// Available apps (filtered by host's allow/blocklist, excludes apps already streaming)
    let apps: [MirageInstalledApp]
}

/// Request to stream an app (Client → Host)
struct SelectAppMessage: Codable {
    /// Bundle identifier of the app to stream
    let bundleIdentifier: String
    /// Quality preset for initial streams
    let preferredQuality: MirageQualityPreset
    /// Client's data port for video
    let dataPort: UInt16?
    /// Client's display scale factor
    let scaleFactor: CGFloat?
    /// Client's display dimensions
    let displayWidth: Int?
    let displayHeight: Int?
    /// Client refresh rate override in Hz (60/120 based on client capability)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    let maxRefreshRate: Int
    /// Client-requested keyframe interval in frames
    var keyFrameInterval: Int?
    /// Client-requested inter-frame quality (0.0-1.0)
    var frameQuality: Float?
    /// Client-requested keyframe quality (0.0-1.0)
    var keyframeQuality: Float?
    /// Client-requested pixel format (capture + encode)
    var pixelFormat: MiragePixelFormat?
    /// Client-requested color space
    var colorSpace: MirageColorSpace?
    /// Client-requested ScreenCaptureKit queue depth
    var captureQueueDepth: Int?
    /// Client-requested minimum target bitrate (bits per second)
    var minBitrate: Int?
    /// Client-requested maximum target bitrate (bits per second)
    var maxBitrate: Int?
    /// Client-requested stream scale (0.1-1.0)
    let streamScale: CGFloat?
    /// Client latency preference for buffering behavior
    let latencyMode: MirageStreamLatencyMode?
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case preferredQuality
        case dataPort
        case scaleFactor
        case displayWidth
        case displayHeight
        case maxRefreshRate
        case keyFrameInterval
        case frameQuality = "keyframeQuality"
        case keyframeQuality = "keyframeQualityOverride"
        case pixelFormat
        case colorSpace
        case captureQueueDepth
        case minBitrate
        case maxBitrate
        case streamScale
        case latencyMode
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
}

/// Window removed from app stream (Host → Client)
struct WindowRemovedFromStreamMessage: Codable {
    /// Bundle identifier of the app
    let bundleIdentifier: String
    /// The window that was removed
    let windowID: WindowID
    /// Why it was removed
    let reason: RemovalReason

    enum RemovalReason: String, Codable {
        /// Host closed the window
        case hostClosed
        /// Client requested close
        case clientClosed
        /// Window became invisible
        case windowHidden
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
}

/// Request to close a window on the host (Client → Host)
struct CloseWindowRequestMessage: Codable {
    /// The window to close
    let windowID: WindowID
}

/// Stream paused notification (Client → Host)
/// Sent when client window loses focus (e.g., Stage Manager)
struct StreamPausedMessage: Codable {
    /// The stream to pause
    let streamID: StreamID
}

/// Stream resumed notification (Client → Host)
/// Sent when client window regains focus
struct StreamResumedMessage: Codable {
    /// The stream to resume
    let streamID: StreamID
}

/// Cancel cooldown and close immediately (Client → Host)
struct CancelCooldownMessage: Codable {
    /// The window to close (was in cooldown)
    let windowID: WindowID
}

/// Window resizability changed (Host → Client)
struct WindowResizabilityChangedMessage: Codable {
    /// The window whose resizability changed
    let windowID: WindowID
    /// New resizability state
    let isResizable: Bool
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
}
