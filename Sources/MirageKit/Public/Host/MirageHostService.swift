//
//  MirageHostService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import Foundation
import Network
import Observation

#if os(macOS)
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Main entry point for hosting window streams (macOS only)
@Observable
@MainActor
public final class MirageHostService {
    /// Available windows for streaming
    public internal(set) var availableWindows: [MirageWindow] = []

    /// Currently active streams
    public internal(set) var activeStreams: [MirageStreamSession] = []

    /// Connected clients
    public internal(set) var connectedClients: [MirageConnectedClient] = []

    // Get all active app streaming sessions

    /// Current host state
    public internal(set) var state: HostState = .idle

    /// Current session state (locked, unlocked, sleeping, etc.)
    public internal(set) var sessionState: HostSessionState = .active

    /// Whether remote unlock is enabled (allows clients to unlock the Mac)
    public var remoteUnlockEnabled: Bool = true

    /// Host delegate for events
    public weak var delegate: MirageHostDelegate?

    /// Trust provider for custom connection approval logic.
    /// When set, the provider is consulted before the delegate for connection approval.
    /// If the provider returns `.trusted`, the connection is auto-approved.
    /// If the provider returns `.requiresApproval` or `.unavailable`, the delegate is consulted.
    /// If the provider returns `.denied`, the connection is rejected immediately.
    public weak var trustProvider: (any MirageTrustProvider)?

    /// Accessibility permission manager for input injection.
    public let permissionManager = MirageAccessibilityPermissionManager()

    /// Window controller for host window management.
    public let windowController = MirageHostWindowController()

    /// Input controller for injecting remote input.
    public let inputController = MirageHostInputController()

    /// Called when host should resize a window before streaming begins.
    /// The callback receives the window and the target size in points.
    /// This allows the app to resize and center the window via Accessibility API.
    public var onResizeWindowForStream: ((MirageWindow, CGSize) -> Void)?

    let advertiser: BonjourAdvertiser
    var udpListener: NWListener?
    let encoderConfig: MirageEncoderConfiguration
    let networkConfig: MirageNetworkConfiguration
    var hostID: UUID = .init()

    // Stream management (internal for extension access)
    var nextStreamID: StreamID = 1
    var streamsByID: [StreamID: StreamContext] = [:]
    var clientsByConnection: [ObjectIdentifier: ClientContext] = [:]
    var clientsByID: [UUID: ClientContext] = [:]
    var singleClientConnectionID: ObjectIdentifier?

    // UDP connections by stream ID (received from client registrations)
    var udpConnectionsByStream: [StreamID: NWConnection] = [:]
    var minimumSizesByWindowID: [WindowID: CGSize] = [:]
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]
    var streamStartupRegistrationLogged: Set<StreamID> = []
    var streamStartupFirstPacketSent: Set<StreamID> = []

    // Quality test connections and tasks
    var qualityTestConnectionsByClientID: [UUID: NWConnection] = [:]
    var qualityTestTasksByClientID: [UUID: Task<Void, Never>] = [:]
    var qualityTestBenchmarkIDsByClientID: [UUID: UUID] = [:]

    // Track first error time per client for graceful disconnect on persistent errors
    // If errors persist past the timeout, disconnect the client.
    var clientFirstErrorTime: [ObjectIdentifier: CFAbsoluteTime] = [:]
    let clientErrorTimeoutSeconds: CFAbsoluteTime = 2.0

    /// Approval timeout to avoid wedging the single-client slot.
    let connectionApprovalTimeoutSeconds: CFAbsoluteTime = 15.0

    // Shared virtual display bounds for synchronous access from AppState
    // Single bounds since all windows share one virtual display
    var sharedVirtualDisplayBounds: CGRect?
    var sharedVirtualDisplayGeneration: UInt64 = 0

    /// Track which windows are using the shared virtual display
    var windowsUsingVirtualDisplay: Set<WindowID> = []

    // Login display stream (lock/login screen) - internal for extension access
    var loginDisplayContext: StreamContext?
    var loginDisplayStreamID: StreamID?
    var loginDisplayResolution: CGSize?
    let loginDisplayInputState = LoginDisplayInputState()
    var loginDisplayStartInProgress = false
    var loginDisplayStartGeneration: UInt64 = 0
    var loginDisplayIsBorrowedStream = false
    var loginDisplayPowerAssertionEnabled = false
    var loginDisplaySharedDisplayConsumerActive = false
    var loginDisplayRetryAttempts: Int = 0
    let loginDisplayRetryLimit: Int = 5
    let loginDisplayRetryDelay: Duration = .seconds(2)
    var loginDisplayRetryTask: Task<Void, Never>?
    var loginDisplayWatchdogTask: Task<Void, Never>?
    var loginDisplayWatchdogGeneration: UInt64 = 0
    var loginDisplayWatchdogStartTime: CFAbsoluteTime = 0
    var lastLoginDisplayRestartTime: CFAbsoluteTime = 0
    let loginDisplayWatchdogInterval: Duration = .seconds(2)
    let loginDisplayWatchdogStartGraceSeconds: CFAbsoluteTime = 4.0
    let loginDisplayWatchdogStaleThresholdSeconds: CFAbsoluteTime = 6.0
    let loginDisplayRestartCooldownSeconds: CFAbsoluteTime = 8.0

    // Desktop stream (full virtual display mirroring) - internal for extension access
    var desktopStreamContext: StreamContext?
    var desktopStreamID: StreamID?
    var desktopStreamClientContext: ClientContext?
    var desktopDisplayBounds: CGRect?
    var desktopVirtualDisplayID: CGDirectDisplayID?
    var desktopUsesVirtualDisplay = false
    var desktopStreamMode: MirageDesktopStreamMode = .mirrored
    var desktopBaseDisplayResolution: CGSize?
    var desktopRequestedStreamScale: CGFloat = 1.0
    var desktopUsesScaledVirtualDisplay = false

    /// Physical displays that were mirrored during desktop streaming (for restoration)
    var mirroredPhysicalDisplayIDs: Set<CGDirectDisplayID> = []
    /// Snapshot of display mirroring state before desktop streaming.
    var desktopMirroringSnapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    /// Primary physical display information captured before mirroring.
    var desktopPrimaryPhysicalDisplayID: CGDirectDisplayID?
    var desktopPrimaryPhysicalBounds: CGRect?

    /// Cursor monitoring - internal for extension access
    var cursorMonitor: CursorMonitor?

    // Session state monitoring (for headless Mac unlock support) - internal for extension access
    var sessionStateMonitor: SessionStateMonitor?
    var unlockManager: UnlockManager?
    var currentSessionToken: String = ""
    var sessionRefreshTask: Task<Void, Never>?
    var sessionRefreshGeneration: UInt64 = 0
    let sessionRefreshInterval: Duration = .seconds(3)

    /// Window activity monitoring (for throttling inactive streams) - internal for extension access
    var windowActivityMonitor: WindowActivityMonitor?

    /// App-centric streaming manager - internal for extension access
    let appStreamManager = AppStreamManager()

    /// Pending app list request to resume after desktop streaming.
    var pendingAppListRequest: PendingAppListRequest?
    var appListRequestTask: Task<Void, Never>?
    var appListRequestToken: UUID = .init()

    /// Menu bar passthrough - internal for extension access
    let menuBarMonitor = MenuBarMonitor()

    /// Window activation (robust multi-method for headless Macs)
    @ObservationIgnored let windowActivator: WindowActivator = .forCurrentEnvironment()

    // MARK: - Fast Input Path (bypasses MainActor)

    /// High-priority queue for input processing - bypasses MainActor for lowest latency
    let inputQueue = DispatchQueue(label: "com.mirage.host.input", qos: .userInteractive)

    /// Thread-safe cache of stream info for fast input routing
    /// Uses a dedicated actor to avoid lock issues in async contexts
    let inputStreamCacheActor = InputStreamCacheActor()

    /// Fast input handler - called on inputQueue, NOT on MainActor
    /// Set this to handle input events with minimal latency
    public var onInputEvent: ((_ event: MirageInputEvent, _ window: MirageWindow, _ client: MirageConnectedClient)
        -> Void)? {
        get { onInputEventStorage }
        set { onInputEventStorage = newValue }
    }

    nonisolated(unsafe) var onInputEventStorage: ((
        _ event: MirageInputEvent,
        _ window: MirageWindow,
        _ client: MirageConnectedClient
    )
        -> Void)?

    public enum HostState: Equatable {
        case idle
        case starting
        case advertising(controlPort: UInt16, dataPort: UInt16)
        case error(String)
    }

    struct PendingAppListRequest: Equatable {
        let clientID: UUID
        var requestedIcons: Bool
    }

    public init(
        hostName: String? = nil,
        deviceID: UUID? = nil,
        encoderConfiguration: MirageEncoderConfiguration = .highQuality,
        networkConfiguration: MirageNetworkConfiguration = .default
    ) {
        let name = hostName ?? Host.current().localizedName ?? "Mac"
        let capabilities = MirageHostCapabilities(
            maxStreams: 4,
            supportsHEVC: true,
            supportsP3ColorSpace: true,
            maxFrameRate: 120,
            protocolVersion: Int(MirageKit.protocolVersion),
            deviceID: deviceID
        )

        advertiser = BonjourAdvertiser(
            serviceName: name,
            capabilities: capabilities,
            enablePeerToPeer: networkConfiguration.enablePeerToPeer
        )
        encoderConfig = encoderConfiguration
        networkConfig = networkConfiguration

        windowController.hostService = self
        inputController.hostService = self
        inputController.windowController = windowController
        inputController.permissionManager = permissionManager

        onResizeWindowForStream = { [weak windowController] window, size in
            windowController?.resizeAndCenterWindowForStream(window, targetSize: size)
        }
    }

    /// Resolve input bounds for desktop streaming based on physical display size.
    /// When mirroring a virtual display with a different aspect ratio, the mirrored
    /// content is aspect-fit within the physical display and input should target
    /// that content rect (not the full physical bounds).
    func resolvedDesktopInputBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?
    )
    -> CGRect {
        if desktopStreamMode == .secondary, let bounds = resolveDesktopDisplayBounds() { return bounds }

        guard desktopUsesVirtualDisplay,
              let virtualResolution,
              virtualResolution.width > 0,
              virtualResolution.height > 0 else {
            return physicalBounds
        }

        let contentAspect = virtualResolution.width / virtualResolution.height
        let boundsAspect = physicalBounds.width / physicalBounds.height
        var fittedSize = physicalBounds.size

        if boundsAspect > contentAspect {
            fittedSize.height = physicalBounds.height
            fittedSize.width = fittedSize.height * contentAspect
        } else {
            fittedSize.width = physicalBounds.width
            fittedSize.height = fittedSize.width / contentAspect
        }

        let horizontalInset = max(0, physicalBounds.width - fittedSize.width)
        let verticalInset = max(0, physicalBounds.height - fittedSize.height)
        let origin = CGPoint(
            x: physicalBounds.origin.x + horizontalInset * 0.5,
            y: physicalBounds.origin.y + verticalInset
        )
        return CGRect(origin: origin, size: fittedSize)
    }

    func resolvedDesktopVirtualDisplayResolution(
        baseResolution: CGSize,
        streamScale: CGFloat
    )
    -> CGSize {
        guard baseResolution.width > 0, baseResolution.height > 0 else { return baseResolution }
        let clampedScale = StreamContext.clampStreamScale(streamScale)
        let width = StreamContext.alignedEvenPixel(baseResolution.width * clampedScale)
        let height = StreamContext.alignedEvenPixel(baseResolution.height * clampedScale)
        return CGSize(width: width, height: height)
    }

    /// Resolve the current virtual display bounds for secondary desktop streaming.
    /// Uses CoreGraphics coordinates for input injection.
    func resolveDesktopDisplayBounds() -> CGRect? {
        guard let displayID = desktopVirtualDisplayID else { return desktopDisplayBounds }
        let bounds = CGDisplayBounds(displayID)
        if bounds.width > 0, bounds.height > 0 { return bounds }
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let size = CGSize(width: CGFloat(mode.width), height: CGFloat(mode.height))
            return CGRect(origin: bounds.origin, size: size)
        }
        return desktopDisplayBounds
    }

    /// Resolve the current virtual display bounds for cursor monitoring (Cocoa coordinates).
    func resolveDesktopDisplayBoundsForCursorMonitor() -> CGRect? {
        if let displayID = desktopVirtualDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen.frame
        }
        let bounds: CGRect?
        if let displayID = desktopVirtualDisplayID {
            let cgBounds = CGDisplayBounds(displayID)
            bounds = (cgBounds.width > 0 && cgBounds.height > 0) ? cgBounds : nil
        } else {
            bounds = desktopDisplayBounds
        }
        guard let bounds, let mainScreen = NSScreen.main else { return nil }
        let cocoaY = mainScreen.frame.height - bounds.origin.y - bounds.height
        return CGRect(x: bounds.origin.x, y: cocoaY, width: bounds.width, height: bounds.height)
    }

    /// Refresh cached physical display bounds after mirroring changes.
    /// Returns the updated physical bounds.
    func refreshDesktopPrimaryPhysicalBounds() -> CGRect {
        let displayID = desktopPrimaryPhysicalDisplayID
            ?? resolvePrimaryPhysicalDisplayID()
            ?? CGMainDisplayID()
        desktopPrimaryPhysicalDisplayID = displayID
        let bounds = CGDisplayBounds(displayID)
        desktopPrimaryPhysicalBounds = bounds
        return bounds
    }

    // Start hosting and advertising

    // Refresh session state on demand and apply any changes immediately.

    // Send session state to a specific client

    // Send window list to a specific client

    // Stop hosting

    // End streaming for a specific app
    // - Parameter bundleIdentifier: The bundle identifier of the app to stop streaming

    // Refresh available windows list

    /// Start streaming a window
    /// - Parameters:
    ///   - window: The window to stream
    ///   - client: The client to stream to
    ///   - dataPort: Optional UDP port for video data
    ///   - clientDisplayResolution: Client's display resolution for virtual display sizing
    ///   - keyFrameInterval: Optional client-requested keyframe interval (in frames)
    ///   - colorSpace: Optional color space override for capture and encode
    ///   - captureQueueDepth: Optional ScreenCaptureKit queue depth override
    ///   - minBitrate: Optional minimum target bitrate (bits per second)
    ///   - maxBitrate: Optional maximum target bitrate (bits per second)
    ///   - targetFrameRate: Optional frame rate override (60/120 based on client capability)
    ///   - pixelFormat: Optional pixel format override for capture and encode
    // TODO: HDR support - requires proper virtual display EDR configuration
    // ///   - hdr: Whether to enable HDR streaming (Rec. 2020 with PQ transfer function)

    // Stop a stream
    // - Parameters:
    //   - session: The stream session to stop
    //   - minimizeWindow: Whether to minimize the source window after stopping (default: false)

    // Notify that a window has been resized - updates the stream to match new dimensions
    // Always encodes at host's native resolution for maximum quality
    // - Parameters:
    //   - window: The window that was resized (contains the new frame)

    // Notify that a window has been resized (convenience overload that ignores preferredPixelSize)
    // Always encodes at host's native resolution for maximum quality
    // - Parameters:
    //   - window: The window that was resized (contains the new frame)
    //   - preferredPixelSize: Ignored - kept for API compatibility

    // Update capture resolution to match client's exact pixel dimensions
    // This allows encoding at the client's native resolution regardless of host window size
    // - Parameters:
    //   - windowID: The window whose stream should be updated
    //   - width: Target pixel width (client's drawable width)
    //   - height: Target pixel height (client's drawable height)

    // Disconnect a client

    // Activate the application and raise the window being streamed.
    // Uses robust multi-method activation that works on headless Macs.

    // Find the AXUIElement for a specific window using its known ID

    // MARK: - Private
}

#endif
