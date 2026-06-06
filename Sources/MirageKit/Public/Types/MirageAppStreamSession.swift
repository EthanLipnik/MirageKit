//
//  MirageAppStreamSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

/// State for streaming one app's windows to a single client.
public struct MirageAppStreamSession: Identifiable, Sendable {
    /// Unique identifier for this session.
    public let id: UUID

    /// Bundle identifier of the app being streamed.
    public let bundleIdentifier: String

    /// Display name of the app.
    public let appName: String

    /// Path to the app bundle.
    public let appPath: String

    /// The client receiving this stream.
    public let clientID: UUID

    /// Client's display name.
    public let clientName: String

    /// Logical client display resolution requested for app-stream virtual displays.
    public let requestedDisplayResolution: CGSize

    /// Optional client display scale override used for app-stream virtual displays.
    public let requestedClientScaleFactor: CGFloat?

    /// Maximum number of visible window slots for this app stream session.
    public var maxVisibleSlots: Int

    /// Total bitrate budget shared across visible window slots.
    package var bitrateBudgetBps: Int?

    /// Current state of the session.
    public var state: AppStreamState

    /// Active window streams keyed by host window ID.
    public var windowStreams: [WindowID: WindowStreamInfo]

    /// Hidden candidate windows that are eligible for slot swap/start.
    package var hiddenWindows: [WindowID: AppStreamHiddenWindowInfo]

    /// All windows that have been seen for this app during the current session.
    public var knownWindowIDs: Set<WindowID>

    /// Last computed active/inactive state for visible stream IDs.
    package var streamActivityByStreamID: [StreamID: Bool]

    /// Last bitrate targets applied by the host governor for visible stream IDs.
    package var streamBitrateTargetsByStreamID: [StreamID: Int]

    /// When this session started.
    public let startTime: Date

    /// When the client disconnected unexpectedly during the reservation period.
    public var disconnectedAt: Date?

    /// Creates an app stream session, clamping the visible slot count to at least one.
    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        appPath: String,
        clientID: UUID,
        clientName: String,
        requestedDisplayResolution: CGSize = .zero,
        requestedClientScaleFactor: CGFloat? = nil,
        maxVisibleSlots: Int = 1,
        bitrateBudgetBps: Int? = nil,
        state: AppStreamState = .starting,
        windowStreams: [WindowID: WindowStreamInfo] = [:],
        hiddenWindows: [WindowID: AppStreamHiddenWindowInfo] = [:],
        knownWindowIDs: Set<WindowID> = [],
        streamActivityByStreamID: [StreamID: Bool] = [:],
        streamBitrateTargetsByStreamID: [StreamID: Int] = [:],
        startTime: Date = Date(),
        disconnectedAt: Date? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appPath = appPath
        self.clientID = clientID
        self.clientName = clientName
        self.requestedDisplayResolution = requestedDisplayResolution
        self.requestedClientScaleFactor = requestedClientScaleFactor
        self.maxVisibleSlots = max(1, maxVisibleSlots)
        self.bitrateBudgetBps = bitrateBudgetBps
        self.state = state
        self.windowStreams = windowStreams
        self.hiddenWindows = hiddenWindows
        self.knownWindowIDs = knownWindowIDs
        self.streamActivityByStreamID = streamActivityByStreamID
        self.streamBitrateTargetsByStreamID = streamBitrateTargetsByStreamID
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

    /// Physical media stream carrying this logical window.
    public var mediaStreamID: StreamID

    /// Fixed slot index for this stream/window binding.
    public var slotIndex: Int

    /// Window title
    public var title: String?

    /// Current window width in points.
    public var width: Int
    /// Current window height in points.
    public var height: Int

    /// Whether the window can be resized
    public var isResizable: Bool

    /// Whether the stream is currently paused (client not in focus)
    public var isPaused: Bool

    /// Whether the host activity governor currently treats the stream as active.
    public var isActive: Bool

    /// Window IDs currently included in the captured display-filter cluster for this visible slot.
    public var capturedClusterWindowIDs: [WindowID]

    /// Region for this logical window inside an app-atlas media stream.
    public var atlasRegion: MirageMedia.MirageAppAtlasRegion?

    /// When this stream started
    public let startTime: Date

    /// Creates metadata for one visible window stream within an app stream session.
    public init(
        streamID: StreamID,
        mediaStreamID: StreamID,
        slotIndex: Int = 0,
        title: String? = nil,
        width: Int,
        height: Int,
        isResizable: Bool = true,
        isPaused: Bool = false,
        isActive: Bool = true,
        capturedClusterWindowIDs: [WindowID] = [],
        atlasRegion: MirageMedia.MirageAppAtlasRegion? = nil,
        startTime: Date = Date()
    ) {
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
        self.slotIndex = slotIndex
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
        self.isPaused = isPaused
        self.isActive = isActive
        self.capturedClusterWindowIDs = capturedClusterWindowIDs
        self.atlasRegion = atlasRegion
        self.startTime = startTime
    }
}

/// Metadata for a hidden app window that can later be promoted into a visible stream slot.
public struct AppStreamHiddenWindowInfo: Sendable {
    /// Last known window title.
    public var title: String?
    /// Last known logical width.
    public var width: Int
    /// Last known logical height.
    public var height: Int
    /// Whether the host can resize the window before streaming it.
    public var isResizable: Bool

    /// Creates metadata for a hidden app window that can later fill a visible slot.
    public init(
        title: String? = nil,
        width: Int,
        height: Int,
        isResizable: Bool = true
    ) {
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
    }
}

// MARK: - Convenience Extensions

public extension MirageAppStreamSession {
    /// Whether this session is in a reservation period after client disconnect.
    var isReserved: Bool {
        if case .disconnected = state { return true }
        return false
    }

    /// Whether the reservation has expired.
    var reservationExpired: Bool {
        guard case let .disconnected(expiresAt) = state else { return false }
        return Date() > expiresAt
    }
}
