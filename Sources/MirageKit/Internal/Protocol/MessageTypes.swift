import Foundation
import CoreGraphics

/// Control channel message types (sent over TCP)
enum ControlMessageType: UInt8, Codable {
    // Connection management
    case hello = 0x01
    case helloResponse = 0x02
    case disconnect = 0x03
    case ping = 0x04
    case pong = 0x05

    // Authentication
    case authRequest = 0x10
    case authChallenge = 0x11
    case authResponse = 0x12
    case authResult = 0x13

    // Window management
    case windowListRequest = 0x20
    case windowList = 0x21
    case windowUpdate = 0x22
    case startStream = 0x23
    case stopStream = 0x24
    case streamStarted = 0x25
    case streamStopped = 0x26

    // Input events
    case inputEvent = 0x30

    // Quality control
    case qualityChange = 0x41
    case keyframeRequest = 0x42

    // Cursor updates
    case cursorUpdate = 0x50

    // Virtual display updates
    case contentBoundsUpdate = 0x60
    case displayResolutionChange = 0x61
    case streamScaleChange = 0x62

    // Session state and unlock (for headless Mac support)
    case sessionStateUpdate = 0x70
    case unlockRequest = 0x71
    case unlockResponse = 0x72
    case loginDisplayReady = 0x73    // Host -> Client: Login display stream is starting
    case loginDisplayStopped = 0x74  // Host -> Client: Login complete, display stream stopped

    // App-centric streaming (new)
    case appListRequest = 0x80
    case appList = 0x81
    case selectApp = 0x82
    case appStreamStarted = 0x83
    case windowAddedToStream = 0x84
    case windowRemovedFromStream = 0x85
    case windowCooldownStarted = 0x86
    case windowCooldownCancelled = 0x87
    case returnToAppSelection = 0x88
    case closeWindowRequest = 0x89
    case streamPaused = 0x8A
    case streamResumed = 0x8B
    case cancelCooldown = 0x8C
    case windowResizabilityChanged = 0x8D
    case appTerminated = 0x8E

    // Menu bar passthrough
    case menuBarUpdate = 0x90       // Host → Client: Menu structure update
    case menuActionRequest = 0x91   // Client → Host: Execute menu action
    case menuActionResult = 0x92    // Host → Client: Action result

    // Desktop streaming (full virtual display mirroring)
    case startDesktopStream = 0xA0      // Client → Host: Start full desktop stream
    case stopDesktopStream = 0xA1       // Client → Host: Stop desktop stream
    case desktopStreamStarted = 0xA2    // Host → Client: Desktop stream is active
    case desktopStreamStopped = 0xA3    // Host → Client: Desktop stream ended

    // Errors
    case error = 0xFF
}

/// Base control message envelope
struct ControlMessage: Codable {
    let type: ControlMessageType
    let payload: Data

    init(type: ControlMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    init<T: Encodable>(type: ControlMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func deserialize(from data: Data) -> (ControlMessage, Int)? {
        guard data.count >= 5 else { return nil }

        // Use index-relative access for Data that might be a slice
        let startIdx = data.startIndex
        let typeByte = data[startIdx]
        guard let type = ControlMessageType(rawValue: typeByte) else {
            MirageLogger.error(.client, "Unknown control message type byte: 0x\(String(format: "%02X", typeByte))")
            return nil
        }

        // Read length from bytes 1-4 (after the type byte)
        let lengthBytes = data[data.index(startIdx, offsetBy: 1)..<data.index(startIdx, offsetBy: 5)]
        let length = lengthBytes.withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }

        let totalLength = 5 + Int(length)
        guard data.count >= totalLength else { return nil }

        // Extract payload using proper indices
        let payloadStart = data.index(startIdx, offsetBy: 5)
        let payloadEnd = data.index(startIdx, offsetBy: totalLength)
        let payload = Data(data[payloadStart..<payloadEnd])

        return (ControlMessage(type: type, payload: payload), totalLength)
    }
}

// MARK: - Connection Messages

struct HelloMessage: Codable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let capabilities: MirageHostCapabilities
}

struct HelloResponseMessage: Codable {
    let accepted: Bool
    let hostID: UUID
    let hostName: String
    let requiresAuth: Bool
    let dataPort: UInt16
}

struct DisconnectMessage: Codable {
    let reason: DisconnectReason
    let message: String?

    enum DisconnectReason: String, Codable {
        case userRequested
        case timeout
        case error
        case hostShutdown
        case authFailed
    }
}

// MARK: - Authentication Messages

struct AuthRequestMessage: Codable {
    let deviceID: UUID
    let publicKey: Data
}

struct AuthChallengeMessage: Codable {
    let challenge: Data
}

struct AuthResponseMessage: Codable {
    let signature: Data
}

struct AuthResultMessage: Codable {
    let success: Bool
    let trusted: Bool
    let errorMessage: String?
}

// MARK: - Window Messages

struct WindowListMessage: Codable {
    let windows: [MirageWindow]
}

struct WindowUpdateMessage: Codable {
    let added: [MirageWindow]
    let removed: [WindowID]
    let updated: [MirageWindow]
}

struct StartStreamMessage: Codable {
    let windowID: WindowID
    let preferredQuality: MirageQualityPreset
    /// UDP port the client is listening on for video data
    let dataPort: UInt16?
    /// Client's display scale factor (e.g., 2.0 for Retina Mac, ~1.72 for iPad Pro)
    /// If nil, host uses its own scale factor (backwards compatibility)
    var scaleFactor: CGFloat? = nil
    /// Client's requested pixel dimensions (optional, for initial stream setup)
    /// If nil, host uses window size × scaleFactor
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    /// Client's physical display resolution in pixels (for virtual display sizing)
    /// Virtual display will be created at this resolution
    var displayWidth: Int? = nil
    var displayHeight: Int? = nil
    /// Client-requested maximum bitrate in bits per second
    /// Use higher values (e.g., 300_000_000 = 300Mbps) for high-bandwidth networks
    /// If nil, host uses default from encoder configuration
    var maxBitrate: Int? = nil
    /// Client-requested keyframe interval in frames
    /// Higher values (e.g., 600 = 10 seconds @ 60fps) reduce periodic lag spikes
    /// If nil, host uses default from encoder configuration
    var keyFrameInterval: Int? = nil
    /// Client-requested encoder quality (0.0-1.0)
    /// Lower values reduce frame size with minimal visual impact
    /// If nil, host uses default from encoder configuration
    var keyframeQuality: Float? = nil
    /// Client-requested stream scale (0.1-1.0)
    /// Applies post-capture downscaling without resizing the host window
    var streamScale: CGFloat? = nil
    /// Client's display maximum refresh rate in Hz (60 or 120)
    /// Mirrors the client-side ProMotion toggle (60 when disabled).
    var maxRefreshRate: Int = 60
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // /// Requires HDR-capable display on both host and client
    // var preferHDR: Bool = false
}

struct StopStreamMessage: Codable {
    let streamID: StreamID
    /// Whether to minimize the source window on the host after stopping the stream
    var minimizeWindow: Bool = false
}

struct StreamStartedMessage: Codable {
    let streamID: StreamID
    let windowID: WindowID
    let width: Int
    let height: Int
    let frameRate: Int
    let codec: MirageVideoCodec
    /// Minimum window size in points - client should not resize smaller
    var minWidth: Int? = nil
    var minHeight: Int? = nil
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16? = nil
}

struct StreamStoppedMessage: Codable {
    let streamID: StreamID
    let reason: StopReason

    enum StopReason: String, Codable {
        case clientRequested
        case windowClosed
        case error
    }
}

// MARK: - Input Messages

struct InputEventMessage: Codable {
    let streamID: StreamID
    let event: MirageInputEvent
}

// MARK: - Quality Messages

struct QualityChangeMessage: Codable {
    let streamID: StreamID
    let newBitrate: Int
    let newFrameRate: Int
}

struct KeyframeRequestMessage: Codable {
    let streamID: StreamID
}

// MARK: - Cursor Messages

/// Cursor state update sent from host to client when cursor appearance changes
struct CursorUpdateMessage: Codable {
    /// The stream this cursor update applies to
    let streamID: StreamID
    /// The current cursor type on the host
    let cursorType: MirageCursorType
    /// Whether the cursor is currently within the streamed window bounds
    let isVisible: Bool
}

// MARK: - Error Messages

struct ErrorMessage: Codable {
    let code: ErrorCode
    let message: String
    let streamID: StreamID?

    enum ErrorCode: String, Codable {
        case unknown
        case invalidMessage
        case streamNotFound
        case windowNotFound
        case encodingError
        case decodingError
        case networkError
        case authRequired
        case permissionDenied
    }
}

// MARK: - Virtual Display Messages

/// Content bounds update sent from host to client when content area changes
/// This happens when menus, sheets, or panels appear on the virtual display
struct ContentBoundsUpdateMessage: Codable {
    /// The stream this update applies to
    let streamID: StreamID
    /// New content bounds in pixels (origin + size)
    let boundsX: CGFloat
    let boundsY: CGFloat
    let boundsWidth: CGFloat
    let boundsHeight: CGFloat

    init(streamID: StreamID, bounds: CGRect) {
        self.streamID = streamID
        self.boundsX = bounds.origin.x
        self.boundsY = bounds.origin.y
        self.boundsWidth = bounds.width
        self.boundsHeight = bounds.height
    }

    var bounds: CGRect {
        CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight)
    }
}

/// Display resolution change request sent from client to host
/// Used when client window moves to a different physical display
struct DisplayResolutionChangeMessage: Codable {
    /// The stream to update
    let streamID: StreamID
    /// New display resolution in pixels
    let displayWidth: Int
    let displayHeight: Int
}

/// Stream scale change request sent from client to host
/// Applies post-capture downscaling without resizing host windows
struct StreamScaleChangeMessage: Codable {
    /// The stream to update
    let streamID: StreamID
    /// Stream scale factor (0.1-1.0)
    let streamScale: CGFloat
}

// MARK: - Session State Messages (Headless Mac Support)

/// Host session state - indicates whether the Mac is accessible for streaming
public enum HostSessionState: String, Codable, Sendable {
    /// Screen is unlocked, ready for normal streaming
    case active
    /// Screen is locked (user logged in but screen locked, password only needed)
    case screenLocked
    /// At login window (no user session, username + password needed)
    case loginScreen
    /// Mac is asleep (needs wake before unlock)
    case sleeping

    /// Whether credentials are required to reach active state
    public var requiresUnlock: Bool {
        switch self {
        case .active: return false
        case .screenLocked, .loginScreen, .sleeping: return true
        }
    }

    /// Whether username is needed in addition to password
    public var requiresUsername: Bool {
        switch self {
        case .loginScreen: return true
        case .active, .screenLocked, .sleeping: return false
        }
    }
}

/// Session state update sent from host to client
/// Sent immediately after connection and whenever state changes
struct SessionStateUpdateMessage: Codable {
    /// Current session state
    let state: HostSessionState
    /// Session token for this state (prevents replay attacks)
    let sessionToken: String
    /// Whether username is needed for unlock
    let requiresUsername: Bool
    /// Timestamp of this update
    let timestamp: Date
}

/// Unlock request sent from client to host
struct UnlockRequestMessage: Codable {
    /// Session token from SessionStateUpdateMessage (must match current)
    let sessionToken: String
    /// Username (required for loginScreen state, ignored otherwise)
    let username: String?
    /// Password for unlock
    let password: String
}

/// Unlock response sent from host to client
struct UnlockResponseMessage: Codable {
    /// Whether unlock was successful
    let success: Bool
    /// New session state after attempt
    let newState: HostSessionState
    /// New session token (if state changed)
    let newSessionToken: String?
    /// Error details if failed
    let error: UnlockError?
    /// Whether client can retry with same token
    let canRetry: Bool
    /// Number of attempts remaining before lockout
    let retriesRemaining: Int?
    /// Seconds to wait before next attempt (rate limiting)
    let retryAfterSeconds: Int?
}

/// Unlock error details
struct UnlockError: Codable {
    let code: UnlockErrorCode
    let message: String
}

/// Error codes for unlock failures
enum UnlockErrorCode: String, Codable {
    /// Wrong username or password
    case invalidCredentials
    /// Too many failed attempts
    case rateLimited
    /// Session token expired or invalid
    case sessionExpired
    /// Host is not in a locked state
    case notLocked
    /// Remote unlock is disabled on host
    case notSupported
    /// Client not authorized for unlock
    case notAuthorized
    /// Unlock operation timed out
    case timeout
    /// Internal error on host
    case internalError
}

// MARK: - Login Display Streaming

/// Sent when host starts streaming the login/lock screen to client
/// Client should prepare to receive frames marked with .loginDisplay flag
struct LoginDisplayReadyMessage: Codable {
    /// Stream ID for the login display stream
    let streamID: UInt32
    /// Resolution of the login display
    let width: Int
    let height: Int
    /// Current session state (screenLocked, loginScreen, etc.)
    let sessionState: HostSessionState
    /// Whether username is needed (true for loginScreen, false for screenLocked)
    let requiresUsername: Bool
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16? = nil
}

/// Sent when login display stream stops (user logged in successfully)
/// Client should transition to normal window selection mode
struct LoginDisplayStoppedMessage: Codable {
    /// The stream ID that was stopped
    let streamID: UInt32
    /// New session state (should be .active)
    let newState: HostSessionState
}

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
    /// Client's display maximum refresh rate in Hz (60 or 120)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    let maxRefreshRate: Int
    /// Client-requested maximum bitrate in bits per second
    let maxBitrate: Int?
    /// Client-requested keyframe interval in frames
    let keyFrameInterval: Int?
    /// Client-requested encoder quality (0.0-1.0)
    let keyframeQuality: Float?
    /// Client-requested stream scale (0.1-1.0)
    let streamScale: CGFloat?
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false
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

// MARK: - Menu Bar Passthrough Messages

/// Menu bar structure update (Host → Client)
/// Sent when the remote app's menu bar changes or on initial stream start
struct MenuBarUpdateMessage: Codable {
    /// The stream this menu bar applies to
    let streamID: StreamID
    /// The menu bar structure, or nil if extraction failed/unavailable
    let menuBar: MirageMenuBar?
    /// Error message if extraction failed
    let errorMessage: String?

    init(streamID: StreamID, menuBar: MirageMenuBar?, errorMessage: String? = nil) {
        self.streamID = streamID
        self.menuBar = menuBar
        self.errorMessage = errorMessage
    }
}

/// Request to execute a menu action (Client → Host)
struct MenuActionRequestMessage: Codable {
    /// The stream to execute the action on
    let streamID: StreamID
    /// Path to the menu item: [menuIndex, itemIndex, submenuItemIndex, ...]
    let actionPath: [Int]
}

/// Result of menu action execution (Host → Client)
struct MenuActionResultMessage: Codable {
    /// The stream the action was executed on
    let streamID: StreamID
    /// Whether the action was successful
    let success: Bool
    /// Error message if failed
    let errorMessage: String?

    init(streamID: StreamID, success: Bool, errorMessage: String? = nil) {
        self.streamID = streamID
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - Desktop Streaming Messages

/// Request to start streaming the full desktop (Client → Host)
/// This mirrors all physical displays to a single virtual display
struct StartDesktopStreamMessage: Codable {
    /// Preferred quality preset
    let preferredQuality: MirageQualityPreset
    /// Client's display scale factor
    let scaleFactor: CGFloat?
    /// Client's display width in pixels
    let displayWidth: Int
    /// Client's display height in pixels
    let displayHeight: Int
    /// Maximum bitrate in bits per second
    let maxBitrate: Int?
    /// Client-requested keyframe interval in frames
    let keyFrameInterval: Int?
    /// Client-requested encoder quality (0.0-1.0)
    let keyframeQuality: Float?
    /// Client-requested stream scale (0.1-1.0)
    let streamScale: CGFloat?
    /// UDP port the client is listening on for video data
    let dataPort: UInt16?
    /// Client's display maximum refresh rate in Hz (60 or 120)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    let maxRefreshRate: Int
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false
}

/// Request to stop the desktop stream (Client → Host)
struct StopDesktopStreamMessage: Codable {
    /// The desktop stream ID to stop
    let streamID: StreamID
}

/// Confirmation that desktop streaming has started (Host → Client)
struct DesktopStreamStartedMessage: Codable {
    /// Stream ID for the desktop stream
    let streamID: StreamID
    /// Resolution of the virtual display
    let width: Int
    let height: Int
    /// Frame rate of the stream
    let frameRate: Int
    /// Video codec being used
    let codec: MirageVideoCodec
    /// Number of physical displays being mirrored
    let displayCount: Int
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16? = nil
}

/// Desktop stream stopped notification (Host → Client)
struct DesktopStreamStoppedMessage: Codable {
    /// The stream ID that was stopped
    let streamID: StreamID
    /// Why the stream was stopped
    let reason: DesktopStreamStopReason
}

/// Reasons why a desktop stream was stopped
public enum DesktopStreamStopReason: String, Codable, Sendable {
    /// Client requested the stop
    case clientRequested
    /// User started an app stream (mutual exclusivity)
    case appStreamStarted
    /// Host shut down or disconnected
    case hostShutdown
    /// An error occurred
    case error
}
