//
//  MirageAppStreamSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation

/// Represents the state of an app streaming session
/// An app stream session manages streaming all windows from a single app to a single client
public struct MirageAppStreamSession: Identifiable, Sendable {
    /// Unique identifier for this session
    public let id: UUID

    /// Bundle identifier of the app being streamed
    public let bundleIdentifier: String

    /// Display name of the app
    public let appName: String

    /// Path to the app bundle
    public let appPath: String

    /// The client receiving this stream
    public let clientID: UUID

    /// Client's display name
    public let clientName: String

    /// Current state of the session
    public var state: AppStreamState

    /// Active window streams (WindowID → StreamSession info)
    public var windowStreams: [WindowID: WindowStreamInfo]

    /// Windows currently in cooldown (WindowID → cooldown expiry time)
    public var windowsInCooldown: [WindowID: Date]

    /// All windows that have been seen for this app (prevents duplicate "new window" detection)
    public var knownWindowIDs: Set<WindowID>

    /// When this session started
    public let startTime: Date

    /// When the client disconnected unexpectedly (for reservation period)
    public var disconnectedAt: Date?

    public var _id: String { id.uuidString }

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String,
        state: AppStreamState = .starting,
        windowStreams: [WindowID: WindowStreamInfo] = [:],
        windowsInCooldown: [WindowID: Date] = [:],
        knownWindowIDs: Set<WindowID> = [],
        startTime: Date = Date(),
        disconnectedAt: Date? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appPath = appPath
        self.clientID = clientID
        self.clientName = clientName
        self.state = state
        self.windowStreams = windowStreams
        self.windowsInCooldown = windowsInCooldown
        self.knownWindowIDs = knownWindowIDs
        self.startTime = startTime
        self.disconnectedAt = disconnectedAt
    }
}

/// State of an app streaming session
public enum AppStreamState: Sendable, Equatable {
    /// Session is starting up (launching app, finding windows)
    case starting

    /// Actively streaming windows
    case streaming

    /// Client disconnected unexpectedly, in reservation period
    case disconnected(reservationExpiresAt: Date)

    /// Session is closing down
    case closing
}

/// Information about a single window stream within an app session
public struct WindowStreamInfo: Sendable {
    /// The stream ID assigned to this window
    public let streamID: StreamID

    /// Window title
    public var title: String?

    /// Current window dimensions
    public var width: Int
    public var height: Int

    /// Whether the window can be resized
    public var isResizable: Bool

    /// Whether the stream is currently paused (client not in focus)
    public var isPaused: Bool

    /// When this stream started
    public let startTime: Date

    public init(
        streamID: StreamID,
        title: String? = nil,
        width: Int,
        height: Int,
        isResizable: Bool = true,
        isPaused: Bool = false,
        startTime: Date = Date()
    ) {
        self.streamID = streamID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
        self.isPaused = isPaused
        self.startTime = startTime
    }
}

// MARK: - Convenience Extensions

public extension MirageAppStreamSession {
    /// Whether this session has any active (non-cooldown) windows
    var hasActiveWindows: Bool { !windowStreams.isEmpty }

    /// Whether this session is in a reservation period (client disconnected)
    var isReserved: Bool {
        if case .disconnected = state { return true }
        return false
    }

    /// Whether the reservation has expired
    var reservationExpired: Bool {
        guard case let .disconnected(expiresAt) = state else { return false }
        return Date() > expiresAt
    }

    /// Total number of windows (streaming + cooldown)
    var totalWindowCount: Int { windowStreams.count + windowsInCooldown.count }

    /// Check if a specific window is in cooldown
    func isWindowInCooldown(_ windowID: WindowID) -> Bool {
        guard let expiresAt = windowsInCooldown[windowID] else { return false }
        return Date() < expiresAt
    }

    /// Get expired cooldowns
    var expiredCooldowns: [WindowID] {
        let now = Date()
        return windowsInCooldown.compactMap { windowID, expiresAt in
            now >= expiresAt ? windowID : nil
        }
    }
}
