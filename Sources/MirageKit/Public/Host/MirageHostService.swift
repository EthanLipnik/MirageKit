//
//  MirageHostService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import Observation
import CoreMedia

#if os(macOS)
import ScreenCaptureKit
import AppKit
import ApplicationServices

// MARK: - Login Display Input State (thread-safe)

final class LoginDisplayInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var streamID: StreamID?
    private var bounds: CGRect = .zero
    private var lastCursorPosition: CGPoint = .zero
    private var hasCursorPosition = false

    func update(streamID: StreamID, bounds: CGRect) {
        lock.lock()
        self.streamID = streamID
        self.bounds = bounds
        self.lastCursorPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        self.hasCursorPosition = false
        lock.unlock()
        MirageLogger.host("LoginDisplayInputState registered: streamID=\(streamID), bounds=\(bounds)")
    }

    func clear() {
        lock.lock()
        let previousID = streamID
        streamID = nil
        bounds = .zero
        hasCursorPosition = false
        lock.unlock()
        if let previousID {
            MirageLogger.host("LoginDisplayInputState cleared: was streamID=\(previousID)")
        }
    }

    func getInfo(for streamID: StreamID) -> (bounds: CGRect, lastCursorPosition: CGPoint, hasCursorPosition: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedID = self.streamID, storedID == streamID else {
            // Only log when there's a mismatch, not when login display is simply not active
            // This avoids spam during normal desktop/window streaming
            return nil
        }
        return (bounds, lastCursorPosition, hasCursorPosition)
    }

    func updateCursorPosition(_ point: CGPoint) {
        lock.lock()
        lastCursorPosition = point
        hasCursorPosition = true
        lock.unlock()
    }
}

/// Main entry point for hosting window streams (macOS only)
@Observable
@MainActor
public final class MirageHostService {
    /// Available windows for streaming
    public private(set) var availableWindows: [MirageWindow] = []

    /// Currently active streams
    public private(set) var activeStreams: [MirageStreamSession] = []

    /// Connected clients
    public private(set) var connectedClients: [MirageConnectedClient] = []

    /// Get all active app streaming sessions
    public func getActiveStreamingSessions() async -> [MirageAppStreamSession] {
        await appStreamManager.getAllSessions()
    }

    /// Current host state
    public private(set) var state: HostState = .idle

    /// Current session state (locked, unlocked, sleeping, etc.)
    public internal(set) var sessionState: HostSessionState = .active

    /// Whether remote unlock is enabled (allows clients to unlock the Mac)
    public var remoteUnlockEnabled: Bool = true

    /// Host delegate for events
    public weak var delegate: MirageHostDelegate?

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

    private let advertiser: BonjourAdvertiser
    var udpListener: NWListener?
    let encoderConfig: MirageEncoderConfiguration
    let networkConfig: MirageNetworkConfiguration
    var hostID: UUID = UUID()

    // Stream management (internal for extension access)
    var nextStreamID: StreamID = 1
    var streamsByID: [StreamID: StreamContext] = [:]
    var clientsByConnection: [ObjectIdentifier: ClientContext] = [:]

    // UDP connections by stream ID (received from client registrations)
    var udpConnectionsByStream: [StreamID: NWConnection] = [:]
    private var minimumSizesByWindowID: [WindowID: CGSize] = [:]

    // Track first error time per client for graceful disconnect on persistent errors
    // If errors persist for 5+ seconds, disconnect the client
    private var clientFirstErrorTime: [ObjectIdentifier: CFAbsoluteTime] = [:]
    private let clientErrorTimeoutSeconds: CFAbsoluteTime = 5.0

    /// Check if an error indicates a fatal, unrecoverable connection state.
    /// Fatal errors mean the TCP socket is dead and no further data will be received.
    private func isFatalConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // POSIX errors indicating connection is dead:
        // 54 = ECONNRESET (Connection reset by peer)
        // 57 = ENOTCONN (Socket is not connected)
        // 32 = EPIPE (Broken pipe)
        // 104 = ECONNRESET on Linux
        let fatalPosixCodes = [54, 57, 32, 104]
        if nsError.domain == NSPOSIXErrorDomain && fatalPosixCodes.contains(nsError.code) {
            return true
        }
        // Network framework errors for cancelled/failed connections
        if nsError.domain == "NWError" && (nsError.code == -65554 || nsError.code == -65555) {
            return true
        }
        return false
    }

    // Shared virtual display bounds for synchronous access from AppState
    // Single bounds since all windows share one virtual display
    var sharedVirtualDisplayBounds: CGRect?

    // Track which windows are using the shared virtual display
    var windowsUsingVirtualDisplay: Set<WindowID> = []

    // Login display stream (lock/login screen) - internal for extension access
    var loginDisplayContext: StreamContext?
    var loginDisplayStreamID: StreamID?
    var loginDisplayResolution: CGSize?
    let loginDisplayInputState = LoginDisplayInputState()

    // Desktop stream (full virtual display mirroring) - internal for extension access
    var desktopStreamContext: StreamContext?
    var desktopStreamID: StreamID?
    var desktopStreamClientContext: ClientContext?
    var desktopDisplayBounds: CGRect?
    var desktopUsesVirtualDisplay = false

    /// Physical displays that were mirrored during desktop streaming (for restoration)
    var mirroredPhysicalDisplayIDs: Set<CGDirectDisplayID> = []

    // Cursor monitoring - internal for extension access
    var cursorMonitor: CursorMonitor?

    // Session state monitoring (for headless Mac unlock support) - internal for extension access
    var sessionStateMonitor: SessionStateMonitor?
    var unlockManager: UnlockManager?
    var currentSessionToken: String = ""

    // Window activity monitoring (for throttling inactive streams) - internal for extension access
    var windowActivityMonitor: WindowActivityMonitor?

    // App-centric streaming manager - internal for extension access
    let appStreamManager = AppStreamManager()

    // Menu bar passthrough - internal for extension access
    let menuBarMonitor = MenuBarMonitor()

    // Window activation (robust multi-method for headless Macs)
    @ObservationIgnored
    private let windowActivator: WindowActivator = WindowActivator.forCurrentEnvironment()

    // MARK: - Fast Input Path (bypasses MainActor)

    /// High-priority queue for input processing - bypasses MainActor for lowest latency
    private let inputQueue = DispatchQueue(label: "com.mirage.host.input", qos: .userInteractive)

    /// Thread-safe cache of stream info for fast input routing
    /// Uses a dedicated actor to avoid lock issues in async contexts
    let inputStreamCacheActor = InputStreamCacheActor()

    /// Fast input handler - called on inputQueue, NOT on MainActor
    /// Set this to handle input events with minimal latency
    public var onInputEvent: ((_ event: MirageInputEvent, _ window: MirageWindow, _ client: MirageConnectedClient) -> Void)? {
        get { _onInputEvent }
        set { _onInputEvent = newValue }
    }
    private nonisolated(unsafe) var _onInputEvent: ((_ event: MirageInputEvent, _ window: MirageWindow, _ client: MirageConnectedClient) -> Void)?

    public enum HostState: Equatable {
        case idle
        case starting
        case advertising(controlPort: UInt16, dataPort: UInt16)
        case error(String)
    }

    public init(
        hostName: String? = nil,
        encoderConfiguration: MirageEncoderConfiguration = .highQuality,
        networkConfiguration: MirageNetworkConfiguration = .default
    ) {
        let name = hostName ?? Host.current().localizedName ?? "Mac"
        let capabilities = MirageHostCapabilities(
            maxStreams: 4,
            supportsHEVC: true,
            supportsP3ColorSpace: true,
            maxFrameRate: 120,
            protocolVersion: Int(MirageKit.protocolVersion)
        )

        self.advertiser = BonjourAdvertiser(
            serviceName: name,
            capabilities: capabilities,
            enablePeerToPeer: networkConfiguration.enablePeerToPeer
        )
        self.encoderConfig = encoderConfiguration
        self.networkConfig = networkConfiguration

        windowController.hostService = self
        inputController.hostService = self
        inputController.windowController = windowController
        inputController.permissionManager = permissionManager

        onResizeWindowForStream = { [weak windowController] window, size in
            windowController?.resizeAndCenterWindowForStream(window, targetSize: size)
        }
    }

    /// Start hosting and advertising
    public func start() async throws {
        guard state == .idle else {
            MirageLogger.host("Already started, state: \(state)")
            return
        }

        state = .starting
        MirageLogger.host("Starting...")

        do {
            // Start TCP listener for control connections (handler passed directly)
            MirageLogger.host("Starting TCP listener on port \(networkConfig.controlPort)...")
            let controlPort = try await advertiser.start(port: networkConfig.controlPort) { [weak self] connection in
                Task { @MainActor [weak self] in
                    await self?.handleNewConnection(connection)
                }
            }
            MirageLogger.host("TCP listener started on port \(controlPort)")

            // Start UDP listener for data
            MirageLogger.host("Starting UDP listener...")
            let dataPort = try await startDataListener()
            MirageLogger.host("UDP listener started on port \(dataPort)")

            state = .advertising(controlPort: controlPort, dataPort: dataPort)
            MirageLogger.host("Now advertising on control:\(controlPort) data:\(dataPort)")

            // Set up app streaming callbacks
            setupAppStreamManagerCallbacks()
        } catch {
            MirageLogger.error(.host, "Failed to start: \(error)")
            state = .error(error.localizedDescription)
            throw error
        }

        // Initial window refresh (non-blocking - may fail if no screen recording permission)
        do {
            try await refreshWindows()
            MirageLogger.host("Window refresh complete, found \(availableWindows.count) windows")
        } catch {
            MirageLogger.host("Initial window refresh failed (screen recording permission may be needed): \(error)")
        }

        // Start cursor monitoring for active streams
        startCursorMonitoring()

        // Start session state monitoring (for headless Mac unlock support)
        await startSessionStateMonitoring()
    }

    /// Refresh session state on demand and apply any changes immediately.
    func refreshSessionStateIfNeeded() async {
        guard let sessionStateMonitor else { return }
        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState {
            await handleSessionStateChange(refreshed)
        }
    }

    /// Send session state to a specific client
    func sendSessionState(to clientContext: ClientContext) async {
        let message = SessionStateUpdateMessage(
            state: sessionState,
            sessionToken: currentSessionToken,
            requiresUsername: sessionState.requiresUsername,
            timestamp: Date()
        )

        do {
            try await clientContext.send(.sessionStateUpdate, content: message)
        } catch {
            MirageLogger.error(.host, "Failed to send session state: \(error)")
        }
    }

    /// Send window list to a specific client
    func sendWindowList(to clientContext: ClientContext) async {
        do {
            let windowList = WindowListMessage(windows: availableWindows)
            try await clientContext.send(.windowList, content: windowList)
            MirageLogger.host("Sent window list with \(availableWindows.count) windows")
        } catch {
            MirageLogger.error(.host, "Failed to send window list: \(error)")
        }
    }

    /// Stop hosting
    public func stop() async {
        // Stop cursor monitoring
        await cursorMonitor?.stop()
        cursorMonitor = nil

        // Stop all streams
        for stream in activeStreams {
            await stopStream(stream)
        }

        // Disconnect all clients
        for client in connectedClients {
            await disconnectClient(client)
        }

        // Force release power assertion on full stop
        await PowerAssertionManager.shared.forceDisable()

        await advertiser.stop()
        udpListener?.cancel()
        udpListener = nil

        state = .idle
    }

    /// End streaming for a specific app
    /// - Parameter bundleIdentifier: The bundle identifier of the app to stop streaming
    public func endAppStream(bundleIdentifier: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else {
            return
        }

        let windowIDs = Array(session.windowStreams.keys)

        // Stop all window streams for this app
        for windowID in windowIDs {
            if let stream = activeStreams.first(where: { $0.window.id == windowID }) {
                await stopStream(stream)
            }
        }

        // Notify client that the app stream has ended
        var clientContext: ClientContext?
        for context in clientsByConnection.values {
            if context.client.id == session.clientID {
                clientContext = context
                break
            }
        }

        if let clientContext {
            // Check if client has other active sessions
            let allSessions = await appStreamManager.getAllSessions()
            let hasRemaining = allSessions.contains { sess in
                sess.clientID == session.clientID && sess.bundleIdentifier != bundleIdentifier
            }

            let message = AppTerminatedMessage(
                bundleIdentifier: bundleIdentifier,
                closedWindowIDs: windowIDs,
                hasRemainingWindows: hasRemaining
            )
            if let controlMessage = try? ControlMessage(type: .appTerminated, content: message) {
                let data = controlMessage.serialize()
                clientContext.tcpConnection.send(content: data, completion: NWConnection.SendCompletion.contentProcessed { _ in })
            }
        }

        // End the session
        await appStreamManager.endSession(bundleIdentifier: bundleIdentifier)

        MirageLogger.host("Ended app stream for \(bundleIdentifier)")
    }

    /// Refresh available windows list
    public func refreshWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false  // Include minimized/off-screen windows
        )

        // Fetch extended metadata for alpha and visibility filtering
        let metadata = fetchWindowMetadata()

        var windows: [MirageWindow] = []

        for scWindow in content.windows {
            // Skip small windows (hidden processes, system UI) - minimum 200x150
            guard scWindow.frame.width >= 200, scWindow.frame.height >= 150 else { continue }

            // Skip windows without titles (auxiliary panels, popovers, floating UI)
            guard let title = scWindow.title, !title.isEmpty else { continue }

            // Skip non-standard window layers (layer 0 = normal windows)
            guard scWindow.windowLayer == 0 else { continue }

            // Skip windows without an owning application
            guard let scApp = scWindow.owningApplication else { continue }

            // Skip invisible windows (alpha near zero) - keeps minimized windows which have normal alpha
            if let windowMeta = metadata[CGWindowID(scWindow.windowID)], windowMeta.alpha < 0.01 {
                continue
            }

            let app = MirageApplication(
                id: scApp.processID,
                bundleIdentifier: scApp.bundleIdentifier,
                name: scApp.applicationName,
                iconData: nil
            )

            let window = MirageWindow(
                id: WindowID(scWindow.windowID),
                title: scWindow.title,
                application: app,
                frame: scWindow.frame,
                isOnScreen: scWindow.isOnScreen,
                windowLayer: Int(scWindow.windowLayer)
            )

            windows.append(window)
        }

        // Collapse tabbed windows into single entries (tabs share the same frame)
        let filteredWindows = detectAndCollapseTabGroups(windows, metadata: metadata)

        availableWindows = filteredWindows.sorted { ($0.application?.name ?? "") < ($1.application?.name ?? "") }
    }

    /// Start streaming a window
    /// - Parameters:
    ///   - window: The window to stream
    ///   - client: The client to stream to
    ///   - dataPort: Optional UDP port for video data
    ///   - clientDisplayResolution: Client's display resolution for virtual display sizing
    ///   - keyFrameInterval: Optional client-requested keyframe interval (in frames)
    ///   - frameQuality: Optional client-requested inter-frame quality (0.0-1.0)
    ///   - keyframeQuality: Optional client-requested keyframe quality (0.0-1.0)
    ///   - qualityPreset: Optional preset for latency-sensitive defaults
    ///   - colorSpace: Optional color space override for capture and encode
    ///   - captureQueueDepth: Optional ScreenCaptureKit queue depth override
    ///   - minBitrate: Optional minimum target bitrate (bits per second)
    ///   - maxBitrate: Optional maximum target bitrate (bits per second)
    ///   - targetFrameRate: Optional frame rate override (60 or 120fps, based on client capability and quality)
    ///   - pixelFormat: Optional pixel format override for capture and encode
    ///   - adaptiveScaleEnabled: Optional toggle for adaptive stream scaling
    // TODO: HDR support - requires proper virtual display EDR configuration
    // ///   - hdr: Whether to enable HDR streaming (Rec. 2020 with PQ transfer function)
    public func startStream(
        for window: MirageWindow,
        to client: MirageConnectedClient,
        dataPort: UInt16? = nil,
        clientDisplayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        frameQuality: Float? = nil,
        keyframeQuality: Float? = nil,
        streamScale: CGFloat? = nil,
        adaptiveScaleEnabled: Bool? = nil,
        qualityPreset: MirageQualityPreset? = nil,
        targetFrameRate: Int? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        captureQueueDepth: Int? = nil,
        minBitrate: Int? = nil,
        maxBitrate: Int? = nil
        // hdr: Bool = false
    ) async throws -> MirageStreamSession {
        // Get the actual SCWindow, its owning application, and the display it's on
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw MirageError.windowNotFound
        }

        // Get the owning application (needed for app-level capture that includes alerts/sheets)
        guard let scApplication = scWindow.owningApplication else {
            throw MirageError.protocolError("Window has no owning application")
        }

        // Find the display containing this window (needed for app-level capture filter)
        guard let scDisplay = content.displays.first(where: { display in
            display.frame.contains(CGPoint(x: scWindow.frame.midX, y: scWindow.frame.midY))
        }) ?? content.displays.first else {
            throw MirageError.protocolError("No display found for window")
        }

        let streamID = nextStreamID
        nextStreamID += 1

        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: latestFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        let session = MirageStreamSession(
            id: streamID,
            window: updatedWindow,
            client: client
        )

        // Create encoder config with client-requested overrides
        var effectiveEncoderConfig: MirageEncoderConfiguration
        if keyFrameInterval != nil || frameQuality != nil || keyframeQuality != nil || pixelFormat != nil || colorSpace != nil || captureQueueDepth != nil || minBitrate != nil || maxBitrate != nil {
            effectiveEncoderConfig = encoderConfig.withOverrides(
                keyFrameInterval: keyFrameInterval,
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                pixelFormat: pixelFormat,
                colorSpace: colorSpace,
                captureQueueDepth: captureQueueDepth,
                minBitrate: minBitrate,
                maxBitrate: maxBitrate
            )
            if let interval = keyFrameInterval {
                MirageLogger.host("Using client-requested keyframe interval: \(interval) frames")
            }
            if let quality = frameQuality {
                MirageLogger.host("Using client-requested frame quality: \(quality)")
            }
            if let quality = keyframeQuality {
                MirageLogger.host("Using client-requested keyframe quality: \(quality)")
            }
            if let colorSpace {
                MirageLogger.host("Using client-requested color space: \(colorSpace.displayName)")
            }
            if let captureQueueDepth {
                MirageLogger.host("Using client-requested capture queue depth: \(captureQueueDepth)")
            }
            if let minBitrate {
                MirageLogger.host("Using client-requested minimum bitrate: \(minBitrate)")
            }
            if let maxBitrate {
                MirageLogger.host("Using client-requested maximum bitrate: \(maxBitrate)")
            }
        } else {
            effectiveEncoderConfig = encoderConfig
        }

        // Apply target frame rate override if specified (based on P2P + client capability)
        if let targetFrameRate {
            effectiveEncoderConfig = effectiveEncoderConfig.withTargetFrameRate(targetFrameRate)
            MirageLogger.host("Using target frame rate: \(targetFrameRate)fps")
        }

        // TODO: HDR support - requires proper virtual display EDR configuration
        // Apply HDR color space if requested
        // if hdr {
        //     effectiveEncoderConfig.colorSpace = .hdr
        //     MirageLogger.host("HDR streaming enabled (Rec. 2020 + PQ)")
        // }

        // Create stream context with capture and encoding
        let context = StreamContext(
            streamID: streamID,
            windowID: window.id,
            encoderConfig: effectiveEncoderConfig,
            qualityPreset: qualityPreset,
            streamScale: streamScale ?? 1.0,
            maxPacketSize: networkConfig.maxPacketSize,
            adaptiveScaleEnabled: adaptiveScaleEnabled ?? true
        )
        await context.setMetricsUpdateHandler { [weak self] metrics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let clientContext = self.findClientContext(clientID: client.id) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    MirageLogger.error(.host, "Failed to send stream metrics: \(error)")
                }
            }
        }
        await context.setStreamScaleUpdateHandler { [weak self] streamID in
            Task { @MainActor [weak self] in
                await self?.sendStreamScaleUpdate(streamID: streamID)
            }
        }

        streamsByID[streamID] = context
        activeStreams.append(session)

        // Enable power assertion to prevent display sleep during streaming
        await PowerAssertionManager.shared.enable()

        // Add window to activity monitor for throttling inactive streams
        await addWindowToActivityMonitor(window.id)

        // Update input cache for fast input routing (thread-safe)
        inputStreamCacheActor.set(streamID, window: updatedWindow, client: client)

        // UDP connection will be set when client sends registration via UDP
        // The client connects to our data port and registers with the stream ID

        // Wrap ScreenCaptureKit types for safe sending across actor boundary
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let applicationWrapper = SCApplicationWrapper(application: scApplication)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        // Start capture with callback to send video data
        // This will throw if screen recording permission is not granted
        do {
            // Use virtual display if client provides display resolution, otherwise use legacy window capture
            if let displayResolution = clientDisplayResolution, displayResolution.width > 0, displayResolution.height > 0 {
                // Virtual display mode - captures entire virtual display at client resolution
                MirageLogger.host("Starting stream with virtual display at \(Int(displayResolution.width))x\(Int(displayResolution.height))")

                try await context.startWithVirtualDisplay(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    clientDisplayResolution: displayResolution,
                    onEncodedFrame: { [weak self] packetData, header in
                        guard let self else { return }
                        Task { @MainActor in
                            self.sendVideoPacketForStream(streamID, data: packetData)
                        }
                    },
                    onContentBoundsChanged: { [weak self] bounds in
                        guard let self else { return }
                        Task { @MainActor in
                            await self.sendContentBoundsUpdate(streamID: streamID, bounds: bounds, to: client)
                        }
                    },
                    onNewWindowDetected: { [weak self] newWindow in
                        guard let self else { return }
                        Task { @MainActor in
                            // Auto-stream new independent windows to the same client
                            await self.handleNewIndependentWindow(newWindow, originalStreamID: streamID, client: client)
                        }
                    },
                    onVirtualDisplayReady: { [weak self] bounds in
                        // CRITICAL: Cache bounds IMMEDIATELY when display is ready
                        // This is awaited by StreamContext, ensuring it completes BEFORE
                        // window movement or capture setup - preventing race condition
                        // where the window centering timer fires before bounds are cached
                        guard let self else { return }
                        await MainActor.run {
                            self.sharedVirtualDisplayBounds = bounds
                            self.windowsUsingVirtualDisplay.insert(window.id)
                            MirageLogger.host("Cached virtual display bounds immediately: \(bounds)")
                        }
                    }
                )

                // Update input cache with window's new frame after moving to virtual display
                // Use the known virtual display bounds to avoid stale CGWindowList values
                if let bounds = sharedVirtualDisplayBounds {
                    let newFrame = CGRect(origin: bounds.origin, size: updatedWindow.frame.size)
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
                } else if let newFrame = currentWindowFrame(for: window.id) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
                }
            } else {
                // Legacy window capture mode
                try await context.start(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    displayWrapper: displayWrapper
                ) { [weak self] packetData, header in
                    guard let self else { return }
                    Task { @MainActor in
                        self.sendVideoPacketForStream(streamID, data: packetData)
                    }
                }
            }
        } catch {
            // Capture failed (likely permission issue) - clean up and rethrow
            MirageLogger.error(.host, "Failed to start capture: \(error)")
            streamsByID.removeValue(forKey: streamID)
            activeStreams.removeAll { $0.id == streamID }
            throw error
        }

        // Activate the window/app being streamed
        // This ensures the window receives input correctly, even on virtual displays
        activateWindow(updatedWindow)

        // Only notify client AFTER capture successfully started
        if let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) {
            let minSize = minimumSizesByWindowID[updatedWindow.id]
            let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
            let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
            let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

            let encodedDimensions = await context.getEncodedDimensions()
            let targetFrameRate = await context.getTargetFrameRate()
            let codec = await context.getCodec()

            // Get dimension token from stream context
            let dimensionToken = await context.getDimensionToken()

            let message = StreamStartedMessage(
                streamID: streamID,
                windowID: window.id,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: targetFrameRate,
                codec: codec,
                minWidth: minWidth,
                minHeight: minHeight,
                dimensionToken: dimensionToken
            )
            try await clientContext.send(.streamStarted, content: message)
        }

        // Start menu bar monitoring for this stream
        if let app = updatedWindow.application {
            await startMenuBarMonitoring(streamID: streamID, app: app, client: client)
        }

        return session
    }

    /// Stop a stream
    /// - Parameters:
    ///   - session: The stream session to stop
    ///   - minimizeWindow: Whether to minimize the source window after stopping (default: false)
    public func stopStream(_ session: MirageStreamSession, minimizeWindow: Bool = false) async {
        guard let context = streamsByID[session.id] else { return }

        // Stop menu bar monitoring for this stream
        await stopMenuBarMonitoring(streamID: session.id)

        // Capture window ID before cleanup for minimize
        let windowID = session.window.id

        // Remove window from activity monitor
        await windowActivityMonitor?.removeWindow(windowID)

        // Remove window from virtual display tracking
        windowsUsingVirtualDisplay.remove(windowID)

        // Clear shared bounds if no more windows using virtual display
        if windowsUsingVirtualDisplay.isEmpty {
            sharedVirtualDisplayBounds = nil
        }

        await context.stop()
        streamsByID.removeValue(forKey: session.id)
        activeStreams.removeAll { $0.id == session.id }

        // Remove from input cache (thread-safe)
        inputStreamCacheActor.remove(session.id)

        // Clean up UDP connection for this stream
        if let udpConnection = udpConnectionsByStream.removeValue(forKey: session.id) {
            udpConnection.cancel()
        }

        // Minimize the window if requested (after stopping capture so window is restored from virtual display)
        if minimizeWindow {
            WindowManager.minimizeWindow(windowID)
        }

        if activeStreams.isEmpty {
            // Stop activity monitor when no more streams are active
            await windowActivityMonitor?.stop()
            windowActivityMonitor = nil

            // Disable power assertion when no more streams are active (including login display)
            if loginDisplayStreamID == nil {
                await PowerAssertionManager.shared.disable()
            }
        }
    }

    /// Notify that a window has been resized - updates the stream to match new dimensions
    /// Always encodes at host's native resolution for maximum quality
    /// - Parameters:
    ///   - window: The window that was resized (contains the new frame)
    public func notifyWindowResized(_ window: MirageWindow) async {
        // Find any active streams for this window and update their dimensions
        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: latestFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        for index in activeStreams.indices where activeStreams[index].window.id == window.id {
            let session = activeStreams[index]
            guard let context = streamsByID[session.id] else { continue }

            activeStreams[index] = MirageStreamSession(
                id: session.id,
                window: updatedWindow,
                client: session.client
            )

            // Update input cache with new frame - critical for mouse coordinate translation
            inputStreamCacheActor.updateWindowFrame(session.id, newFrame: latestFrame)

            do {
                // Update capture/encoder to scaled resolution
                try await context.updateDimensions(windowFrame: updatedWindow.frame)

                let encodedDimensions = await context.getEncodedDimensions()
                let targetFrameRate = await context.getTargetFrameRate()
                let codec = await context.getCodec()

                // Get updated dimension token after resize
                let dimensionToken = await context.getDimensionToken()

                if let clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id }) {
                    let minSize = minimumSizesByWindowID[updatedWindow.id]
                    let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
                    let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                    let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                    let message = StreamStartedMessage(
                        streamID: session.id,
                        windowID: window.id,
                        width: encodedDimensions.width,
                        height: encodedDimensions.height,
                        frameRate: targetFrameRate,
                        codec: codec,
                        minWidth: minWidth,
                        minHeight: minHeight,
                        dimensionToken: dimensionToken
                    )
                    try await clientContext.send(.streamStarted, content: message)
                    MirageLogger.host("Encoding at scaled resolution: \(encodedDimensions.width)x\(encodedDimensions.height)")
                }
            } catch {
                MirageLogger.error(.host, "Failed to update stream dimensions: \(error)")
            }
        }
    }

    /// Notify that a window has been resized (convenience overload that ignores preferredPixelSize)
    /// Always encodes at host's native resolution for maximum quality
    /// - Parameters:
    ///   - window: The window that was resized (contains the new frame)
    ///   - preferredPixelSize: Ignored - kept for API compatibility
    public func notifyWindowResized(_ window: MirageWindow, preferredPixelSize: CGSize?) async {
        // preferredPixelSize is ignored - we always encode at native resolution
        await notifyWindowResized(window)
    }

    /// Update capture resolution to match client's exact pixel dimensions
    /// This allows encoding at the client's native resolution regardless of host window size
    /// - Parameters:
    ///   - windowID: The window whose stream should be updated
    ///   - width: Target pixel width (client's drawable width)
    ///   - height: Target pixel height (client's drawable height)
    public func updateCaptureResolution(for windowID: WindowID, width: Int, height: Int) async {
        // Find the stream for this window
        guard let session = activeStreams.first(where: { $0.window.id == windowID }),
              let context = streamsByID[session.id] else {
            MirageLogger.host("No active stream found for window \(windowID)")
            return
        }

        // Get the latest window frame for calculations
        let latestFrame = currentWindowFrame(for: windowID) ?? session.window.frame

        // Update the window frame in the active stream (maintains position metadata)
        if let index = activeStreams.firstIndex(where: { $0.window.id == windowID }) {
            let currentSession = activeStreams[index]
            let updatedWindow = MirageWindow(
                id: currentSession.window.id,
                title: currentSession.window.title,
                application: currentSession.window.application,
                frame: latestFrame,
                isOnScreen: currentSession.window.isOnScreen,
                windowLayer: currentSession.window.windowLayer
            )
            activeStreams[index] = MirageStreamSession(
                id: currentSession.id,
                window: updatedWindow,
                client: currentSession.client
            )
        }

        do {
            // Request client's exact resolution - with .best, SCK will capture at highest quality
            try await context.updateResolution(width: width, height: height)

            // Get updated dimension token after resize
            let dimensionToken = await context.getDimensionToken()

            // Notify the client of the dimensions
            if let clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = minimumSizesByWindowID[windowID]
                let fallbackMin = fallbackMinimumSize(for: latestFrame)
                let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                let message = StreamStartedMessage(
                    streamID: session.id,
                    windowID: windowID,
                    width: width,
                    height: height,
                    frameRate: await context.getTargetFrameRate(),
                    codec: encoderConfig.codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: dimensionToken
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger.host("Capture resolution updated to \(width)x\(height)")
            }
        } catch {
            MirageLogger.error(.host, "Failed to update capture resolution: \(error)")
        }
    }

    /// Disconnect a client
    public func disconnectClient(_ client: MirageConnectedClient) async {
        // Stop all window streams for this client and minimize their windows
        for stream in activeStreams where stream.client.id == client.id {
            await stopStream(stream, minimizeWindow: true)
        }

        // Stop desktop stream if owned by this client
        // This prevents host from continuing to encode/send frames after client disconnects
        if let desktopClient = desktopStreamClientContext, desktopClient.client.id == client.id {
            MirageLogger.host("Stopping desktop stream for disconnected client: \(client.name)")
            await stopDesktopStream(reason: .clientRequested)
        }

        // Remove client
        if let key = clientsByConnection.first(where: { $0.value.client.id == client.id })?.key {
            clientsByConnection.removeValue(forKey: key)
        }

        connectedClients.removeAll { $0.id == client.id }

        if clientsByConnection.isEmpty {
            await stopLoginDisplayStream(newState: sessionState)
            await cleanupSharedVirtualDisplayIfIdle()
        }
    }

    private func cleanupSharedVirtualDisplayIfIdle() async {
        guard activeStreams.isEmpty, loginDisplayContext == nil, desktopStreamContext == nil else { return }

        let stats = await SharedVirtualDisplayManager.shared.getStatistics()
        guard stats.hasDisplay else { return }

        MirageLogger.host("No active streams or clients; destroying shared virtual display")
        await SharedVirtualDisplayManager.shared.destroyAllAndClear()
    }

    /// Activate the application and raise the window being streamed.
    /// Uses robust multi-method activation that works on headless Macs.
    private func activateWindow(_ window: MirageWindow) {
        guard let app = window.application else {
            MirageLogger.host("Cannot activate window - no associated application")
            return
        }

        // Get the AX window if available (for raising specific window)
        let axWindow = findAXWindow(for: window)

        // Use robust multi-method activation
        let result = windowActivator.activate(app: app, window: window, axWindow: axWindow)

        switch result {
        case .success(let method):
            MirageLogger.host("Window activated via \(method)")
        case .partialSuccess(let method, let message):
            MirageLogger.host("Window partially activated via \(method): \(message)")
        case .failure(_, let error):
            MirageLogger.error(.host, "Window activation failed: \(error)")
        }
    }

    /// Find the AXUIElement for a specific window using its known ID
    private func findAXWindow(for window: MirageWindow) -> AXUIElement? {
        guard let app = window.application else {
            MirageLogger.host("Window has no associated application")
            return nil
        }

        // Validate process is still running before attempting AX access
        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            MirageLogger.host("Process \(app.id) (\(app.name)) is no longer running")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.id)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            // Log the actual error for debugging
            MirageLogger.host("AX windows query failed for '\(app.name)' (PID: \(app.id)): AXError \(result.rawValue)")
            switch result {
            case .apiDisabled:
                MirageLogger.host("Accessibility API is disabled in System Preferences")
            case .invalidUIElement:
                MirageLogger.host("Invalid UI element - process may have terminated or restarted")
            case .cannotComplete:
                MirageLogger.host("Cannot complete - app may be unresponsive")
            case .notImplemented:
                MirageLogger.host("App does not implement accessibility for windows")
            case .noValue:
                MirageLogger.host("App returned no windows via accessibility")
            default:
                break
            }
            return nil
        }

        // Single window - use it directly
        if axWindows.count == 1 {
            return axWindows[0]
        }

        // Get window position from CGWindowList using the known window ID
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        // Match by position
        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)

            if let positionValue = positionRef {
                var position = CGPoint.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

                if abs(position.x - windowX) < 10 && abs(position.y - windowY) < 10 {
                    return axWindow
                }
            }
        }

        return axWindows.first
    }

    public func updateMinimumSize(for windowID: WindowID, minSize: CGSize) {
        guard minSize.width > 0, minSize.height > 0 else { return }
        if let existing = minimumSizesByWindowID[windowID] {
            minimumSizesByWindowID[windowID] = CGSize(
                width: min(existing.width, minSize.width),
                height: min(existing.height, minSize.height)
            )
        } else {
            minimumSizesByWindowID[windowID] = minSize
        }
    }

    // MARK: - Virtual Display Queries

    /// Check if a window's stream uses the shared virtual display
    /// - Parameter windowID: The window ID to check
    /// - Returns: true if the stream for this window uses a virtual display
    public func isStreamUsingVirtualDisplay(windowID: WindowID) -> Bool {
        return windowsUsingVirtualDisplay.contains(windowID)
    }

    /// Get the shared virtual display bounds for a window's stream
    /// Returns the CGRect bounds of the shared virtual display if this window is being streamed.
    /// All windows share the same virtual display, sized to match the largest client resolution.
    /// Used by AppState for centering/resizing windows on the virtual display instead of NSScreen.main.
    /// - Parameter windowID: The window ID to query
    /// - Returns: The shared virtual display bounds, or nil if not using virtual display
    public func getVirtualDisplayBounds(windowID: WindowID) -> CGRect? {
        guard windowsUsingVirtualDisplay.contains(windowID) else { return nil }
        return sharedVirtualDisplayBounds
    }

    /// Update the cached window frame for input coordinate translation
    /// Call this after moving/centering a window to ensure mouse clicks go to the correct location.
    /// - Parameters:
    ///   - windowID: The window whose frame changed
    ///   - newFrame: The window's new frame in global coordinates
    public func updateInputCacheFrame(windowID: WindowID, newFrame: CGRect) {
        if let streamID = inputStreamCacheActor.getStreamID(forWindowID: windowID) {
            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
            MirageLogger.host("Updated input cache frame for window \(windowID): \(newFrame)")
        }
    }

    /// Bring a window to the front using SkyLight APIs
    /// Use this when AXUIElement-based window activation fails (e.g., on virtual displays)
    /// This is static because it doesn't require instance state and can be called from any context
    /// - Parameter windowID: The CGWindowID to bring to front
    /// - Returns: true if successful
    public static func bringWindowToFront(_ windowID: WindowID) -> Bool {
        #if os(macOS)
        // Use the shared SkyLight bridge to order the window above all others.
        return CGSWindowSpaceBridge.bringWindowToFront(windowID)
        #else
        return false
        #endif
    }

    // MARK: - Private

    private func startDataListener() async throws -> UInt16 {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        // Use .any for dynamic port allocation, or specific port if configured
        let port: NWEndpoint.Port = networkConfig.dataPort == 0 ? .any : NWEndpoint.Port(rawValue: networkConfig.dataPort) ?? .any

        let listener = try NWListener(using: params, on: port)
        self.udpListener = listener

        // Handle incoming UDP connections from clients
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInteractive))
            Task { @MainActor [weak self] in
                await self?.handleIncomingVideoConnection(connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)

            listener.stateUpdateHandler = { [continuationBox] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuationBox.resume(returning: port)
                    }
                case .failed(let error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(throwing: MirageError.protocolError("Listener cancelled"))
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInteractive))
        }
    }

    /// Handle an incoming UDP connection from a client (for video data)
    /// Continues listening for additional stream registrations on the same connection
    private func handleIncomingVideoConnection(_ connection: NWConnection) async {
        // Continue receiving registration packets until connection closes
        // This allows a single client UDP connection to register multiple streams
        while true {
            // Receive the registration packet
            let result: (Data?, NWConnection.ContentContext?, Bool, NWError?) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 22, maximumLength: 64) { data, context, isComplete, error in
                    continuation.resume(returning: (data, context, isComplete, error))
                }
            }

            // Check for error first
            if let error = result.3 {
                MirageLogger.host("UDP connection error: \(error)")
                break
            }

            // For UDP, isComplete can be true even with valid data (each datagram is complete)
            // Process data first, then check if we should continue listening
            guard let data = result.0, data.count >= 22 else {
                // No valid data - if connection is complete, we're done
                if result.2 {
                    MirageLogger.host("UDP connection closed (no more data)")
                    break
                }
                MirageLogger.host("Invalid video registration packet")
                continue  // Keep listening for valid packets
            }

            // Parse registration: magic (4) + streamID (2) + deviceID (16)
            let magic = data.prefix(4)
            guard magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) else { // "MIRG"
                MirageLogger.host("Invalid video registration magic")
                continue  // Keep listening for valid packets
            }

            let streamID = data.dropFirst(4).prefix(2).withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 0, as: StreamID.self).littleEndian
            }

            MirageLogger.host("Received video registration for stream \(streamID)")

            // Verify stream exists
            guard streamsByID[streamID] != nil else {
                MirageLogger.host("Stream \(streamID) not found, may be pending")
                continue  // Keep listening - stream might be created soon
            }

            // Store the UDP connection for this stream
            // All streams from this client share the same connection
            udpConnectionsByStream[streamID] = connection

            MirageLogger.host("UDP connection registered for stream \(streamID)")

            if let context = streamsByID[streamID] {
                MirageLogger.host("Enabling encoding after UDP registration for stream \(streamID)")
                await context.allowEncodingAfterRegistration()
            } else {
                MirageLogger.host("WARNING: No stream context found for stream \(streamID)")
            }
        }
    }

    /// Send video packet for a specific stream
    func sendVideoPacketForStream(_ streamID: StreamID, data: Data) {
        guard let connection = udpConnectionsByStream[streamID] else {
            // Client hasn't registered via UDP yet - drop the packet silently
            return
        }
        connection.send(content: data, completion: .idempotent)
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        MirageLogger.host("New client connection")

        // Start the connection
        connection.start(queue: .global(qos: .userInitiated))

        // Wait for connection to be ready (use SafeContinuationBox to prevent double-resume)
        let isReady = await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            connection.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume(returning: true)
                case .failed, .cancelled:
                    box.resume(returning: false)
                default:
                    break
                }
            }
        }

        guard isReady else {
            MirageLogger.host("Client connection failed")
            return
        }

        // Extract endpoint info for display
        let endpointDescription: String
        switch connection.endpoint {
        case .hostPort(let host, let port):
            endpointDescription = "\(host):\(port)"
        case .service(let name, _, _, _):
            endpointDescription = name
        default:
            endpointDescription = connection.endpoint.debugDescription
        }

        MirageLogger.host("Waiting for hello message from \(endpointDescription)...")

        // Wait for hello message from client
        let deviceInfo = await receiveHelloMessage(from: connection, endpoint: endpointDescription)

        MirageLogger.host("Requesting approval for \(deviceInfo.name) (\(deviceInfo.deviceType.displayName))...")

        // Ask delegate if we should accept this connection (use SafeContinuationBox to prevent double-resume)
        let shouldAccept: Bool = await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            if let delegate {
                delegate.hostService(self, shouldAcceptConnectionFrom: deviceInfo) { accepted in
                    box.resume(returning: accepted)
                }
            } else {
                // No delegate, auto-accept
                box.resume(returning: true)
            }
        }

        guard shouldAccept else {
            MirageLogger.host("Connection rejected by user")
            connection.cancel()
            return
        }

        MirageLogger.host("Connection approved, sending hello response...")

        // Extract data port from state
        let dataPort: UInt16
        if case .advertising(_, let port) = state {
            dataPort = port
        } else {
            dataPort = 0
        }

        // Send HelloResponse with data port
        do {
            let hostName = Host.current().localizedName ?? "Mac"
            let response = HelloResponseMessage(
                accepted: true,
                hostID: hostID,
                hostName: hostName,
                requiresAuth: false,
                dataPort: dataPort
            )
            let message = try ControlMessage(type: .helloResponse, content: response)
            let data = message.serialize()

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MirageLogger.error(.host, "Failed to send hello response: \(error)")
                } else {
                    MirageLogger.host("Sent hello response with dataPort \(dataPort)")
                }
            })
        } catch {
            MirageLogger.error(.host, "Failed to create hello response: \(error)")
        }

        // Create a client record
        let client = MirageConnectedClient(
            id: deviceInfo.id,
            name: deviceInfo.name,
            deviceType: deviceInfo.deviceType,
            connectedAt: Date()
        )

        // Store the client context with TCP connection
        let clientContext = ClientContext(
            client: client,
            tcpConnection: connection,
            udpConnection: nil
        )
        clientsByConnection[ObjectIdentifier(connection)] = clientContext

        connectedClients.append(client)
        delegate?.hostService(self, didConnectClient: client)

        // Send session state first (before window list)
        await refreshSessionStateIfNeeded()
        await sendSessionState(to: clientContext)

        // Only send window list if session is active (not locked)
        // If locked, client will show unlock form based on session state
        if sessionState == .active {
            await sendWindowList(to: clientContext)
        } else {
            await startLoginDisplayStreamIfNeeded()
            MirageLogger.host("Session is \(sessionState), client will show unlock form")
        }

        // Start receiving control messages from this client
        startReceivingFromClient(connection: connection, client: client)
    }

    /// Continuously receive and handle control messages from a client
    private func startReceivingFromClient(connection: NWConnection, client: MirageConnectedClient) {
        var receiveBuffer = Data()
        let bufferLock = NSLock()  // Protect buffer access across queues
        let connectionID = ObjectIdentifier(connection)

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }

                // Parse messages on the network queue (before any dispatch)
                bufferLock.lock()
                if let data, !data.isEmpty {
                    receiveBuffer.append(data)
                }

                // Extract all complete messages
                var messages: [(message: ControlMessage, isInput: Bool)] = []
                while let (message, consumed) = ControlMessage.deserialize(from: receiveBuffer) {
                    receiveBuffer.removeFirst(consumed)
                    messages.append((message, message.type == .inputEvent))
                }
                bufferLock.unlock()

                // Fast path: Handle input events on inputQueue (bypasses MainActor)
                for (message, isInput) in messages where isInput {
                    self.inputQueue.async {
                        self.handleInputEventFast(message, from: client)
                    }
                }

                // Normal path: Handle other messages on MainActor
                let nonInputMessages = messages.filter { !$0.isInput }.map { $0.message }
                if !nonInputMessages.isEmpty || error != nil || isComplete {
                    Task { @MainActor [weak self] in
                        guard let self else { return }

                        // Successful data received - reset error tracking
                        if !nonInputMessages.isEmpty {
                            self.clientFirstErrorTime.removeValue(forKey: connectionID)
                        }

                        for message in nonInputMessages {
                            await self.handleClientMessage(message, from: client, connection: connection)
                        }

                        if let error {
                            // Check if this is a fatal connection error that cannot recover
                            // These errors mean the TCP connection is dead - no point waiting
                            let isFatalError = self.isFatalConnectionError(error)

                            if isFatalError {
                                MirageLogger.error(.host, "Client \(client.name) fatal connection error - disconnecting: \(error)")
                                self.clientFirstErrorTime.removeValue(forKey: connectionID)
                                await self.disconnectClient(client)
                                return
                            }

                            // For non-fatal errors, use timeout-based recovery
                            let now = CFAbsoluteTimeGetCurrent()
                            if let firstErrorTime = self.clientFirstErrorTime[connectionID] {
                                // Check if errors have persisted beyond timeout
                                let errorDuration = now - firstErrorTime
                                if errorDuration >= self.clientErrorTimeoutSeconds {
                                    MirageLogger.error(.host, "Client \(client.name) errors persisted for \(Int(errorDuration))s - disconnecting")
                                    self.clientFirstErrorTime.removeValue(forKey: connectionID)
                                    await self.disconnectClient(client)
                                    return
                                }
                                MirageLogger.host("Client \(client.name) error (persisting for \(Int(errorDuration))s): \(error)")
                            } else {
                                // First error - record time and continue
                                self.clientFirstErrorTime[connectionID] = now
                                MirageLogger.host("Client \(client.name) transient error, will disconnect after \(Int(self.clientErrorTimeoutSeconds))s if not recovered: \(error)")
                            }
                            // Continue receiving to allow recovery
                            receiveNext()
                            return
                        }

                        if isComplete {
                            MirageLogger.host("Client disconnected")
                            self.clientFirstErrorTime.removeValue(forKey: connectionID)
                            await self.disconnectClient(client)
                            return
                        }

                        // Continue receiving
                        receiveNext()
                    }
                } else {
                    // No MainActor work needed, continue receiving immediately
                    receiveNext()
                }
            }
        }

        receiveNext()
    }

    /// Fast input event handler - runs on inputQueue, NOT MainActor
    /// Uses cached stream info for O(1) lookup
    private func handleInputEventFast(_ message: ControlMessage, from client: MirageConnectedClient) {
        do {
            let inputMessage = try message.decode(InputEventMessage.self)

            if let loginInfo = loginDisplayInputState.getInfo(for: inputMessage.streamID) {
                handleLoginDisplayInputEvent(inputMessage.event, loginInfo: loginInfo)
                return
            }

            // Fast O(1) lookup from thread-safe cache
            guard let cacheEntry = inputStreamCacheActor.get(inputMessage.streamID) else {
                MirageLogger.host("No cached stream for input: \(inputMessage.streamID)")
                return
            }

            // Handle desktop stream resize events directly in host service
            // Desktop streams have window.id == 0 and resize should change virtual display
            if cacheEntry.window.id == 0 {
                let streamID = inputMessage.streamID
                switch inputMessage.event {
                case .relativeResize(let resizeEvent):
                    let newResolution = CGSize(width: resizeEvent.pixelWidth, height: resizeEvent.pixelHeight)
                    Task { @MainActor in
                        await self.handleDisplayResolutionChange(streamID: streamID, newResolution: newResolution)
                    }
                    return
                case .pixelResize(let resizeEvent):
                    let newResolution = CGSize(width: resizeEvent.pixelWidth, height: resizeEvent.pixelHeight)
                    Task { @MainActor in
                        await self.handleDisplayResolutionChange(streamID: streamID, newResolution: newResolution)
                    }
                    return
                default:
                    break  // Other desktop input events go to callback
                }
            }

            // Call the fast input handler (set by AppState)
            // Pass the cache entry which includes window, contentRect, etc.
            if let handler = _onInputEvent {
                handler(inputMessage.event, cacheEntry.window, client)
            } else {
                inputController.handleInputEvent(inputMessage.event, window: cacheEntry.window)
            }
        } catch {
            MirageLogger.error(.host, "Failed to decode input event: \(error)")
        }
    }

    /// Handle a control message from a client
    private func handleClientMessage(_ message: ControlMessage, from client: MirageConnectedClient, connection: NWConnection) async {
        MirageLogger.host("Received message type: \(message.type) from \(client.name)")
        switch message.type {
        case .startStream:
            do {
                let request = try message.decode(StartStreamMessage.self)
                MirageLogger.host("Client requested stream for window \(request.windowID)")

                await refreshSessionStateIfNeeded()
                guard sessionState == .active else {
                    MirageLogger.host("Rejecting startStream while session is \(sessionState)")
                    if let clientContext = clientsByConnection[ObjectIdentifier(connection)] {
                        await sendSessionState(to: clientContext)
                    }
                    return
                }

                // Find the window
                guard let window = availableWindows.first(where: { $0.id == request.windowID }) else {
                    MirageLogger.host("Window not found: \(request.windowID)")
                    return
                }

                // Get client's display resolution for virtual display sizing
                var clientDisplayResolution: CGSize?
                if let displayWidth = request.displayWidth, let displayHeight = request.displayHeight,
                   displayWidth > 0, displayHeight > 0 {
                    clientDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
                    MirageLogger.host("Client display resolution: \(displayWidth)x\(displayHeight)")
                }

                // Handle initial window sizing if client provides dimensions (legacy mode only)
                // With virtual displays, the window will be sized relative to the virtual display
                if clientDisplayResolution == nil,
                   let pixelWidth = request.pixelWidth, let pixelHeight = request.pixelHeight,
                   pixelWidth > 0, pixelHeight > 0,
                   let scaleFactor = request.scaleFactor, scaleFactor > 0 {
                    let pointSize = CGSize(
                        width: CGFloat(pixelWidth) / scaleFactor,
                        height: CGFloat(pixelHeight) / scaleFactor
                    )
                    MirageLogger.host("Client initial size (legacy): \(pixelWidth)x\(pixelHeight) px -> \(pointSize) pts")
                    onResizeWindowForStream?(window, pointSize)
                }

                // Determine target frame rate based on client capability
                let clientMaxRefreshRate = request.maxRefreshRate
                let targetFrameRate = clientMaxRefreshRate >= 120 ? 120 : 60

                let presetConfig = request.preferredQuality.encoderConfiguration(for: targetFrameRate)
                let keyFrameInterval = request.keyFrameInterval ?? presetConfig.keyFrameInterval
                let frameQuality = request.frameQuality ?? presetConfig.frameQuality
                let keyframeQuality = request.keyframeQuality ?? presetConfig.keyframeQuality
                let pixelFormat = request.pixelFormat ?? presetConfig.pixelFormat
                let colorSpace = request.colorSpace ?? presetConfig.colorSpace
                let minBitrate = request.minBitrate ?? presetConfig.minBitrate
                let maxBitrate = request.maxBitrate ?? presetConfig.maxBitrate
                let requestedScale = request.streamScale ?? 1.0
                let adaptiveScaleEnabled = request.adaptiveScaleEnabled ?? true
                MirageLogger.host("Frame rate: \(targetFrameRate)fps (quality=\(request.preferredQuality.displayName), client max=\(clientMaxRefreshRate)Hz)")

                try await startStream(
                    for: window,
                    to: client,
                    dataPort: request.dataPort,
                    clientDisplayResolution: clientDisplayResolution,
                    keyFrameInterval: keyFrameInterval,
                    frameQuality: frameQuality,
                    keyframeQuality: keyframeQuality,
                    streamScale: requestedScale,
                    adaptiveScaleEnabled: adaptiveScaleEnabled,
                    qualityPreset: request.preferredQuality,
                    targetFrameRate: targetFrameRate,
                    pixelFormat: pixelFormat,
                    colorSpace: colorSpace,
                    captureQueueDepth: request.captureQueueDepth,
                    minBitrate: minBitrate,
                    maxBitrate: maxBitrate
                )
            } catch {
                MirageLogger.error(.host, "Failed to handle startStream: \(error)")
            }

        case .displayResolutionChange:
            do {
                let request = try message.decode(DisplayResolutionChangeMessage.self)
                MirageLogger.host("Client requested display resolution change for stream \(request.streamID): \(request.displayWidth)x\(request.displayHeight)")
                await handleDisplayResolutionChange(
                    streamID: request.streamID,
                    newResolution: CGSize(width: request.displayWidth, height: request.displayHeight)
                )
            } catch {
                MirageLogger.error(.host, "Failed to handle displayResolutionChange: \(error)")
            }

        case .streamScaleChange:
            do {
                let request = try message.decode(StreamScaleChangeMessage.self)
                MirageLogger.host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
                await handleStreamScaleChange(
                    streamID: request.streamID,
                    streamScale: request.streamScale,
                    adaptiveScaleEnabled: request.adaptiveScaleEnabled
                )
            } catch {
                MirageLogger.error(.host, "Failed to handle streamScaleChange: \(error)")
            }

        case .stopStream:
            if let request = try? message.decode(StopStreamMessage.self) {
                if let session = activeStreams.first(where: { $0.id == request.streamID }) {
                    await stopStream(session, minimizeWindow: request.minimizeWindow)
                }
            }

        case .keyframeRequest:
            if let request = try? message.decode(KeyframeRequestMessage.self),
               let context = streamsByID[request.streamID] {
                await context.requestKeyframe()
            }

        case .ping:
            // Respond with pong
            let pong = ControlMessage(type: .pong)
            connection.send(content: pong.serialize(), completion: .idempotent)

        case .inputEvent:
            do {
                let inputMessage = try message.decode(InputEventMessage.self)
                // Only log resize events in detail to avoid log spam
                if case .windowResize(let resizeEvent) = inputMessage.event {
                    MirageLogger.host("Received RESIZE event: \(resizeEvent.newSize) pts, scale: \(resizeEvent.scaleFactor), pixels: \(resizeEvent.pixelSize)")
                }
                // Find the window for this stream
                if let session = activeStreams.first(where: { $0.id == inputMessage.streamID }) {
                    delegate?.hostService(self, didReceiveInputEvent: inputMessage.event, forWindow: session.window, fromClient: client)
                } else {
                    MirageLogger.host("No session found for stream \(inputMessage.streamID)")
                }
            } catch {
                MirageLogger.error(.host, "Failed to decode input event: \(error)")
            }

        case .disconnect:
            // Client is explicitly disconnecting - clean up their streams
            if let disconnect = try? message.decode(DisconnectMessage.self) {
                MirageLogger.host("Client \(client.name) disconnected: \(disconnect.reason.rawValue)")
            } else {
                MirageLogger.host("Client \(client.name) disconnected")
            }
            await disconnectClient(client)
            delegate?.hostService(self, didDisconnectClient: client)

        case .unlockRequest:
            await handleUnlockRequest(message, from: client, connection: connection)

        // MARK: App-Centric Streaming Messages

        case .appListRequest:
            await handleAppListRequest(message, from: client, connection: connection)

        case .selectApp:
            await handleSelectApp(message, from: client, connection: connection)

        case .closeWindowRequest:
            await handleCloseWindowRequest(message, from: client, connection: connection)

        case .streamPaused:
            await handleStreamPaused(message, from: client)

        case .streamResumed:
            await handleStreamResumed(message, from: client)

        case .cancelCooldown:
            await handleCancelCooldown(message, from: client, connection: connection)

        // MARK: Menu Bar Passthrough

        case .menuActionRequest:
            await handleMenuActionRequest(message, from: client, connection: connection)

        // MARK: Desktop Streaming Messages

        case .startDesktopStream:
            await handleStartDesktopStream(message, from: client, connection: connection)

        case .stopDesktopStream:
            await handleStopDesktopStream(message)

        default:
            MirageLogger.host("Unhandled message type: \(message.type)")
        }
    }

    private func sendVideoData(_ data: Data, header: FrameHeader, to client: MirageConnectedClient) async {
        // Send via UDP to client
        if let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) {
            clientContext.sendVideoPacket(data)
        }
    }

    /// Receive hello message from a connecting client
    private func receiveHelloMessage(from connection: NWConnection, endpoint: String) async -> MirageDeviceInfo {
        // Wait for data with timeout
        let result: (Data?, NWConnection.ContentContext?, Bool, NWError?) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
                continuation.resume(returning: (data, context, isComplete, error))
            }
        }

        let (data, _, _, error) = result

        if let error {
            MirageLogger.error(.host, "Error receiving hello: \(error)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        guard let data, !data.isEmpty else {
            MirageLogger.host("No data received for hello")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        // Parse the control message
        guard let (message, _) = ControlMessage.deserialize(from: data) else {
            MirageLogger.host("Failed to deserialize hello message")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        guard message.type == .hello else {
            MirageLogger.host("Expected hello message, got \(message.type)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        do {
            let hello = try message.decode(HelloMessage.self)
            MirageLogger.host("Received hello from \(hello.deviceName) (\(hello.deviceType.displayName))")
            return MirageDeviceInfo(
                id: hello.deviceID,
                name: hello.deviceName,
                deviceType: hello.deviceType,
                endpoint: endpoint
            )
        } catch {
            MirageLogger.error(.host, "Failed to decode hello: \(error)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }
    }

}

// MARK: - Supporting Types

public struct MirageConnectedClient: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let deviceType: DeviceType
    public let connectedAt: Date
}

public struct MirageStreamSession: Identifiable, Sendable {
    public let id: StreamID
    public let window: MirageWindow
    public let client: MirageConnectedClient
}

#endif
