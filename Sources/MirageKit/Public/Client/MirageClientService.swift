//
//  MirageClientService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation
import Network
import Observation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Main entry point for connecting to and viewing remote windows
@Observable
@MainActor
public final class MirageClientService {
    /// Current connection state
    public internal(set) var connectionState: ConnectionState = .disconnected
    /// Whether the host connection is awaiting manual approval
    public internal(set) var isAwaitingManualApproval: Bool = false

    /// Available windows on the connected host
    public internal(set) var availableWindows: [MirageWindow] = []

    /// Active stream views
    public internal(set) var activeStreams: [ClientStreamSession] = []

    /// Whether we've received the initial window list from the host
    public internal(set) var hasReceivedWindowList: Bool = false

    /// Current session state of the connected host (locked, unlocked, etc.)
    public internal(set) var hostSessionState: HostSessionState?

    /// Current session token from the host (for unlock requests)
    var currentSessionToken: String?

    /// Login display stream ID (when host is locked and streaming login screen)
    public internal(set) var loginDisplayStreamID: StreamID?

    /// Login display resolution
    public internal(set) var loginDisplayResolution: CGSize?

    /// Desktop stream ID (when streaming full virtual display)
    public internal(set) var desktopStreamID: StreamID?

    /// Desktop stream resolution
    public internal(set) var desktopStreamResolution: CGSize?

    /// Desktop stream mode (mirrored vs secondary display)
    public internal(set) var desktopStreamMode: MirageDesktopStreamMode?

    /// Stream scale for post-capture downscaling
    /// 1.0 = native resolution, lower values reduce encoded size
    public var resolutionScale: CGFloat = 1.0

    /// Latency preference for stream buffering behavior.
    public var latencyMode: MirageStreamLatencyMode = .smoothest

    /// Optional refresh rate override sent to the host.
    public var maxRefreshRateOverride: Int?

    /// Callback when desktop stream starts
    public var onDesktopStreamStarted: ((StreamID, CGSize, Int) -> Void)?

    /// Callback when desktop stream stops
    public var onDesktopStreamStopped: ((StreamID, DesktopStreamStopReason) -> Void)?

    /// Handler for minimum window size updates from the host
    public var onStreamMinimumSizeUpdate: ((StreamID, CGSize) -> Void)?

    /// Handler for cursor updates from the host
    public var onCursorUpdate: ((StreamID, MirageCursorType, Bool) -> Void)?

    /// Thread-safe cursor position store for secondary display cursor sync
    public let cursorPositionStore = MirageClientCursorPositionStore()

    /// Callback for content bounds updates (when menus, sheets appear on virtual display)
    public var onContentBoundsUpdate: ((StreamID, CGRect) -> Void)?

    // MARK: - App-Centric Streaming Properties

    /// Available apps on the connected host
    public internal(set) var availableApps: [MirageInstalledApp] = []

    /// Whether we've received the initial app list from the host
    public internal(set) var hasReceivedAppList: Bool = false

    /// Currently streaming app's bundle identifier
    public internal(set) var streamingAppBundleID: String?

    /// Callback when app list is received
    public var onAppListReceived: (([MirageInstalledApp]) -> Void)?

    /// Callback when app streaming starts
    public var onAppStreamStarted: ((String, String, [AppStreamStartedMessage.AppStreamWindow]) -> Void)?

    /// Callback when a new window is added to app stream
    public var onWindowAddedToStream: ((WindowAddedToStreamMessage) -> Void)?

    /// Callback when window cooldown starts
    public var onWindowCooldownStarted: ((WindowCooldownStartedMessage) -> Void)?

    /// Callback when cooldown is cancelled (new window appeared)
    public var onWindowCooldownCancelled: ((WindowCooldownCancelledMessage) -> Void)?

    /// Callback when returning to app selection
    public var onReturnToAppSelection: ((ReturnToAppSelectionMessage) -> Void)?

    /// Callback when app terminates
    public var onAppTerminated: ((AppTerminatedMessage) -> Void)?

    // MARK: - Menu Bar Passthrough Properties

    /// Callback when menu bar structure is received from host
    public var onMenuBarUpdate: ((StreamID, MirageMenuBar?) -> Void)?

    /// Callback when menu action result is received
    public var onMenuActionResult: ((StreamID, Bool, String?) -> Void)?

    /// Client delegate for events
    public weak var delegate: MirageClientDelegate?

    /// iCloud user record ID to send during connection handshake.
    /// Set this before calling connect(to:) to enable iCloud-based auto-trust.
    public var iCloudUserID: String?

    /// Session store for UI state and stream coordination.
    public let sessionStore: MirageClientSessionStore
    /// Metrics store for stream telemetry (decoupled from SwiftUI).
    public let metricsStore = MirageClientMetricsStore()
    /// Cursor store for pointer updates (decoupled from SwiftUI).
    public let cursorStore = MirageClientCursorStore()

    var networkConfig: MirageNetworkConfiguration
    var transport: HybridTransport?
    var connection: NWConnection?
    var connectedHost: MirageHost?
    /// Stable device identifier for the client, persisted in UserDefaults.
    public let deviceID: UUID
    let deviceName: String
    var receiveBuffer = Data()
    var approvalWaitTask: Task<Void, Never>?
    var hasReceivedHelloResponse = false

    // Video receiving
    var udpConnection: NWConnection?
    var hostDataPort: UInt16 = 0

    /// Per-stream controllers for lifecycle management
    /// StreamController owns decoder, reassembler, and resize state machine
    var controllersByStream: [StreamID: StreamController] = [:]

    // Track which streams have been registered with the host (prevents duplicate registrations)
    var registeredStreamIDs: Set<StreamID> = []
    var lastKeyframeRequestTime: [StreamID: CFAbsoluteTime] = [:]
    let keyframeRequestCooldown: CFAbsoluteTime = 0.75
    var desktopStreamRequestStartTime: CFAbsoluteTime = 0
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]
    var streamStartupFirstRegistrationSent: Set<StreamID> = []
    var streamStartupFirstPacketReceived: Set<StreamID> = []

    // MARK: - Quality Test State

    let qualityTestLock = NSLock()
    nonisolated(unsafe) var qualityTestAccumulatorStorage: QualityTestAccumulator?
    nonisolated(unsafe) var qualityTestActiveTestIDStorage: UUID?
    var qualityTestResultContinuation: CheckedContinuation<QualityTestResultMessage?, Never>?
    var qualityTestPendingTestID: UUID?
    var pingContinuation: CheckedContinuation<Void, Error>?

    /// Thread-safe set of active stream IDs for packet filtering from UDP callback
    let activeStreamIDsLock = NSLock()
    nonisolated(unsafe) var activeStreamIDsStorage: Set<StreamID> = []

    /// Thread-safe property to check if a stream is active from nonisolated contexts
    nonisolated var activeStreamIDsForFiltering: Set<StreamID> {
        activeStreamIDsLock.lock()
        defer { activeStreamIDsLock.unlock() }
        return activeStreamIDsStorage
    }

    /// Thread-safe set of streams awaiting a first-packet startup log.
    let startupPacketPendingLock = NSLock()
    nonisolated(unsafe) var startupPacketPendingStorage: Set<StreamID> = []

    nonisolated func isStartupPacketPending(_ streamID: StreamID) -> Bool {
        startupPacketPendingLock.lock()
        defer { startupPacketPendingLock.unlock() }
        return startupPacketPendingStorage.contains(streamID)
    }

    nonisolated func takeStartupPacketPending(_ streamID: StreamID) -> Bool {
        startupPacketPendingLock.lock()
        defer { startupPacketPendingLock.unlock() }
        if startupPacketPendingStorage.contains(streamID) {
            startupPacketPendingStorage.remove(streamID)
            return true
        }
        return false
    }

    func markStartupPacketPending(_ streamID: StreamID) {
        startupPacketPendingLock.lock()
        startupPacketPendingStorage.insert(streamID)
        startupPacketPendingLock.unlock()
    }

    func clearStartupPacketPending(_ streamID: StreamID) {
        startupPacketPendingLock.lock()
        startupPacketPendingStorage.remove(streamID)
        startupPacketPendingLock.unlock()
    }

    /// Thread-safe set of stream IDs where input is blocked (decoder unhealthy)
    /// Input is blocked when the stream is frozen for a sustained interval.
    let inputBlockedStreamIDsLock = NSLock()
    nonisolated(unsafe) var inputBlockedStreamIDsStorage: Set<StreamID> = []

    /// Thread-safe storage for last cursor positions per stream
    /// Used by sendInputReleaseEvents to avoid jumping cursor to center during decode errors
    let lastCursorPositionsLock = NSLock()
    nonisolated(unsafe) var lastCursorPositionsStorage: [StreamID: CGPoint] = [:]

    /// Thread-safe snapshot of reassemblers for packet routing from UDP callback
    let reassemblersLock = NSLock()
    nonisolated(unsafe) var reassemblersSnapshotStorage: [StreamID: FrameReassembler] = [:]

    /// Stream start synchronization - waits for server to assign stream ID
    var streamStartedContinuation: CheckedContinuation<StreamID, Error>?

    /// Minimum window sizes per stream (from host)
    var streamMinSizes: [StreamID: (minWidth: Int, minHeight: Int)] = [:]

    // Per-stream refresh rate overrides (60/120 only).
    var refreshRateOverridesByStream: [StreamID: Int] = [:]
    var refreshRateMismatchCounts: [StreamID: Int] = [:]
    var refreshRateFallbackTargets: [StreamID: Int] = [:]

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(host: String)
        case reconnecting
        case error(String)

        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): true
            case (.connecting, .connecting): true
            case let (.connected(a), .connected(b)): a == b
            case (.reconnecting, .reconnecting): true
            case let (.error(a), .error(b)): a == b
            default: false
            }
        }

        /// Whether this state allows starting a new connection
        public var canConnect: Bool {
            switch self {
            case .disconnected,
                 .error: true
            default: false
            }
        }
    }

    /// UserDefaults key for persisting the device ID
    private static let deviceIDKey = "com.mirage.client.deviceID"

    public init(
        deviceName: String? = nil,
        networkConfiguration: MirageNetworkConfiguration = .default,
        sessionStore: MirageClientSessionStore = MirageClientSessionStore()
    ) {
        #if os(macOS)
        self.deviceName = deviceName ?? Host.current().localizedName ?? "Mac"
        #else
        self.deviceName = deviceName ?? UIDevice.current.name
        #endif

        networkConfig = networkConfiguration
        self.sessionStore = sessionStore

        // Load existing device ID or generate and persist a new one
        if let savedIDString = UserDefaults.standard.string(forKey: Self.deviceIDKey),
           let savedID = UUID(uuidString: savedIDString) {
            deviceID = savedID
            MirageLogger.client("Loaded existing device ID: \(savedID)")
        } else {
            let newID = UUID()
            UserDefaults.standard.set(newID.uuidString, forKey: Self.deviceIDKey)
            deviceID = newID
            MirageLogger.client("Generated new device ID: \(newID)")
        }
        self.sessionStore.clientService = self
    }

    #if os(iOS) || os(visionOS)
    /// Cached drawable size from the Metal view.
    public static var lastKnownDrawableSize: CGSize = .zero
    /// Cached max refresh rate from the active screen (for external display support).
    public static var lastKnownScreenMaxFPS: Int = 0
    #endif
}
