//
//  MirageClientService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import Observation
import CoreGraphics

#if canImport(UIKit)
import UIKit.UIDevice
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

// MARK: - iOS Window Detection Extensions

#if os(iOS)
public extension UIWindow {
    /// Returns the current key window from connected window scenes
    /// More reliable than deprecated UIApplication.shared.keyWindow
    /// Note: For SwiftUI views, prefer using WindowSceneReader from MirageKit
    /// for more reliable screen detection through the view hierarchy.
    static var current: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if window.isKeyWindow { return window }
            }
        }
        return nil
    }
}
#endif

/// Main entry point for connecting to and viewing remote windows
@Observable
@MainActor
public final class MirageClientService {
    /// Current connection state
    public private(set) var connectionState: ConnectionState = .disconnected

    /// Available windows on the connected host
    public private(set) var availableWindows: [MirageWindow] = []

    /// Active stream views
    public private(set) var activeStreams: [ClientStreamSession] = []

    /// Whether we've received the initial window list from the host
    public private(set) var hasReceivedWindowList: Bool = false

    /// Current session state of the connected host (locked, unlocked, etc.)
    public private(set) var hostSessionState: HostSessionState?

    /// Current session token from the host (for unlock requests)
    private var currentSessionToken: String?

    /// Login display stream ID (when host is locked and streaming login screen)
    public private(set) var loginDisplayStreamID: StreamID?

    /// Login display resolution
    public private(set) var loginDisplayResolution: CGSize?

    /// Desktop stream ID (when streaming full virtual display)
    public private(set) var desktopStreamID: StreamID?

    /// Desktop stream resolution
    public private(set) var desktopStreamResolution: CGSize?

    /// Stream scale for post-capture downscaling
    /// 1.0 = native resolution, lower values reduce encoded size
    public var resolutionScale: CGFloat = 1.0

    /// Whether the host is allowed to adapt stream scale for FPS recovery.
    public var adaptiveScaleEnabled: Bool = true

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

    /// Callback for content bounds updates (when menus, sheets appear on virtual display)
    public var onContentBoundsUpdate: ((StreamID, CGRect) -> Void)?

    // MARK: - App-Centric Streaming Properties

    /// Available apps on the connected host
    public private(set) var availableApps: [MirageInstalledApp] = []

    /// Whether we've received the initial app list from the host
    public private(set) var hasReceivedAppList: Bool = false

    /// Currently streaming app's bundle identifier
    public private(set) var streamingAppBundleID: String?

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

    /// Session store for UI state and stream coordination.
    public let sessionStore: MirageClientSessionStore
    /// Metrics store for stream telemetry (decoupled from SwiftUI).
    public let metricsStore = MirageClientMetricsStore()
    /// Cursor store for pointer updates (decoupled from SwiftUI).
    public let cursorStore = MirageClientCursorStore()

    private var networkConfig: MirageNetworkConfiguration
    private var transport: HybridTransport?
    private var connection: NWConnection?
    private var connectedHost: MirageHost?
    private let deviceID: UUID
    private let deviceName: String
    private var receiveBuffer = Data()

    // Video receiving
    private var udpConnection: NWConnection?
    private var hostDataPort: UInt16 = 0

    // Per-stream controllers for lifecycle management
    // StreamController owns decoder, reassembler, and resize state machine
    private var controllersByStream: [StreamID: StreamController] = [:]

    // Track which streams have been registered with the host (prevents duplicate registrations)
    private var registeredStreamIDs: Set<StreamID> = []
    private var lastKeyframeRequestTime: [StreamID: CFAbsoluteTime] = [:]
    private let keyframeRequestCooldown: CFAbsoluteTime = 0.75

    /// Thread-safe set of active stream IDs for packet filtering from UDP callback
    private let activeStreamIDsLock = NSLock()
    nonisolated(unsafe) private var _activeStreamIDs: Set<StreamID> = []

    /// Thread-safe property to check if a stream is active from nonisolated contexts
    nonisolated var activeStreamIDsForFiltering: Set<StreamID> {
        activeStreamIDsLock.lock()
        defer { activeStreamIDsLock.unlock() }
        return _activeStreamIDs
    }

    /// Thread-safe set of stream IDs where input is blocked (decoder unhealthy)
    /// Input is blocked when decoder is awaiting keyframe or has decode errors
    private let inputBlockedStreamIDsLock = NSLock()
    nonisolated(unsafe) private var _inputBlockedStreamIDs: Set<StreamID> = []

    /// Thread-safe storage for last cursor positions per stream
    /// Used by sendInputReleaseEvents to avoid jumping cursor to center during decode errors
    private let lastCursorPositionsLock = NSLock()
    nonisolated(unsafe) private var _lastCursorPositions: [StreamID: CGPoint] = [:]

    /// Thread-safe check if input is blocked for a stream
    /// Used by sendInputFireAndForget to prevent input when user can't see what they're clicking
    nonisolated func isInputBlocked(for streamID: StreamID) -> Bool {
        inputBlockedStreamIDsLock.lock()
        defer { inputBlockedStreamIDsLock.unlock() }
        return _inputBlockedStreamIDs.contains(streamID)
    }

    private func setInputBlocked(_ blocked: Bool, for streamID: StreamID) {
        // When blocking, first send release events to prevent stuck input on host
        // This handles the case where user is mid-drag when decode error occurs
        if blocked {
            sendInputReleaseEvents(for: streamID)
        }

        inputBlockedStreamIDsLock.lock()
        if blocked {
            _inputBlockedStreamIDs.insert(streamID)
        } else {
            _inputBlockedStreamIDs.remove(streamID)
        }
        inputBlockedStreamIDsLock.unlock()
    }

    /// Send events to release any potentially held input (mouse buttons, modifiers)
    /// Called before blocking input to prevent stuck state on host when decode errors occur mid-drag
    private func sendInputReleaseEvents(for streamID: StreamID) {
        guard case .connected = connectionState, let connection else { return }

        // Use last known cursor position to avoid jarring cursor jump to center
        // Fall back to center if we haven't received any mouse events yet
        lastCursorPositionsLock.lock()
        let releaseLocation = _lastCursorPositions[streamID] ?? CGPoint(x: 0.5, y: 0.5)
        lastCursorPositionsLock.unlock()

        do {
            // Release left mouse button (handles drag release)
            let leftMouseUp = MirageMouseEvent(button: .left, location: releaseLocation, modifiers: [])
            let leftMessage = try ControlMessage(type: .inputEvent, content: InputEventMessage(streamID: streamID, event: .mouseUp(leftMouseUp)))
            connection.send(content: leftMessage.serialize(), completion: .idempotent)

            // Release right mouse button
            let rightMouseUp = MirageMouseEvent(button: .right, location: releaseLocation, modifiers: [])
            let rightMessage = try ControlMessage(type: .inputEvent, content: InputEventMessage(streamID: streamID, event: .rightMouseUp(rightMouseUp)))
            connection.send(content: rightMessage.serialize(), completion: .idempotent)

            // Release middle mouse button
            let middleMouseUp = MirageMouseEvent(button: .middle, location: releaseLocation, modifiers: [])
            let middleMessage = try ControlMessage(type: .inputEvent, content: InputEventMessage(streamID: streamID, event: .otherMouseUp(middleMouseUp)))
            connection.send(content: middleMessage.serialize(), completion: .idempotent)

            // Clear all modifier keys (Shift, Control, Option, Command)
            let flagsMessage = try ControlMessage(type: .inputEvent, content: InputEventMessage(streamID: streamID, event: .flagsChanged([])))
            connection.send(content: flagsMessage.serialize(), completion: .idempotent)

            MirageLogger.client("Sent input release events for stream \(streamID) before blocking")
        } catch {
            MirageLogger.error(.client, "Failed to send input release events: \(error)")
        }
    }

    private func addActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        _activeStreamIDs.insert(id)
        activeStreamIDsLock.unlock()
    }

    private func removeActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        _activeStreamIDs.remove(id)
        activeStreamIDsLock.unlock()

        // Also clear input blocking state for this stream
        setInputBlocked(false, for: id)
    }

    private func clearAllActiveStreamIDs() {
        activeStreamIDsLock.lock()
        _activeStreamIDs.removeAll()
        activeStreamIDsLock.unlock()

        // Also clear all input blocking states
        inputBlockedStreamIDsLock.lock()
        _inputBlockedStreamIDs.removeAll()
        inputBlockedStreamIDsLock.unlock()
    }

    /// Thread-safe snapshot of reassemblers for packet routing from UDP callback
    private let reassemblersLock = NSLock()
    nonisolated(unsafe) private var _reassemblersSnapshot: [StreamID: FrameReassembler] = [:]

    /// Get a snapshot of reassemblers for thread-safe access from UDP callback
    nonisolated func reassemblerForStream(_ id: StreamID) -> FrameReassembler? {
        reassemblersLock.lock()
        defer { reassemblersLock.unlock() }
        return _reassemblersSnapshot[id]
    }

    private func updateReassemblerSnapshot() async {
        // Build snapshot from controllers
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = await controller.getReassembler()
        }
        // Use nonisolated helper to avoid async lock warning
        storeReassemblerSnapshot(snapshot)
    }

    /// Helper to store reassembler snapshot synchronously
    private nonisolated func storeReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        reassemblersLock.lock()
        _reassemblersSnapshot = snapshot
        reassemblersLock.unlock()
    }

    // Stream start synchronization - waits for server to assign stream ID
    private var streamStartedContinuation: CheckedContinuation<StreamID, Error>?

    // Minimum window sizes per stream (from host)
    private var streamMinSizes: [StreamID: (minWidth: Int, minHeight: Int)] = [:]

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(host: String)
        case reconnecting
        case error(String)

        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): return true
            case (.connecting, .connecting): return true
            case (.connected(let a), .connected(let b)): return a == b
            case (.reconnecting, .reconnecting): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }

        /// Whether this state allows starting a new connection
        public var canConnect: Bool {
            switch self {
            case .disconnected, .error: return true
            default: return false
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

        self.networkConfig = networkConfiguration
        self.sessionStore = sessionStore

        // Load existing device ID or generate and persist a new one
        if let savedIDString = UserDefaults.standard.string(forKey: Self.deviceIDKey),
           let savedID = UUID(uuidString: savedIDString) {
            self.deviceID = savedID
            MirageLogger.client("Loaded existing device ID: \(savedID)")
        } else {
            let newID = UUID()
            UserDefaults.standard.set(newID.uuidString, forKey: Self.deviceIDKey)
            self.deviceID = newID
            MirageLogger.client("Generated new device ID: \(newID)")
        }
        self.sessionStore.clientService = self
    }

    /// Determine current device type
    private var currentDeviceType: DeviceType {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPad
        } else {
            return .iPhone
        }
        #elseif os(visionOS)
        return .vision
        #else
        return .unknown
        #endif
    }

    /// Send hello message with device info to host
    private func sendHelloMessage(connection: NWConnection) async {
        let hello = HelloMessage(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: currentDeviceType,
            protocolVersion: Int(MirageKit.protocolVersion),
            capabilities: MirageHostCapabilities(
                maxStreams: 4,
                supportsHEVC: true,
                supportsP3ColorSpace: true,
                maxFrameRate: 120,
                protocolVersion: Int(MirageKit.protocolVersion)
            )
        )

        do {
            let message = try ControlMessage(type: .hello, content: hello)
            let data = message.serialize()
            MirageLogger.client("Sending hello: \(deviceName) (\(currentDeviceType.displayName))")

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MirageLogger.error(.client, "Failed to send hello: \(error)")
                } else {
                    MirageLogger.client("Hello sent successfully")
                }
            })
        } catch {
            MirageLogger.error(.client, "Failed to create hello message: \(error)")
        }
    }

    /// Connect to a discovered host
    public func connect(to host: MirageHost) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        MirageLogger.client("Connecting to \(host.name)...")
        connectionState = .connecting
        connectedHost = host

        do {
            // Create a direct TCP connection to the Bonjour endpoint
            let parameters = NWParameters.tcp
            parameters.serviceClass = .interactiveVideo
            parameters.includePeerToPeer = networkConfig.enablePeerToPeer

            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }

            let connection = NWConnection(to: host.endpoint, using: parameters)

            // Wait for connection to be ready
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let continuationBox = ContinuationBox<Void>(continuation)

                connection.stateUpdateHandler = { [continuationBox] state in
                    MirageLogger.client("Connection state: \(state)")
                    switch state {
                    case .ready:
                        continuationBox.resume()
                    case .failed(let error):
                        continuationBox.resume(throwing: error)
                    case .cancelled:
                        continuationBox.resume(throwing: MirageError.protocolError("Connection cancelled"))
                    case .waiting(let error):
                        MirageLogger.client("Connection waiting: \(error)")
                    default:
                        break
                    }
                }

                connection.start(queue: .global(qos: .userInitiated))
            }

            MirageLogger.client("Connected to \(host.name)")
            connectionState = .connected(host: host.name)

            // Store connection for receiving messages
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    Task { @MainActor in
                        await self.handleDisconnect(
                            reason: error.localizedDescription,
                            state: .error(error.localizedDescription),
                            notifyDelegate: true
                        )
                    }
                case .cancelled:
                    Task { @MainActor in
                        await self.handleDisconnect(
                            reason: "Connection cancelled",
                            state: .disconnected,
                            notifyDelegate: true
                        )
                    }
                default:
                    break
                }
            }

            // Send hello message with device info
            await sendHelloMessage(connection: connection)

            // Start receiving messages from the server
            startReceiving()

        } catch {
            MirageLogger.error(.client, "Connection failed: \(error)")
            connectionState = .disconnected  // Reset to allow retry
            connectedHost = nil
            transport = nil
            throw error
        }
    }

    /// Disconnect from the current host
    public func disconnect() async {
        // Send disconnect message to host before closing connection
        if let connection, case .connected = connectionState {
            let disconnectMsg = DisconnectMessage(reason: .userRequested, message: nil)
            if let message = try? ControlMessage(type: .disconnect, content: disconnectMsg) {
                let data = message.serialize()
                // Send synchronously and wait for completion
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connection.send(content: data, completion: .contentProcessed { _ in
                        continuation.resume()
                    })
                }
            }
        }

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false
        )
    }

    private func handleDisconnect(reason: String, state: ConnectionState, notifyDelegate: Bool) async {
        if case .disconnected = connectionState {
            return
        }

        if case .error = connectionState, case .error = state {
            return
        }

        stopScreenPolling()

        let sessions = activeStreams
        let storedSessions = sessionStore.activeSessions

        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        await transport?.disconnect()
        transport = nil
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        streamingAppBundleID = nil

        for session in sessions {
            await stopViewing(session)
        }

        if let loginDisplayStreamID {
            MirageFrameCache.shared.clear(for: loginDisplayStreamID)
        }
        metricsStore.clearAll()
        cursorStore.clearAll()
        sessionStore.clearLoginDisplayState()

        // Clean up video resources
        stopVideoConnection()

        let controllers = controllersByStream.values
        for controller in controllers {
            await controller.stop()
        }
        controllersByStream.removeAll()
        registeredStreamIDs.removeAll()
        activeStreams.removeAll()
        for session in storedSessions {
            sessionStore.removeSession(session.id)
        }
        await updateReassemblerSnapshot()

        // Clear active stream IDs (thread-safe)
        clearAllActiveStreamIDs()

        // Reset session state
        hostSessionState = nil
        currentSessionToken = nil
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        desktopStreamID = nil
        desktopStreamResolution = nil
        connectionState = state

        if notifyDelegate {
            delegate?.clientService(self, didDisconnectFromHost: reason)
        }
    }

    // MARK: - Host Unlock

    /// Send an unlock request to the host
    /// - Parameters:
    ///   - username: Username (required if host is at login screen)
    ///   - password: Password for the account
    /// - Throws: Error if not connected or no session token
    public func sendUnlockRequest(username: String?, password: String) async throws {
        guard let connection else {
            throw MirageError.protocolError("Not connected to host")
        }

        guard let token = currentSessionToken else {
            throw MirageError.protocolError("No session token available")
        }

        let request = UnlockRequestMessage(
            sessionToken: token,
            username: username,
            password: password
        )

        let message = try ControlMessage(type: .unlockRequest, content: request)
        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    MirageLogger.client("Sent unlock request")
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Message Receiving

    private func startReceiving() {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processReceivedData()
                }

                if let error {
                    MirageLogger.error(.client, "Receive error: \(error)")
                    await self.handleDisconnect(
                        reason: error.localizedDescription,
                        state: .error(error.localizedDescription),
                        notifyDelegate: true
                    )
                    return
                }

                if isComplete {
                    MirageLogger.client("Connection closed by server")
                    await self.handleDisconnect(
                        reason: "Host disconnected",
                        state: .disconnected,
                        notifyDelegate: true
                    )
                    return
                }

                // Continue receiving
                self.startReceiving()
            }
        }
    }

    private func processReceivedData() {
        // Try to parse complete messages from the buffer
        while !receiveBuffer.isEmpty {
            // Check if this looks like a control message (first byte should be a valid type)
            let firstByte = receiveBuffer[receiveBuffer.startIndex]

            // Check if it might be video data (starts with MIRG magic: 0x4D 0x49 0x52 0x47)
            if firstByte == 0x4D && receiveBuffer.count >= 4 {
                let magic = receiveBuffer.prefix(4)
                if magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) {
                    MirageLogger.client("Warning: Received video data on TCP control channel, discarding")
                    // Discard this data - it shouldn't be on TCP
                    receiveBuffer.removeAll()
                    return
                }
            }

            guard let (message, bytesConsumed) = ControlMessage.deserialize(from: receiveBuffer) else {
                // Not enough data for a complete message, or invalid data
                // App list with icons can be very large (10MB+), so use a generous limit
                if receiveBuffer.count > 50_000_000 {
                    // Buffer too large with no valid messages - likely corrupted, clear it
                    MirageLogger.client("Buffer overflow with invalid data, clearing")
                    receiveBuffer.removeAll()
                }
                return
            }

            receiveBuffer.removeFirst(bytesConsumed)
            MirageLogger.client("Received message type: \(message.type)")

            Task {
                await handleControlMessage(message)
            }
        }
    }

    /// Request updated window list from host
    public func requestWindowList() async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let message = ControlMessage(type: .windowListRequest)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    // MARK: - App-Centric Streaming Methods

    /// Request list of installed apps from host
    /// - Parameter includeIcons: Whether to include app icons (increases message size)
    public func requestAppList(includeIcons: Bool = true) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        MirageLogger.client("Requesting app list from host (includeIcons: \(includeIcons))")
        let request = AppListRequestMessage(includeIcons: includeIcons)
        let message = try ControlMessage(type: .appListRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        MirageLogger.client("App list request sent")
    }

    /// Select an app to stream (will stream all its windows)
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier of the app to stream
    ///   - quality: Quality preset for the streams
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina)
    ///   - displayResolution: Client's display resolution for virtual display sizing
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    // TODO: HDR support - requires proper virtual display EDR configuration
    // ///   - preferHDR: Whether to request HDR streaming (Rec. 2020 with PQ)
    public func selectApp(
        bundleIdentifier: String,
        quality: MirageQualityPreset = .medium,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
        // preferHDR: Bool = false
    ) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        // Use provided display resolution or detect from main display
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())

        var request = SelectAppMessage(
            bundleIdentifier: bundleIdentifier,
            preferredQuality: quality,
            dataPort: nil,  // Not needed - host will use our UDP connection
            scaleFactor: scaleFactor,
            displayWidth: effectiveDisplayResolution.width > 0 ? Int(effectiveDisplayResolution.width) : nil,
            displayHeight: effectiveDisplayResolution.height > 0 ? Int(effectiveDisplayResolution.height) : nil,
            maxRefreshRate: getScreenMaxRefreshRate(),
            keyFrameInterval: nil,
            frameQuality: nil,
            keyframeQuality: nil,
            pixelFormat: nil,
            colorSpace: nil,
            minBitrate: nil,
            maxBitrate: nil,
            streamScale: clampedStreamScale(),
            adaptiveScaleEnabled: adaptiveScaleEnabled
        )
        // TODO: HDR support - requires proper virtual display EDR configuration
        // request.preferHDR = preferHDR

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil {
            overrides.keyFrameInterval = keyFrameInterval
        }
        if overrides.frameQuality == nil {
            overrides.frameQuality = keyframeQuality
        }
        applyEncoderOverrides(overrides, to: &request)

        let message = try ControlMessage(type: .selectApp, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        streamingAppBundleID = bundleIdentifier
        MirageLogger.client("Requested to stream app: \(bundleIdentifier)")
    }

    /// Cancel a window cooldown and close immediately.
    /// - Parameter windowID: The window currently in cooldown.
    public func cancelCooldown(windowID: WindowID) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let request = CancelCooldownMessage(windowID: windowID)
        let message = try ControlMessage(type: .cancelCooldown, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        MirageLogger.client("Cancel cooldown requested for window \(windowID)")
    }

    /// Start streaming the full desktop (virtual display mirroring mode)
    /// - Parameters:
    ///   - quality: Quality preset for the stream
    ///   - scaleFactor: Optional display scale factor
    ///   - displayResolution: Client's display resolution for virtual display sizing
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - captureSource: Optional desktop capture source override.
    // TODO: HDR support - requires proper virtual display EDR configuration
    // ///   - preferHDR: Whether to request HDR streaming (Rec. 2020 with PQ)
    public func startDesktopStream(
        quality: MirageQualityPreset = .medium,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        captureSource: MirageDesktopCaptureSource? = nil
        // preferHDR: Bool = false
    ) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        // Use provided display resolution or detect from main display
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())

        guard effectiveDisplayResolution.width > 0 && effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Invalid display resolution")
        }

        var request = StartDesktopStreamMessage(
            preferredQuality: quality,
            scaleFactor: scaleFactor,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            keyFrameInterval: nil,
            frameQuality: nil,
            keyframeQuality: nil,
            pixelFormat: nil,
            colorSpace: nil,
            captureSource: captureSource,
            minBitrate: nil,
            maxBitrate: nil,
            streamScale: clampedStreamScale(),
            adaptiveScaleEnabled: adaptiveScaleEnabled,
            dataPort: nil,  // Host will use our UDP connection
            maxRefreshRate: getScreenMaxRefreshRate()
        )
        // TODO: HDR support - requires proper virtual display EDR configuration
        // request.preferHDR = preferHDR

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil {
            overrides.keyFrameInterval = keyFrameInterval
        }
        if overrides.frameQuality == nil {
            overrides.frameQuality = keyframeQuality
        }
        applyEncoderOverrides(overrides, to: &request)

        if let captureSource {
            MirageLogger.client("Requesting desktop capture source: \(captureSource.displayName)")
        }

        let message = try ControlMessage(type: .startDesktopStream, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        MirageLogger.client("Requested desktop stream: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))")
    }

    /// Stop the current desktop stream
    public func stopDesktopStream() async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        guard let streamID = desktopStreamID else {
            MirageLogger.client("No active desktop stream to stop")
            return
        }

        let request = StopDesktopStreamMessage(streamID: streamID)
        let message = try ControlMessage(type: .stopDesktopStream, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        MirageLogger.client("Requested stop desktop stream: \(streamID)")
    }

    /// Start viewing a remote window
    /// - Parameters:
    ///   - window: The remote window to stream
    ///   - quality: Quality preset for the stream
    ///   - expectedPixelSize: Optional pixel dimensions the client expects to render at.
    ///     If provided, the host will encode at this resolution from the start.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///     Used with expectedPixelSize to calculate point-based window size.
    ///   - displayResolution: Client's physical display resolution in pixels.
    ///     If provided, host creates a virtual display at this resolution for optimal quality.
    ///   - keyFrameInterval: Optional keyframe interval in frames. Higher = fewer lag spikes.
    ///     Examples: 600 (10 seconds @ 60fps), 300 (5 seconds @ 60fps)
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0). Lower = smaller frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    public func startViewing(
        window: MirageWindow,
        quality: MirageQualityPreset = .medium,
        expectedPixelSize: CGSize? = nil,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
    ) async throws -> ClientStreamSession {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        // Note: Decoder/reassembler are created per-stream AFTER receiving streamStarted with the stream ID
        // This enables true multi-stream support where each stream has its own decode pipeline

        // Send startStream request (no dataPort needed - host will use our UDP connection)
        // Include client's expected pixel size if provided so host can encode at correct resolution from the start
        var request = StartStreamMessage(windowID: window.id, preferredQuality: quality, dataPort: nil)
        if let expectedPixelSize, expectedPixelSize.width > 0, expectedPixelSize.height > 0 {
            request.pixelWidth = Int(expectedPixelSize.width)
            request.pixelHeight = Int(expectedPixelSize.height)
            request.scaleFactor = scaleFactor
        }

        // Include display resolution for virtual display sizing
        // This enables 1:1 resolution mapping between client and host
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())
        if effectiveDisplayResolution.width > 0 && effectiveDisplayResolution.height > 0 {
            request.displayWidth = Int(effectiveDisplayResolution.width)
            request.displayHeight = Int(effectiveDisplayResolution.height)
            MirageLogger.client("Including display resolution: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))")
        }

        // Include encoder config overrides if specified
        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil {
            overrides.keyFrameInterval = keyFrameInterval
        }
        if overrides.frameQuality == nil {
            overrides.frameQuality = keyframeQuality
        }
        applyEncoderOverrides(overrides, to: &request)

        request.streamScale = clampedStreamScale()
        request.adaptiveScaleEnabled = adaptiveScaleEnabled

        // Include screen refresh rate for 120fps support on P2P connections
        request.maxRefreshRate = getScreenMaxRefreshRate()

        let message = try ControlMessage(type: .startStream, content: request)
        let messageData = message.serialize()

        MirageLogger.client("Sending startStream for window \(window.id)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: messageData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Wait for streamStarted response from server to get the real stream ID
        let realStreamID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StreamID, Error>) in
            self.streamStartedContinuation = continuation
        }

        MirageLogger.client("Stream started with ID \(realStreamID)")

        // Create per-stream controller (owns decoder and reassembler)
        await setupControllerForStream(realStreamID)

        // Add to active streams set (thread-safe for packet filtering)
        addActiveStreamID(realStreamID)

        // Create session with the REAL stream ID from server
        let session = ClientStreamSession(
            id: realStreamID,
            window: window,
            quality: quality
        )

        activeStreams.append(session)
        return session
    }

    /// Set up or reset controller for a specific stream.
    /// StreamController owns the decoder, reassembler, and resize state machine.
    /// If controller already exists (e.g., after resize or reconnection), resets its state.
    private func setupControllerForStream(_ streamID: StreamID) async {
        // If controller already exists, reset its state for new session
        if let existingController = controllersByStream[streamID] {
            await existingController.resetForNewSession()
            MirageLogger.client("Reset existing controller for stream \(streamID)")
            return
        }

        // Create new controller
        let controller = StreamController(streamID: streamID)
        controllersByStream[streamID] = controller

        // Set up callbacks before starting
        let capturedStreamID = streamID
        await controller.setCallbacks(
            onKeyframeNeeded: { [weak self] in
                self?.sendKeyframeRequest(for: capturedStreamID)
            },
            onResizeEvent: { [weak self] event in
                self?.handleResizeEvent(event, for: capturedStreamID)
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self] metrics in
                guard let self else { return }
                self.metricsStore.updateClientMetrics(
                    streamID: capturedStreamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    droppedFrames: metrics.droppedFrames
                )
            },
            onFirstFrame: { [weak self] in
                self?.sessionStore.markFirstFrameReceived(for: capturedStreamID)
            },
            onInputBlockingChanged: { [weak self] isBlocked in
                self?.setInputBlocked(isBlocked, for: capturedStreamID)
            }
        )

        // Start the controller (sets up decoder and reassembler internally)
        await controller.start()

        // Update thread-safe snapshot for UDP receive loop
        await updateReassemblerSnapshot()

        MirageLogger.client("Created new controller for stream \(streamID)")
    }

    /// Handle resize event from StreamController
    private func handleResizeEvent(_ event: StreamController.ResizeEvent, for streamID: StreamID) {
        // Get the active session for this stream to find the windowID
        guard let session = activeStreams.first(where: { $0.id == streamID }) else {
            MirageLogger.error(.client, "No active session for stream \(streamID) during resize")
            return
        }

        // Create relative resize event
        let resizeEvent = MirageRelativeResizeEvent(
            windowID: session.window.id,
            aspectRatio: event.aspectRatio,
            relativeScale: event.relativeScale,
            clientScreenSize: event.clientScreenSize,
            pixelWidth: event.pixelWidth,
            pixelHeight: event.pixelHeight
        )

        // Send as input event
        sendInputFireAndForget(.relativeResize(resizeEvent), forStream: streamID)
    }

    /// Get the controller for a stream (for view access)
    func controller(for streamID: StreamID) -> StreamController? {
        controllersByStream[streamID]
    }

    /// Start UDP connection to host's data port for receiving video
    private func startVideoConnection() async throws {
        guard hostDataPort > 0 else {
            throw MirageError.protocolError("Host data port not set")
        }

        guard let connection = self.connection else {
            throw MirageError.protocolError("No TCP connection")
        }

        // Get the host address from the TCP connection's resolved remote endpoint
        let host: NWEndpoint.Host
        if case .hostPort(let h, _) = connection.endpoint {
            // Direct hostPort endpoint
            host = h
        } else if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                  case .hostPort(let h, _) = remoteEndpoint {
            // Resolved Bonjour endpoint
            host = h
        } else {
            // Try to use the original Bonjour service endpoint with data port
            // Create UDP connection using same endpoint type but different port
            MirageLogger.client("Using Bonjour endpoint for UDP")
            if case .service(_, _, _, _) = connection.endpoint {
                // Can't change port on service endpoint, need resolved address
                // Fall back to using host discovery info
                if let connectedHost = connectedHost {
                    let dataEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(connectedHost.name), port: NWEndpoint.Port(rawValue: hostDataPort)!)
                    MirageLogger.client("Connecting to host data port via hostname \(connectedHost.name):\(hostDataPort)")
                    let params = NWParameters.udp
                    params.serviceClass = .interactiveVideo
                    params.includePeerToPeer = networkConfig.enablePeerToPeer

                    let udpConn = NWConnection(to: dataEndpoint, using: params)
                    self.udpConnection = udpConn

                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let box = ContinuationBox<Void>(continuation)
                        udpConn.stateUpdateHandler = { [box] state in
                            switch state {
                            case .ready:
                                box.resume()
                            case .failed(let error):
                                box.resume(throwing: error)
                            case .cancelled:
                                box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                            default:
                                break
                            }
                        }
                        udpConn.start(queue: .global(qos: .userInteractive))
                    }
                    MirageLogger.client("UDP connection established to host data port")
                    startReceivingVideo()
                    return
                }
            }
            throw MirageError.protocolError("Cannot determine host address")
        }

        let dataEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: hostDataPort)!)
        MirageLogger.client("Connecting to host data port at \(host):\(hostDataPort)")

        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let udpConn = NWConnection(to: dataEndpoint, using: params)
        self.udpConnection = udpConn

        // Wait for connection to be ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)

            udpConn.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume()
                case .failed(let error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                default:
                    break
                }
            }

            udpConn.start(queue: .global(qos: .userInteractive))
        }

        MirageLogger.client("UDP connection established to host data port")

        // Start receiving video data
        startReceivingVideo()
    }

    /// Start receiving video data from UDP connection
    private func startReceivingVideo() {
        guard let udpConn = udpConnection else { return }

        // CRITICAL: Use nonisolated helper to avoid MainActor isolation inheritance.
        // The nested receiveNext() function would inherit @MainActor from this method,
        // causing unsafeForcedSync when called from Network callbacks during iOS gesture tracking.
        // We pass `self` as a weak reference for thread-safe reassembler lookup.
        startUDPReceiveLoop(udpConnection: udpConn, service: self)
    }

    /// Start the UDP receive loop in a nonisolated context.
    /// CRITICAL: This MUST be nonisolated to avoid MainActor synchronization in the hot path.
    /// During iOS gesture tracking (UITrackingRunLoopMode), MainActor is blocked. If the
    /// nested receiveNext() function inherited MainActor isolation, the Network callback
    /// would trigger unsafeForcedSync, causing the entire app to freeze during drag operations.
    private nonisolated func startUDPReceiveLoop(
        udpConnection: NWConnection,
        service: MirageClientService
    ) {
        // Nested function now inherits nonisolated (NOT MainActor) from this function
        @Sendable func receiveNext() {
            udpConnection.receive(minimumIncompleteLength: MirageHeaderSize, maximumLength: 65536) { data, _, isComplete, error in

                if let data, data.count >= MirageHeaderSize {
                    if let header = FrameHeader.deserialize(from: data) {
                        let streamID = header.streamID

                        // Thread-safe stream ID validation - check if this stream is active
                        guard service.activeStreamIDsForFiltering.contains(streamID) else {
                            receiveNext()
                            return
                        }

                        // Get the reassembler for this specific stream
                        guard let reassembler = service.reassemblerForStream(streamID) else {
                            receiveNext()
                            return
                        }

                        // CRITICAL: Copy payload data BEFORE creating async Task
                        // data.dropFirst() returns a Slice that references the original data buffer.
                        // If we pass it to an async Task, the original buffer may be freed before
                        // the Task executes, causing use-after-free corruption → BadData decode errors.
                        let payload = Data(data.dropFirst(MirageHeaderSize))

                        // Process packet - reassembler is an actor with its own synchronization
                        Task {
                            await reassembler.processPacket(payload, header: header)
                        }
                    }
                }

                if let error {
                    MirageLogger.error(.client, "UDP receive error: \(error)")
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    /// Send stream registration to host via UDP
    private func sendStreamRegistration(streamID: StreamID) async throws {
        guard let udpConn = udpConnection else {
            throw MirageError.protocolError("No UDP connection")
        }

        // Create registration packet: magic (4) + streamID (2) + deviceID (16)
        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x47]) // "MIRG" magic
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }

        MirageLogger.client("Sending stream registration for stream \(streamID)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        MirageLogger.client("Stream registration sent")
        lastKeyframeRequestTime[streamID] = CFAbsoluteTimeGetCurrent()
    }

    /// Stop the video connection
    private func stopVideoConnection() {
        udpConnection?.cancel()
        udpConnection = nil
        hostDataPort = 0
    }

    /// Request a keyframe from the host when decoder encounters errors
    /// This allows recovery from corrupted stream state
    private func sendKeyframeRequest(for streamID: StreamID) {
        guard case .connected = connectionState, let connection else {
            MirageLogger.client("Cannot send keyframe request - not connected")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let lastTime = lastKeyframeRequestTime[streamID], now - lastTime < keyframeRequestCooldown {
            let remaining = Int(((keyframeRequestCooldown - (now - lastTime)) * 1000).rounded())
            MirageLogger.client("Keyframe request skipped (cooldown \(remaining)ms) for stream \(streamID)")
            return
        }
        lastKeyframeRequestTime[streamID] = now

        let request = KeyframeRequestMessage(streamID: streamID)
        guard let message = try? ControlMessage(type: .keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return
        }

        let data = message.serialize()
        connection.send(content: data, completion: .idempotent)
        MirageLogger.client("Sent keyframe request for stream \(streamID)")
    }

    /// Request stream recovery by forcing a keyframe.
    /// Call this when returning from background to re-sync the video decoder.
    /// - Parameter streamID: The stream to recover
    public func requestStreamRecovery(for streamID: StreamID) {
        guard case .connected = connectionState else {
            MirageLogger.client("Stream recovery skipped - not connected")
            return
        }

        MirageLogger.client("Stream recovery requested for stream \(streamID)")

        // Clear stale frame from cache to avoid showing frozen content
        MirageFrameCache.shared.clear(for: streamID)

        // Request stream recovery from controller and refresh UDP registration
        Task { [weak self] in
            guard let self else { return }
            await controllersByStream[streamID]?.requestRecovery()

            do {
                if udpConnection == nil {
                    try await startVideoConnection()
                }
                try await sendStreamRegistration(streamID: streamID)
            } catch {
                MirageLogger.error(.client, "Stream recovery registration failed: \(error)")
                stopVideoConnection()
            }
        }
    }

    /// Stop viewing a stream
    /// - Parameters:
    ///   - session: The stream session to stop
    ///   - minimizeWindow: Whether to minimize the source window on the host (default: false)
    public func stopViewing(_ session: ClientStreamSession, minimizeWindow: Bool = false) async {
        let streamID = session.id

        // Stop screen polling for this stream
        stopScreenPolling()

        // Clear cached frames for this stream
        MirageFrameCache.shared.clear(for: streamID)

        let request = StopStreamMessage(streamID: streamID, minimizeWindow: minimizeWindow)
        if let message = try? ControlMessage(type: .stopStream, content: request),
           let connection {
            connection.send(content: message.serialize(), completion: .idempotent)
        }

        activeStreams.removeAll { $0.id == streamID }

        // Remove from active streams set (thread-safe)
        removeActiveStreamID(streamID)

        // Clean up per-stream resources
        registeredStreamIDs.remove(streamID)

        // Stop and remove controller for this stream
        if let controller = controllersByStream[streamID] {
            await controller.stop()
            controllersByStream.removeValue(forKey: streamID)
        }

        // Update thread-safe snapshot
        await updateReassemblerSnapshot()
    }

    /// Send an input event to the host with network confirmation
    /// Note: Input is silently blocked when decoder is unhealthy (awaiting keyframe or decode errors)
    /// to prevent user from clicking on things they can't see
    public func sendInput(_ event: MirageInputEvent, forStream streamID: StreamID) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        // Block input when decoder is unhealthy - user can't see what they're clicking
        // This prevents accidental clicks during resize, keyframe recovery, or decode errors
        if isInputBlocked(for: streamID) {
            return  // Silently block - decoder is awaiting keyframe or has errors
        }

        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, content: inputMessage)
        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Send an input event to the host without waiting for network confirmation
    /// Use this for low-latency input handling where delivery confirmation isn't needed
    /// Note: Input is silently blocked when decoder is unhealthy (awaiting keyframe or decode errors)
    /// to prevent user from clicking on things they can't see
    public func sendInputFireAndForget(_ event: MirageInputEvent, forStream streamID: StreamID) {
        guard case .connected = connectionState, let connection else {
            return  // Silently fail if not connected
        }

        // Block input when decoder is unhealthy - user can't see what they're clicking
        // This prevents accidental clicks during resize, keyframe recovery, or decode errors
        if isInputBlocked(for: streamID) {
            return  // Silently block - decoder is awaiting keyframe or has errors
        }

        // Track cursor position from mouse events for graceful input release during decode errors
        if let location = event.mouseLocation {
            lastCursorPositionsLock.lock()
            _lastCursorPositions[streamID] = location
            lastCursorPositionsLock.unlock()
        }

        do {
            let inputMessage = InputEventMessage(streamID: streamID, event: event)
            let message = try ControlMessage(type: .inputEvent, content: inputMessage)
            let data = message.serialize()

            // Send without waiting for completion - .idempotent doesn't block
            connection.send(content: data, completion: .idempotent)
        } catch {
            MirageLogger.error(.client, "Failed to send input: \(error)")
        }
    }

    /// Get the minimum window size for a stream (in points)
    /// Returns nil if no minimum size was received from the host
    public func getMinimumSize(forStream streamID: StreamID) -> (minWidth: Int, minHeight: Int)? {
        streamMinSizes[streamID]
    }

    // MARK: - Menu Bar Actions

    /// Execute a menu action on the host for a specific stream.
    ///
    /// - Parameters:
    ///   - streamID: The stream to execute the action on
    ///   - actionPath: Path to the menu item [menuIndex, itemIndex, submenuIndex, ...]
    /// - Throws: If not connected or message encoding fails
    public func executeMenuAction(streamID: StreamID, actionPath: [Int]) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let request = MenuActionRequestMessage(streamID: streamID, actionPath: actionPath)
        let message = try ControlMessage(type: .menuActionRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    // MARK: - Private

    private func setupMessageHandlers() {
        Task {
            await transport?.setControlMessageHandler { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handleControlMessage(message)
                }
            }

            await transport?.setVideoPacketHandler { [weak self] data, header in
                Task { @MainActor [weak self] in
                    await self?.handleVideoPacket(data, header: header)
                }
            }
        }
    }

    private func handleControlMessage(_ message: ControlMessage) async {
        switch message.type {
        case .helloResponse:
            do {
                let response = try message.decode(HelloResponseMessage.self)
                if response.accepted {
                    hostDataPort = response.dataPort
                    MirageLogger.client("Received hello response, dataPort: \(hostDataPort)")
                } else {
                    MirageLogger.client("Connection rejected by host")
                    connectionState = .error("Connection rejected")
                }
            } catch {
                MirageLogger.error(.client, "Failed to decode hello response: \(error)")
            }

        case .windowList:
            do {
                let windowList = try message.decode(WindowListMessage.self)
                MirageLogger.client("Received window list with \(windowList.windows.count) windows")
                for window in windowList.windows {
                    MirageLogger.client("  - \(window.application?.name ?? "Unknown"): \(window.title ?? "Untitled")")
                }
                hasReceivedWindowList = true
                availableWindows = windowList.windows
                delegate?.clientService(self, didUpdateWindowList: windowList.windows)
            } catch {
                MirageLogger.error(.client, "Failed to decode window list: \(error)")
            }

        case .windowUpdate:
            if let update = try? message.decode(WindowUpdateMessage.self) {
                // Apply updates to window list
                for window in update.added {
                    if !availableWindows.contains(where: { $0.id == window.id }) {
                        availableWindows.append(window)
                    }
                }
                for id in update.removed {
                    availableWindows.removeAll { $0.id == id }
                }
                for window in update.updated {
                    if let index = availableWindows.firstIndex(where: { $0.id == window.id }) {
                        availableWindows[index] = window
                    }
                }
            }

        case .streamStarted:
            if let started = try? message.decode(StreamStartedMessage.self) {
                let streamID = started.streamID
                MirageLogger.client("Stream started: \(streamID) for window \(started.windowID)")

                // Capture dimension token from host (if provided)
                let dimensionToken = started.dimensionToken

                // Reset controller's reassembler for this specific stream to clear any stale fragments
                // This prevents old fragments from contaminating new frames after reconnection or resize
                Task { [weak self] in
                    if let controller = self?.controllersByStream[streamID] {
                        let reassembler = await controller.getReassembler()
                        await reassembler.reset()
                        // Set dimension token on reassembler if host provided one
                        if let token = dimensionToken {
                            await reassembler.updateExpectedDimensionToken(token)
                        }
                    }
                }

                // Store minimum size from host (if provided)
                if let minW = started.minWidth, let minH = started.minHeight {
                    streamMinSizes[streamID] = (minWidth: minW, minHeight: minH)
                    MirageLogger.client("Minimum window size: \(minW)x\(minH) pts")
                    let minSize = CGSize(width: minW, height: minH)
                    sessionStore.updateMinimumSize(for: streamID, minSize: minSize)
                    onStreamMinimumSizeUpdate?(streamID, minSize)
                }

                // For app-centric streaming, the decoder needs to be set up here since
                // startViewing is not called. For traditional streaming, the continuation
                // handler in startViewing will set up the decoder.
                let isAppCentricStream = streamStartedContinuation == nil

                // Resume the waiting startViewing call with the real stream ID
                streamStartedContinuation?.resume(returning: streamID)
                streamStartedContinuation = nil

                // Start screen polling for external display detection (iOS only)
                startScreenPolling(for: streamID)

                // CRITICAL: Set up controller BEFORE registering for UDP
                // This ensures frames can be processed as soon as they arrive.
                // For traditional streaming, startViewing also calls setupControllerForStream,
                // but we must ensure it completes before UDP registration. The setup function
                // has a dedup check, so calling it twice is safe.
                if !registeredStreamIDs.contains(streamID) {
                    registeredStreamIDs.insert(streamID)
                    Task {
                        do {
                            // Step 1: Always set up controller before UDP registration
                            // For app-centric: this is the only setup call
                            // For traditional: startViewing may also call, but dedup check handles it
                            await self.setupControllerForStream(streamID)
                            self.addActiveStreamID(streamID)
                            if isAppCentricStream {
                                MirageLogger.client("Controller set up for app-centric stream \(streamID)")
                            }

                            // Set dimension token after controller is set up
                            if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                                let reassembler = await controller.getReassembler()
                                await reassembler.updateExpectedDimensionToken(token)
                            }

                            // Step 2: Create UDP connection to host's data port
                            if self.udpConnection == nil {
                                try await self.startVideoConnection()
                            }

                            // Step 3: Send registration - host will send keyframe
                            try await self.sendStreamRegistration(streamID: streamID)
                        } catch {
                            MirageLogger.error(.client, "Failed to establish video connection: \(error)")
                            self.registeredStreamIDs.remove(streamID)
                        }
                    }
                }
            }

        case .streamStopped:
            if let stopped = try? message.decode(StreamStoppedMessage.self) {
                let streamID = stopped.streamID
                activeStreams.removeAll { $0.id == streamID }
                MirageFrameCache.shared.clear(for: streamID)
                metricsStore.clear(streamID: streamID)
                cursorStore.clear(streamID: streamID)

                // Clean up per-stream resources
                removeActiveStreamID(streamID)
                registeredStreamIDs.remove(streamID)

                // Clean up controller for this stream
                Task { [weak self] in
                    guard let self else { return }
                    if let controller = self.controllersByStream[streamID] {
                        await controller.stop()
                        self.controllersByStream.removeValue(forKey: streamID)
                    }
                    await self.updateReassemblerSnapshot()
                }
            }

        case .streamMetricsUpdate:
            if let metrics = try? message.decode(StreamMetricsMessage.self) {
                metricsStore.updateHostMetrics(
                    streamID: metrics.streamID,
                    encodedFPS: metrics.encodedFPS,
                    idleEncodedFPS: metrics.idleEncodedFPS,
                    droppedFrames: metrics.droppedFrames,
                    activeQuality: Double(metrics.activeQuality)
                )
            }

        case .error:
            if let error = try? message.decode(ErrorMessage.self) {
                delegate?.clientService(self, didEncounterError: MirageError.protocolError(error.message))
            }

        case .disconnect:
            if let disconnect = try? message.decode(DisconnectMessage.self) {
                await handleDisconnect(
                    reason: disconnect.reason.rawValue,
                    state: .disconnected,
                    notifyDelegate: true
                )
            }

        case .cursorUpdate:
            if let update = try? message.decode(CursorUpdateMessage.self) {
                MirageLogger.client("Cursor update received: \(update.cursorType) (visible: \(update.isVisible))")
                cursorStore.updateCursor(
                    streamID: update.streamID,
                    cursorType: update.cursorType,
                    isVisible: update.isVisible
                )
                onCursorUpdate?(update.streamID, update.cursorType, update.isVisible)
            }

        case .contentBoundsUpdate:
            if let update = try? message.decode(ContentBoundsUpdateMessage.self) {
                MirageLogger.client("Content bounds update for stream \(update.streamID): \(update.bounds)")
                onContentBoundsUpdate?(update.streamID, update.bounds)
                delegate?.clientService(self, didReceiveContentBoundsUpdate: update.bounds, forStream: update.streamID)
            }

        case .sessionStateUpdate:
            do {
                let update = try message.decode(SessionStateUpdateMessage.self)
                MirageLogger.client("Host session state: \(update.state), requires username: \(update.requiresUsername)")
                hostSessionState = update.state
                currentSessionToken = update.sessionToken
                delegate?.clientService(self, hostSessionStateChanged: update.state, requiresUsername: update.requiresUsername)
            } catch {
                MirageLogger.error(.client, "Failed to decode session state update: \(error)")
            }

        case .unlockResponse:
            do {
                let response = try message.decode(UnlockResponseMessage.self)
                MirageLogger.client("Unlock response: success=\(response.success)")
                if response.success {
                    hostSessionState = response.newState
                    if let token = response.newSessionToken {
                        currentSessionToken = token
                    }
                }
                delegate?.clientService(
                    self,
                    unlockDidComplete: response.success,
                    error: response.error?.message,
                    canRetry: response.canRetry,
                    retriesRemaining: response.retriesRemaining,
                    retryAfterSeconds: response.retryAfterSeconds
                )
            } catch {
                MirageLogger.error(.client, "Failed to decode unlock response: \(error)")
            }

        case .loginDisplayReady:
            do {
                let ready = try message.decode(LoginDisplayReadyMessage.self)
                MirageLogger.client("Login display ready: stream=\(ready.streamID), \(ready.width)x\(ready.height)")
                let streamID = StreamID(ready.streamID)
                loginDisplayStreamID = streamID
                loginDisplayResolution = CGSize(width: ready.width, height: ready.height)
                sessionStore.startLoginDisplay(streamID: streamID, resolution: CGSize(width: ready.width, height: ready.height))

                // Capture dimension token from host (if provided)
                let dimensionToken = ready.dimensionToken

                // CRITICAL: Set up controller BEFORE registering for UDP
                // This ensures frames can be processed as soon as they arrive.
                Task {
                    // Step 1: Set up controller
                    await self.setupControllerForStream(streamID)

                    // Step 2: Add to active stream filter BEFORE UDP registration
                    self.addActiveStreamID(streamID)

                    // Set dimension token after controller is set up
                    if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                        let reassembler = await controller.getReassembler()
                        await reassembler.updateExpectedDimensionToken(token)
                    }

                    // Step 3: NOW register for UDP - host will send keyframe on registration
                    if !self.registeredStreamIDs.contains(streamID) {
                        self.registeredStreamIDs.insert(streamID)
                        do {
                            if self.udpConnection == nil {
                                try await self.startVideoConnection()
                            }
                            try await self.sendStreamRegistration(streamID: streamID)
                            MirageLogger.client("Registered for login display video stream \(streamID)")
                        } catch {
                            MirageLogger.error(.client, "Failed to establish video connection for login display: \(error)")
                            self.registeredStreamIDs.remove(streamID)
                        }
                    }
                }

                delegate?.clientService(
                    self,
                    loginDisplayDidStart: StreamID(ready.streamID),
                    resolution: CGSize(width: ready.width, height: ready.height),
                    sessionState: ready.sessionState,
                    requiresUsername: ready.requiresUsername
                )
            } catch {
                MirageLogger.error(.client, "Failed to decode login display ready: \(error)")
            }

        case .loginDisplayStopped:
            do {
                let stopped = try message.decode(LoginDisplayStoppedMessage.self)
                let streamID = StreamID(stopped.streamID)
                MirageLogger.client("Login display stopped: stream=\(streamID)")
                loginDisplayStreamID = nil
                loginDisplayResolution = nil
                sessionStore.stopLoginDisplay()
                metricsStore.clear(streamID: streamID)
                cursorStore.clear(streamID: streamID)

                // Clean up login display stream resources
                removeActiveStreamID(streamID)
                registeredStreamIDs.remove(streamID)

                // Clean up controller for login display
                Task {
                    if let controller = self.controllersByStream[streamID] {
                        await controller.stop()
                        self.controllersByStream.removeValue(forKey: streamID)
                    }
                    await self.updateReassemblerSnapshot()
                }

                delegate?.clientService(self, loginDisplayDidStop: streamID, newState: stopped.newState)
            } catch {
                MirageLogger.error(.client, "Failed to decode login display stopped: \(error)")
            }

        // MARK: Desktop Streaming Messages

        case .desktopStreamStarted:
            do {
                let started = try message.decode(DesktopStreamStartedMessage.self)
                MirageLogger.client("Desktop stream started: stream=\(started.streamID), \(started.width)x\(started.height)")
                let streamID = started.streamID
                desktopStreamID = streamID
                desktopStreamResolution = CGSize(width: started.width, height: started.height)

                // Capture dimension token from host (if provided)
                let dimensionToken = started.dimensionToken

                // CRITICAL: Set up controller BEFORE registering for UDP
                // This ensures frames can be processed as soon as they arrive.
                // Previously, two separate Tasks caused a race where UDP frames arrived
                // before decoder/reassembler/activeStreamID were ready, causing ~1/3 frame loss.
                Task {
                    // Step 1: Set up controller
                    await self.setupControllerForStream(streamID)

                    // Step 2: Add to active stream filter BEFORE UDP registration
                    self.addActiveStreamID(streamID)

                    // Set dimension token after controller is set up
                    if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                        let reassembler = await controller.getReassembler()
                        await reassembler.updateExpectedDimensionToken(token)
                    }

                    // Step 3: NOW register for UDP - host will send keyframe on registration
                    if !self.registeredStreamIDs.contains(streamID) {
                        self.registeredStreamIDs.insert(streamID)
                        do {
                            if self.udpConnection == nil {
                                try await self.startVideoConnection()
                            }
                            try await self.sendStreamRegistration(streamID: streamID)
                            MirageLogger.client("Registered for desktop stream video \(streamID)")
                        } catch {
                            MirageLogger.error(.client, "Failed to establish video connection for desktop stream: \(error)")
                            self.registeredStreamIDs.remove(streamID)
                        }
                    }
                }

                // Notify callbacks
                onDesktopStreamStarted?(streamID, CGSize(width: started.width, height: started.height), started.displayCount)

                // Trigger minimum size update for blur handling
                let desktopMinSize = CGSize(width: started.width, height: started.height)
                sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
                onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
            } catch {
                MirageLogger.error(.client, "Failed to decode desktop stream started: \(error)")
            }

        case .desktopStreamStopped:
            do {
                let stopped = try message.decode(DesktopStreamStoppedMessage.self)
                let streamID = stopped.streamID
                MirageLogger.client("Desktop stream stopped: stream=\(streamID), reason=\(stopped.reason)")

                // Clean up desktop stream state
                desktopStreamID = nil
                desktopStreamResolution = nil
                metricsStore.clear(streamID: streamID)
                cursorStore.clear(streamID: streamID)

                // Clean up stream resources
                removeActiveStreamID(streamID)
                registeredStreamIDs.remove(streamID)

                // Clean up controller
                Task {
                    if let controller = self.controllersByStream[streamID] {
                        await controller.stop()
                        self.controllersByStream.removeValue(forKey: streamID)
                    }
                    await self.updateReassemblerSnapshot()
                }

                // Notify callbacks
                onDesktopStreamStopped?(streamID, stopped.reason)
            } catch {
                MirageLogger.error(.client, "Failed to decode desktop stream stopped: \(error)")
            }

        // MARK: App-Centric Streaming Messages

        case .appList:
            do {
                let appList = try message.decode(AppListMessage.self)
                MirageLogger.client("Received app list with \(appList.apps.count) apps")
                availableApps = appList.apps
                hasReceivedAppList = true
                onAppListReceived?(appList.apps)
            } catch {
                MirageLogger.error(.client, "Failed to decode app list: \(error)")
            }

        case .appStreamStarted:
            do {
                let started = try message.decode(AppStreamStartedMessage.self)
                MirageLogger.client("App stream started: \(started.appName) with \(started.windows.count) windows")
                streamingAppBundleID = started.bundleIdentifier
                onAppStreamStarted?(started.bundleIdentifier, started.appName, started.windows)
            } catch {
                MirageLogger.error(.client, "Failed to decode app stream started: \(error)")
            }

        case .windowAddedToStream:
            do {
                let added = try message.decode(WindowAddedToStreamMessage.self)
                MirageLogger.client("Window added to stream: \(added.windowID)")
                onWindowAddedToStream?(added)
            } catch {
                MirageLogger.error(.client, "Failed to decode window added: \(error)")
            }

        case .windowCooldownStarted:
            do {
                let cooldown = try message.decode(WindowCooldownStartedMessage.self)
                MirageLogger.client("Window cooldown started: \(cooldown.windowID) for \(cooldown.durationSeconds)s")
                onWindowCooldownStarted?(cooldown)
            } catch {
                MirageLogger.error(.client, "Failed to decode cooldown started: \(error)")
            }

        case .windowCooldownCancelled:
            do {
                let cancelled = try message.decode(WindowCooldownCancelledMessage.self)
                MirageLogger.client("Window cooldown cancelled, new window: \(cancelled.newWindowID)")
                onWindowCooldownCancelled?(cancelled)
            } catch {
                MirageLogger.error(.client, "Failed to decode cooldown cancelled: \(error)")
            }

        case .returnToAppSelection:
            do {
                let returnMsg = try message.decode(ReturnToAppSelectionMessage.self)
                MirageLogger.client("Return to app selection for window: \(returnMsg.windowID)")
                streamingAppBundleID = nil
                onReturnToAppSelection?(returnMsg)
            } catch {
                MirageLogger.error(.client, "Failed to decode return to app selection: \(error)")
            }

        case .appTerminated:
            do {
                let terminated = try message.decode(AppTerminatedMessage.self)
                MirageLogger.client("App terminated: \(terminated.bundleIdentifier)")
                if streamingAppBundleID == terminated.bundleIdentifier {
                    streamingAppBundleID = nil
                }
                onAppTerminated?(terminated)
            } catch {
                MirageLogger.error(.client, "Failed to decode app terminated: \(error)")
            }

        // MARK: Menu Bar Passthrough Messages

        case .menuBarUpdate:
            do {
                let update = try message.decode(MenuBarUpdateMessage.self)
                if let menuBar = update.menuBar {
                    MirageLogger.log(.menuBar, "Received menu bar for stream \(update.streamID): \(menuBar.menus.count) menus")
                } else {
                    MirageLogger.log(.menuBar, "Received empty menu bar for stream \(update.streamID)")
                }
                onMenuBarUpdate?(update.streamID, update.menuBar)
            } catch {
                MirageLogger.error(.menuBar, "Failed to decode menu bar update: \(error)")
            }

        case .menuActionResult:
            do {
                let result = try message.decode(MenuActionResultMessage.self)
                MirageLogger.log(.menuBar, "Menu action result for stream \(result.streamID): \(result.success)")
                onMenuActionResult?(result.streamID, result.success, result.errorMessage)
            } catch {
                MirageLogger.error(.menuBar, "Failed to decode menu action result: \(error)")
            }

        default:
            break
        }
    }

    private func handleVideoPacket(_ data: Data, header: FrameHeader) async {
        // Forward to appropriate stream's decoder
        delegate?.clientService(self, didReceiveVideoPacket: data, forStream: header.streamID)
    }

    private func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let frameQuality = overrides.frameQuality, frameQuality > 0 {
            request.frameQuality = frameQuality
            MirageLogger.client("Requesting frame quality: \(frameQuality)")
        }
        if let keyframeQuality = overrides.keyframeQuality, keyframeQuality > 0 {
            request.keyframeQuality = keyframeQuality
            MirageLogger.client("Requesting keyframe quality: \(keyframeQuality)")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let Mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger.client("Requesting minimum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let Mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger.client("Requesting maximum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }

    private func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout SelectAppMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let frameQuality = overrides.frameQuality, frameQuality > 0 {
            request.frameQuality = frameQuality
            MirageLogger.client("Requesting frame quality: \(frameQuality)")
        }
        if let keyframeQuality = overrides.keyframeQuality, keyframeQuality > 0 {
            request.keyframeQuality = keyframeQuality
            MirageLogger.client("Requesting keyframe quality: \(keyframeQuality)")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let Mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger.client("Requesting minimum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let Mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger.client("Requesting maximum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }

    private func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartDesktopStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let frameQuality = overrides.frameQuality, frameQuality > 0 {
            request.frameQuality = frameQuality
            MirageLogger.client("Requesting frame quality: \(frameQuality)")
        }
        if let keyframeQuality = overrides.keyframeQuality, keyframeQuality > 0 {
            request.keyframeQuality = keyframeQuality
            MirageLogger.client("Requesting keyframe quality: \(keyframeQuality)")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let Mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger.client("Requesting minimum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let Mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger.client("Requesting maximum bitrate: \(Mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }

    // MARK: - Display Resolution Helpers

    /// Task for polling screen changes on iOS
    private var screenPollingTask: Task<Void, Never>?

    /// Last known screen resolution for change detection
    private var lastKnownScreenResolution: CGSize = .zero

    /// Get the display resolution for the screen the window is currently on
    /// Intelligently detects which display the window is on (built-in vs external)
    private func scaledDisplayResolution(_ resolution: CGSize) -> CGSize {
        let width = max(2, floor(resolution.width / 2) * 2)
        let height = max(2, floor(resolution.height / 2) * 2)
        return CGSize(width: width, height: height)
    }

    private func clampedStreamScale() -> CGFloat {
        let scale = resolutionScale
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    private func getMainDisplayResolution() -> CGSize {
        #if os(macOS)
        guard let mainScreen = NSScreen.main else {
            return CGSize(width: 2560, height: 1600)  // Default fallback
        }
        let scale = mainScreen.backingScaleFactor
        return CGSize(
            width: mainScreen.frame.width * scale,
            height: mainScreen.frame.height * scale
        )
        #elseif os(iOS)
        // Get the screen the window is currently displayed on
        guard let screen = Self.currentWindowScreen() else {
            // Default resolution if no screen can be determined
            return CGSize(width: 2560, height: 1600)
        }
        let nativeBounds = screen.nativeBounds
        if nativeBounds.width > 0, nativeBounds.height > 0 {
            return nativeBounds.size
        }
        let scale = screen.nativeScale
        return CGSize(
            width: screen.bounds.width * scale,
            height: screen.bounds.height * scale
        )
        #elseif os(visionOS)
        // visionOS doesn't have traditional screens, use a sensible default
        return CGSize(width: 2560, height: 1600)
        #else
        return CGSize(width: 2560, height: 1600)
        #endif
    }

    /// Get the maximum refresh rate requested by the client.
    /// iOS relies on the user-selected toggle; other platforms use the screen's max.
    private func getScreenMaxRefreshRate() -> Int {
        #if os(iOS)
        if let override = maxRefreshRateOverride {
            return override
        }
        return 60
        #else
        let screenMax: Int
        #if os(macOS)
        screenMax = NSScreen.main?.maximumFramesPerSecond ?? 120
        #elseif os(visionOS)
        screenMax = 120  // Vision Pro supports 120Hz
        #else
        screenMax = 60
        #endif

        if let override = maxRefreshRateOverride {
            return override
        }
        return screenMax
        #endif
    }

    #if os(iOS)
    /// Cached drawable size from the Metal view (updated by MirageStreamContentView)
    /// Used to help determine which screen the window is actually displayed on
    public static var lastKnownDrawableSize: CGSize = .zero

    /// Returns the screen that the app's window is currently displayed on.
    /// Treats all screens equally - no concept of "main" vs "external".
    /// Returns nil if no screen can be determined.
    public static func currentWindowScreen() -> UIScreen? {
        let allScreens = UIScreen.screens
        guard !allScreens.isEmpty else { return nil }

        // First, try to match drawable size to a screen
        // This is the most reliable way because Metal reports actual rendering resolution
        if lastKnownDrawableSize.width > 0 && lastKnownDrawableSize.height > 0 {
            var bestMatch: UIScreen?
            var bestScore: CGFloat = .greatestFiniteMagnitude

            for screen in allScreens {
                let nativeSize = screen.nativeBounds.size
                // Score is how different the drawable is from this screen's native size
                let widthDiff = abs(nativeSize.width - lastKnownDrawableSize.width)
                let heightDiff = abs(nativeSize.height - lastKnownDrawableSize.height)
                let score = widthDiff + heightDiff

                if score < bestScore {
                    bestScore = score
                    bestMatch = screen
                }
            }

            // If we have a close match (within 100 pixels), use it
            if let match = bestMatch, bestScore < 100 {
                MirageLogger.debug(.client, "currentWindowScreen: matched drawable \(Int(lastKnownDrawableSize.width))x\(Int(lastKnownDrawableSize.height)) to screen \(match.nativeBounds.size)")
                return match
            }
        }

        // Second, try the window scene's screen property
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  scene.activationState == .foregroundActive else { continue }

            let screen = windowScene.screen
            MirageLogger.debug(.client, "currentWindowScreen: scene reports screen=\(screen.bounds)")
            return screen
        }

        // Third, check key window's screen
        if let keyWindow = UIWindow.current {
            let screen = keyWindow.screen
            MirageLogger.debug(.client, "currentWindowScreen: key window screen=\(screen.bounds)")
            return screen
        }

        // Last resort: first available screen
        MirageLogger.debug(.client, "currentWindowScreen: falling back to first available screen")
        return allScreens.first
    }

    /// Alias for currentWindowScreen for clearer API
    public static func preferredScreen() -> UIScreen? {
        return currentWindowScreen()
    }
    #endif

    /// Start polling for screen changes (iOS only)
    /// Detects when user moves app to external display and sends resolution update
    private func startScreenPolling(for streamID: StreamID) {
        #if os(iOS)
        // Cancel any existing polling
        screenPollingTask?.cancel()

        // Store initial resolution (must be on MainActor for UIApplication access)
        lastKnownScreenResolution = getMainDisplayResolution()
        MirageLogger.client("Screen polling started, initial resolution: \(Int(lastKnownScreenResolution.width))x\(Int(lastKnownScreenResolution.height))")

        screenPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Poll every 500ms
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    break // Task cancelled
                }

                guard let self else { break }

                // CRITICAL: UIApplication.shared.connectedScenes must be accessed on MainActor
                // Without this, currentWindowScreen() may return stale/wrong screen info
                let currentResolution = await MainActor.run {
                    self.getMainDisplayResolution()
                }

                // Check if resolution changed significantly (more than 10 pixels difference)
                let widthChanged = abs(currentResolution.width - self.lastKnownScreenResolution.width) > 10
                let heightChanged = abs(currentResolution.height - self.lastKnownScreenResolution.height) > 10

                if widthChanged || heightChanged {
                    MirageLogger.client("Screen changed: \(Int(self.lastKnownScreenResolution.width))x\(Int(self.lastKnownScreenResolution.height)) -> \(Int(currentResolution.width))x\(Int(currentResolution.height))")
                    self.lastKnownScreenResolution = currentResolution

                    // Send resolution change to host
                    do {
                        try await self.sendDisplayResolutionChange(streamID: streamID, newResolution: currentResolution)
                    } catch {
                        MirageLogger.error(.client, "Failed to send display resolution change: \(error)")
                    }
                }
            }
        }
        #endif
    }

    /// Stop screen polling
    private func stopScreenPolling() {
        #if os(iOS)
        screenPollingTask?.cancel()
        screenPollingTask = nil
        #endif
    }

    /// Send display resolution change to host (when window moves to different display)
    public func sendDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let scaledResolution = scaledDisplayResolution(newResolution)
        let request = DisplayResolutionChangeMessage(
            streamID: streamID,
            displayWidth: Int(scaledResolution.width),
            displayHeight: Int(scaledResolution.height)
        )
        let message = try ControlMessage(type: .displayResolutionChange, content: request)

        MirageLogger.client("Sending display resolution change for stream \(streamID): \(Int(scaledResolution.width))x\(Int(scaledResolution.height))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func sendStreamScaleChange(streamID: StreamID, scale: CGFloat, adaptiveScaleEnabled: Bool? = nil) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let clampedScale = max(0.1, min(1.0, scale))
        let request = StreamScaleChangeMessage(
            streamID: streamID,
            streamScale: clampedScale,
            adaptiveScaleEnabled: adaptiveScaleEnabled
        )
        let message = try ControlMessage(type: .streamScaleChange, content: request)

        let roundedScale = (clampedScale * 100).rounded() / 100
        MirageLogger.client("Sending stream scale change for stream \(streamID): \(roundedScale)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

// MARK: - Supporting Types

public struct ClientStreamSession: Identifiable, Sendable {
    public let id: StreamID
    public let window: MirageWindow
    public let quality: MirageQualityPreset

    public init(id: StreamID, window: MirageWindow, quality: MirageQualityPreset) {
        self.id = id
        self.window = window
        self.quality = quality
    }
}
