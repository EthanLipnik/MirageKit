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
import MirageKit

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
    public internal(set) var sessionState: LoomSessionAvailability = .ready

    /// Whether remote unlock is enabled (allows clients to unlock the Mac)
    public var remoteUnlockEnabled: Bool = true

    /// Whether app-stream window close on the client should attempt to close the host window.
    public var closeHostWindowOnClientWindowClose: Bool = false

    /// Preferred low-power policy for host encoder sessions.
    public var encoderLowPowerModePreference: MirageCodecLowPowerModePreference = .auto {
        didSet {
            guard oldValue != encoderLowPowerModePreference else { return }
            scheduleEncoderLowPowerPolicyApply(reason: "preference_change")
        }
    }

    /// Whether battery-based low-power policy is currently supported on this host device.
    public internal(set) var encoderLowPowerSupportsBatteryPolicy: Bool = false

    /// Whether the host encoder is currently using low-power mode.
    public internal(set) var isEncoderLowPowerModeActive: Bool = false

    /// Callback fired when host battery-policy support changes.
    public var onEncoderLowPowerBatteryPolicySupportChanged: ((Bool) -> Void)?

    /// Host delegate for events
    public weak var delegate: MirageHostDelegate?

    /// Trust provider for custom connection approval logic.
    /// When set, the provider is consulted before the delegate for connection approval.
    /// If the provider returns `.trusted`, the connection is auto-approved.
    /// If the provider returns `.requiresApproval` or `.unavailable`, the delegate is consulted.
    /// If the provider returns `.denied`, the connection is rejected immediately.
    public weak var trustProvider: (any LoomTrustProvider)? {
        didSet {
            loomNode.trustProvider = trustProvider
        }
    }

    /// Software update controller used for client-initiated host update status and install requests.
    public weak var softwareUpdateController: (any MirageHostSoftwareUpdateController)?

    /// Identity manager for signed handshake envelopes.
    public var identityManager: LoomIdentityManager? = LoomIdentityManager.shared {
        didSet {
            loomNode.identityManager = identityManager
            let keyID = Self.identityKeyID(for: identityManager)
            updateAdvertisedIdentityKeyID(keyID)
        }
    }

    /// Accessibility permission manager for input injection.
    public let permissionManager = MirageAccessibilityPermissionManager()

    /// Window controller for host window management.
    public let windowController = MirageHostWindowController()

    /// Input controller for injecting remote input.
    public nonisolated let inputController = MirageHostInputController()

    /// Whether direct remote QUIC control transport is enabled.
    public var remoteTransportEnabled: Bool = false {
        didSet {
            Task { @MainActor [weak self] in
                await self?.updateRemoteControlListenerState()
            }
        }
    }

    /// Bound local port for the remote QUIC control listener.
    public internal(set) var remoteControlPort: UInt16?

    /// Called when host should resize a window before streaming begins.
    /// The callback receives the window and the target size in points.
    /// This allows the app to resize and center the window via Accessibility API.
    public var onResizeWindowForStream: ((MirageWindow, CGSize) -> Void)?

    public let loomNode: LoomNode
    var advertisedPeerAdvertisement: LoomPeerAdvertisement
    var udpListener: NWListener?
    var remoteControlListener: NWListener?
    let encoderConfig: MirageEncoderConfiguration
    let networkConfig: LoomNetworkConfiguration
    let serviceName: String
    var hostID: UUID = .init()
    let handshakeReplayProtector = LoomReplayProtector()
    // Internal for low-power policy extension.
    let encoderPowerStateMonitor = MiragePowerStateMonitor()
    var encoderPowerStateSnapshot = MiragePowerStateSnapshot(
        isSystemLowPowerModeEnabled: false,
        isOnBattery: nil
    )

    /// Current peer advertisement payload published through Loom discovery.
    public var currentPeerAdvertisement: LoomPeerAdvertisement {
        advertisedPeerAdvertisement
    }

    // Stream management (internal for extension access)
    var nextStreamID: StreamID = 1
    var streamsByID: [StreamID: StreamContext] = [:]
    // O(1) lookup maps for active app/window stream routing.
    var activeSessionByStreamID: [StreamID: MirageStreamSession] = [:]
    var activeStreamIDByWindowID: [WindowID: StreamID] = [:]
    var activeWindowIDByStreamID: [StreamID: WindowID] = [:]
    var clientsByConnection: [ObjectIdentifier: ClientContext] = [:]
    var clientsByID: [UUID: ClientContext] = [:]
    var disconnectingClientIDs: Set<UUID> = []
    var peerIdentityByClientID: [UUID: LoomPeerIdentity] = [:]
    var singleClientConnectionID: ObjectIdentifier?
    nonisolated let transportRegistry = HostTransportRegistry()
    nonisolated let streamRegistry = HostStreamRegistry()
    nonisolated let receiveLoopsByConnectionID = Locked<[ObjectIdentifier: HostReceiveLoop]>([:])
    nonisolated let controlWorkersByClientID = Locked<[UUID: SerialWorker]>([:])
    nonisolated let transportWorker = SerialWorker(
        label: "com.mirage.host.transport",
        qos: .userInteractive
    )

    // UDP connections by stream ID (received from client registrations)
    var udpConnectionsByStream: [StreamID: NWConnection] = [:]
    // Per-client media registration authentication context.
    var mediaSecurityByClientID: [UUID: MirageMediaSecurityContext] = [:]
    // Per-client media payload encryption policy.
    var mediaEncryptionEnabledByClientID: [UUID: Bool] = [:]
    // Audio UDP connections by client ID (single mixed audio stream per client).
    var audioConnectionsByClientID: [UUID: NWConnection] = [:]
    // Active host audio pipelines by client ID.
    var audioPipelinesByClientID: [UUID: HostAudioPipeline] = [:]
    // Selected source stream for client audio capture.
    var audioSourceStreamByClientID: [UUID: StreamID] = [:]
    // Latest requested audio configuration by client.
    var audioConfigurationByClientID: [UUID: MirageAudioConfiguration] = [:]
    // Last audio streamStarted payload sent to each client.
    var audioStartedMessageByClientID: [UUID: AudioStreamStartedMessage] = [:]
    var minimumSizesByWindowID: [WindowID: CGSize] = [:]
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]
    var streamStartupRegistrationLogged: Set<StreamID> = []
    let awdlExperimentEnabled: Bool = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    nonisolated static let lightsOutDisableEnvironmentKey = "MIRAGE_DISABLE_LIGHTS_OUT"
    let lightsOutDisabledByEnvironment: Bool = MirageHostService.isLightsOutDisabledByEnvironment()
    var mediaPathSnapshotByStreamID: [StreamID: MirageNetworkPathSnapshot] = [:]
    var sendErrorBursts: UInt64 = 0
    var transportRefreshRequests: UInt64 = 0

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

    struct WindowVirtualDisplayState: Sendable {
        let streamID: StreamID
        let displayID: CGDirectDisplayID
        let generation: UInt64
        let bounds: CGRect
        let targetContentAspectRatio: CGFloat?
        let captureSourceRect: CGRect
        let visiblePixelResolution: CGSize
        let scaleFactor: CGFloat
        let pixelResolution: CGSize
        let clientScaleFactor: CGFloat
    }

    struct WindowVisibleFrameDriftState: Sendable {
        let candidateBounds: CGRect
        let candidateVisiblePixelResolution: CGSize
        let consecutiveSamples: Int
    }

    struct WindowPlacementRepairBackoffState: Sendable {
        let failureCount: Int
        let nextRetryAt: CFAbsoluteTime
    }

    // Per-window dedicated virtual display state for app/window streams.
    var windowVirtualDisplayStateByWindowID: [WindowID: WindowVirtualDisplayState] = [:]
    // Per-stream queued resize targets for dedicated app/window displays.
    var pendingWindowResizeResolutionByStreamID: [StreamID: CGSize] = [:]
    // Streams currently applying a dedicated app/window resize transaction.
    var windowResizeInFlightStreamIDs: Set<StreamID> = []
    // Monotonic request counters for dedicated app/window resize transactions.
    var windowResizeRequestCounterByStreamID: [StreamID: UInt64] = [:]
    // Debounced visible-frame drift monitor tasks by stream.
    var windowVisibleFrameMonitorTasks: [StreamID: Task<Void, Never>] = [:]
    // Per-stream drift-stability state for visible-frame monitor hysteresis.
    var windowVisibleFrameDriftStateByStreamID: [StreamID: WindowVisibleFrameDriftState] = [:]
    // Cooldown tracking for authoritative placement repairs (window -> last repair time).
    var lastWindowPlacementRepairAtByWindowID: [WindowID: CFAbsoluteTime] = [:]
    // Backoff tracking for non-forced maintenance placement repairs.
    var windowPlacementRepairBackoffByWindowID: [WindowID: WindowPlacementRepairBackoffState] = [:]
    // Shared-display generation for desktop/login shared-consumer flows.
    var sharedVirtualDisplayGeneration: UInt64 = 0
    // Shared-display scale factor for desktop/login shared-consumer flows.
    var sharedVirtualDisplayScaleFactor: CGFloat = 2.0

    // Login display stream (lock/login screen) - internal for extension access
    var loginDisplayContext: StreamContext?
    var loginDisplayStreamID: StreamID?
    var loginDisplayResolution: CGSize?
    nonisolated let loginDisplayInputState = LoginDisplayInputState()
    var loginDisplayStartInProgress = false
    var loginDisplayStartGeneration: UInt64 = 0
    var loginDisplayIsBorrowedStream = false
    var loginDisplayPowerAssertionEnabled = false
    var loginDisplaySharedDisplayConsumerActive = false
    var loginDisplayRetryAttempts: Int = 0
    let loginDisplayRetryLimit: Int = 5
    let loginDisplayRetryDelaySeconds: TimeInterval = 2.0
    var loginDisplayRetryTimer: DispatchSourceTimer?
    var loginDisplayWatchdogTimer: DispatchSourceTimer?
    var loginDisplayWatchdogGeneration: UInt64 = 0
    var loginDisplayWatchdogStartTime: CFAbsoluteTime = 0
    var lastLoginDisplayRestartTime: CFAbsoluteTime = 0
    let loginDisplayWatchdogIntervalSeconds: TimeInterval = 2.0
    let loginDisplayWatchdogStartGraceSeconds: CFAbsoluteTime = 4.0
    let loginDisplayWatchdogStaleThresholdSeconds: CFAbsoluteTime = 6.0
    let loginDisplayRestartCooldownSeconds: CFAbsoluteTime = 8.0

    // Desktop stream (full virtual display mirroring) - internal for extension access
    var desktopStreamContext: StreamContext?
    var desktopStreamID: StreamID?
    var desktopStreamClientContext: ClientContext?
    var desktopDisplayBounds: CGRect?
    var desktopVirtualDisplayID: CGDirectDisplayID?
    var desktopRequestedScaleFactor: CGFloat?
    var desktopStreamMode: MirageDesktopStreamMode = .mirrored
    var pendingDesktopResizeResolution: CGSize?
    var desktopResizeInFlight: Bool = false
    var desktopResizeRequestCounter: UInt64 = 0

    /// Physical displays that were mirrored during desktop streaming (for restoration)
    var mirroredPhysicalDisplayIDs: Set<CGDirectDisplayID> = []
    /// Snapshot of display mirroring state before desktop streaming.
    var desktopMirroringSnapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    /// Primary physical display information captured before mirroring.
    var desktopPrimaryPhysicalDisplayID: CGDirectDisplayID?
    var desktopPrimaryPhysicalBounds: CGRect?

    /// Cursor monitoring - internal for extension access
    var cursorMonitor: CursorMonitor?
    var cursorUpdateMessagesSinceLastSample: UInt64 = 0
    var cursorPositionMessagesSinceLastSample: UInt64 = 0
    var droppedCursorUpdateMessagesSinceLastSample: UInt64 = 0
    var droppedCursorPositionMessagesSinceLastSample: UInt64 = 0
    var lastCursorControlSampleTime: CFAbsoluteTime = 0
    let cursorControlSampleInterval: CFAbsoluteTime = 1.0

    // Session state monitoring (for headless Mac unlock support) - internal for extension access
    var sessionStateMonitor: SessionStateMonitor?
    var unlockManager: UnlockManager?
    var currentSessionToken: String = ""
    var sessionRefreshTask: Task<Void, Never>?
    var sessionRefreshGeneration: UInt64 = 0
    let sessionRefreshInterval: Duration = .seconds(3)

    /// App-stream runtime orchestrator (host-authoritative stream tiering + budgets).
    let appStreamRuntimeOrchestrator = AppStreamRuntimeOrchestrator()
    /// Unified stream policy applier with idempotent/cooldown reconfiguration.
    let streamPolicyApplier = StreamPolicyApplier()
    /// App-stream fixed two-display allocator metadata.
    let appStreamDisplayAllocator = AppStreamDisplayAllocator()

    /// App-centric streaming manager - internal for extension access
    let appStreamManager = AppStreamManager()

    struct PendingAppWindowReplacement: Sendable {
        let streamID: StreamID
        let bundleIdentifier: String
        let clientID: UUID
        let closedWindowID: WindowID
        let slotStreamID: StreamID
        let deadline: Date
    }

    struct PendingAppWindowCloseAlertAction: Sendable {
        let id: String
        let title: String
        let isDestructive: Bool
        let index: Int
    }

    struct PendingAppWindowCloseAlertToken: Sendable {
        let token: String
        let clientID: UUID
        let bundleIdentifier: String
        let sourceWindowID: WindowID
        let sourceApp: MirageApplication?
        let presentingStreamID: StreamID
        let actions: [PendingAppWindowCloseAlertAction]
    }

    /// Pending 5s replacement cooldown entries keyed by stream ID.
    var pendingAppWindowReplacementsByStreamID: [StreamID: PendingAppWindowReplacement] = [:]
    /// Cooldown expiry tasks keyed by stream ID.
    var pendingAppWindowReplacementTasksByStreamID: [StreamID: Task<Void, Never>] = [:]
    /// Pending actionable close-blocked host alerts keyed by token.
    var pendingAppWindowCloseAlertTokensByToken: [String: PendingAppWindowCloseAlertToken] = [:]
    /// Scheduled policy-transition tasks keyed by app session bundle identifier.
    var appStreamPolicyTransitionTasksByBundleID: [String: Task<Void, Never>] = [:]
    let appWindowReplacementCooldownDuration: Duration = .seconds(5)

    /// Pending app list request to resume once interactive stream workload is idle.
    var pendingAppListRequest: PendingAppListRequest?
    var appListRequestTask: Task<Void, Never>?
    var appListRequestToken: UUID = .init()
    var appListRequestDeferredForInteractiveWorkload: Bool = false
    let appIconSignatureStore = HostAppIconSignatureStore()

    /// Menu bar passthrough - internal for extension access
    let menuBarMonitor = MenuBarMonitor()

    /// Window activation (robust multi-method for headless Macs)
    @ObservationIgnored let windowActivator: WindowActivator = .forCurrentEnvironment()

    /// Lights Out (curtain) preference for desktop streams.
    /// App/window streams always force Lights Out while active.
    public var lightsOutEnabled: Bool = false {
        didSet {
            Task { @MainActor [weak self] in
                await self?.updateLightsOutState()
            }
        }
    }

    /// Whether to lock the host when all active streaming has stopped.
    public var lockHostWhenStreamingStops: Bool = false

    /// Optional override for host lock behavior (defaults to CGSession if nil).
    public var lockHostHandler: (@MainActor () -> Void)?

    /// Local shortcut used to recover from a stuck Lights Out session.
    public var lightsOutEmergencyShortcut: MirageHostShortcut = .defaultLightsOutRecovery {
        didSet {
            lightsOutController.emergencyShortcut = lightsOutEmergencyShortcut
        }
    }

    /// Called when the Lights Out emergency shortcut is detected.
    @ObservationIgnored public var onLightsOutEmergencyShortcut: (@MainActor () async -> Void)? {
        didSet {
            lightsOutController.onEmergencyShortcut = onLightsOutEmergencyShortcut
        }
    }

    /// Whether Lights Out is temporarily suspended for an active screenshot session.
    var lightsOutScreenshotSuspended: Bool = false
    /// Task that waits for the screenshot session to finish before restoring Lights Out.
    var lightsOutScreenshotSuspendTask: Task<Void, Never>?
    /// Number of app/window stream start requests currently in setup before stream activation.
    var pendingAppStreamStartCount: Int = 0
    /// Number of desktop stream start requests currently in setup before stream activation.
    var pendingDesktopStreamStartCount: Int = 0

    /// Whether host output stays muted while host audio streaming is active.
    public var muteLocalAudioWhileStreaming: Bool = false {
        didSet {
            updateHostAudioMuteState()
        }
    }

    @ObservationIgnored let lightsOutController = HostLightsOutController()
    @ObservationIgnored let hostAudioMuteController = HostAudioMuteController()
    @ObservationIgnored var stageManagerController = HostStageManagerController()
    var appStreamingStageManagerNeedsRestore: Bool = false
    var appStreamingStageManagerPreparationInProgress: Bool = false

    // MARK: - Fast Input Path (bypasses MainActor)

    /// High-priority queue for input processing - bypasses MainActor for lowest latency
    nonisolated let inputQueue = DispatchQueue(label: "com.mirage.host.input", qos: .userInteractive)

    /// Thread-safe cache of stream info for fast input routing
    /// Uses a dedicated actor to avoid lock issues in async contexts
    nonisolated let inputStreamCacheActor = InputStreamCacheActor()

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
    typealias ControlMessageHandler = @MainActor (ControlMessage, MirageConnectedClient, NWConnection) async -> Void
    var controlMessageHandlers: [ControlMessageType: ControlMessageHandler] = [:]
    nonisolated(unsafe) var diagnosticsContextProviderToken: LoomDiagnosticsContextProviderToken?

    public enum HostState: Equatable {
        case idle
        case starting
        case advertising(controlPort: UInt16, dataPort: UInt16)
        case error(String)
    }

    struct PendingAppListRequest: Equatable {
        let clientID: UUID
        var requestID: UUID
        var requestedForceRefresh: Bool
        var forceIconReset: Bool
        var priorityBundleIdentifiers: [String]
    }

    public init(
        hostName: String? = nil,
        deviceID: UUID? = nil,
        encoderConfiguration: MirageEncoderConfiguration = .highQuality,
        loomConfiguration: LoomNetworkConfiguration = .default
    ) {
        var resolvedConfiguration = loomConfiguration
        if resolvedConfiguration.serviceType == Loom.serviceType {
            resolvedConfiguration.serviceType = MirageKit.serviceType
        }

        let name = hostName ?? Host.current().localizedName ?? "Mac"
        let identityKeyID = Self.identityKeyID(for: LoomIdentityManager.shared)
        let hardwareModelIdentifier = Self.hardwareModelIdentifier()
        let hardwareColorCode = Self.hardwareColorCode()
        let hardwareIconName = Self.hardwareIconName(
            for: hardwareModelIdentifier,
            hardwareColorCode: hardwareColorCode
        )
        let hardwareMachineFamily = Self.hardwareMachineFamily(
            modelIdentifier: hardwareModelIdentifier,
            iconName: hardwareIconName
        )
        let peerAdvertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            modelIdentifier: hardwareModelIdentifier,
            iconName: hardwareIconName,
            machineFamily: hardwareMachineFamily
        )
        MirageLogger.host(
            "Hardware metadata model=\(hardwareModelIdentifier ?? "nil") icon=\(hardwareIconName ?? "nil") family=\(hardwareMachineFamily ?? "nil") color=\(hardwareColorCode?.description ?? "nil")"
        )
        advertisedPeerAdvertisement = peerAdvertisement
        hostID = peerAdvertisement.deviceID ?? UUID()
        serviceName = name
        loomNode = LoomNode(
            configuration: resolvedConfiguration,
            identityManager: LoomIdentityManager.shared
        )
        encoderConfig = encoderConfiguration
        networkConfig = resolvedConfiguration

        windowController.hostService = self
        inputController.hostService = self
        inputController.windowController = windowController
        inputController.permissionManager = permissionManager

        onResizeWindowForStream = { [weak windowController] window, size in
            windowController?.resizeAndCenterWindowForStream(window, targetSize: size)
        }

        lightsOutController.onOverlayWindowsChanged = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshLightsOutCaptureExclusions()
            }
        }
        lightsOutController.emergencyShortcut = lightsOutEmergencyShortcut
        lightsOutController.onEmergencyShortcut = onLightsOutEmergencyShortcut
        lightsOutController.onScreenshotShortcut = { [weak self] in
            await self?.handleLightsOutScreenshotShortcut()
        }
        if lightsOutDisabledByEnvironment {
            MirageLogger.host("Lights Out disabled by environment (\(Self.lightsOutDisableEnvironmentKey)=1)")
        }

        registerControlMessageHandlers()
        registerDiagnosticsContextProvider()
        configureEncoderLowPowerMonitoring()
    }

    deinit {
        let powerStateMonitor = encoderPowerStateMonitor
        Task { @MainActor in
            powerStateMonitor.stop()
        }
        guard let diagnosticsContextProviderToken else { return }
        Task {
            await LoomDiagnostics.unregisterContextProvider(diagnosticsContextProviderToken)
        }
    }

    private func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.makeDiagnosticsContextSnapshot() }
            }
        }
    }

    private func makeDiagnosticsContextSnapshot() -> LoomDiagnosticsContext {
        [
            "host.state": .string(Self.diagnosticsHostStateName(state)),
            "host.sessionState": .string(String(describing: sessionState)),
            "host.remoteUnlockEnabled": .bool(remoteUnlockEnabled),
            "host.remoteTransportEnabled": .bool(remoteTransportEnabled),
            "host.lightsOutEnabled": .bool(lightsOutEnabled),
            "host.lightsOutDisabledByEnvironment": .bool(lightsOutDisabledByEnvironment),
            "host.lockHostWhenStreamingStops": .bool(lockHostWhenStreamingStops),
            "host.connectedClientsCount": .int(connectedClients.count),
            "host.activeStreamsCount": .int(activeStreams.count),
            "host.availableWindowsCount": .int(availableWindows.count),
            "host.desktopStreamActive": .bool(desktopStreamID != nil),
            "host.loginDisplayStreamActive": .bool(loginDisplayStreamID != nil),
            "host.desktopResizeInFlight": .bool(desktopResizeInFlight),
            "host.windowVirtualDisplayCount": .int(windowVirtualDisplayStateByWindowID.count)
        ]
    }

    private static func diagnosticsHostStateName(_ state: HostState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .advertising:
            return "advertising"
        case .error:
            return "error"
        }
    }

    nonisolated static func isLightsOutDisabledByEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[lightsOutDisableEnvironmentKey] == "1"
    }

    private static func identityKeyID(for manager: LoomIdentityManager?) -> String? {
        guard let manager else { return nil }
        return try? manager.currentIdentity().keyID
    }

    /// Updates the identity key advertised in the Loom discovery payload.
    public func updateAdvertisedIdentityKeyID(_ keyID: String?) {
        advertisedPeerAdvertisement = LoomPeerAdvertisement(
            protocolVersion: advertisedPeerAdvertisement.protocolVersion,
            deviceID: advertisedPeerAdvertisement.deviceID,
            identityKeyID: keyID,
            deviceType: advertisedPeerAdvertisement.deviceType,
            modelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
            iconName: advertisedPeerAdvertisement.iconName,
            machineFamily: advertisedPeerAdvertisement.machineFamily,
            metadata: advertisedPeerAdvertisement.metadata
        )
        Task { await loomNode.updateAdvertisement(advertisedPeerAdvertisement) }
    }

    private static func hardwareModelIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct CoreTypesHostIconEntry {
        let lowercasedName: String
        let originalName: String
        let size: Int
    }

    private static func hardwareIconName(
        for modelIdentifier: String?,
        hardwareColorCode: Int?
    ) -> String? {
        guard let normalizedModel = normalizeModelIdentifier(modelIdentifier) else {
            return nil
        }
        guard let coreTypesPath = coreTypesBundlePath() else {
            return nil
        }

        var iconEntries: [CoreTypesHostIconEntry] = []
        var plistPaths: [String] = []
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(atPath: coreTypesPath) {
            for case let relativePath as String in enumerator {
                let lowercasedPath = relativePath.lowercased()

                if lowercasedPath.hasSuffix(".icns") {
                    let fullPath = coreTypesPath + "/" + relativePath
                    let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
                    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    let originalName = (relativePath as NSString).lastPathComponent
                    iconEntries.append(
                        CoreTypesHostIconEntry(
                            lowercasedName: originalName.lowercased(),
                            originalName: originalName,
                            size: size
                        )
                    )
                    continue
                }

                if lowercasedPath.hasSuffix("/info.plist") {
                    plistPaths.append(coreTypesPath + "/" + relativePath)
                }
            }
        }

        guard !iconEntries.isEmpty else {
            return nil
        }

        let metadata = parseCoreTypesMetadata(plistPaths: plistPaths)
        let preferredModelTag = hardwareColorCode.map { "\(normalizedModel)@ecolor=\($0)" }
        let preferredTypes = preferredModelTag.flatMap { metadata.modelTagToTypeIdentifiers[$0] } ?? []
        let mappedTypes = metadata.modelToTypeIdentifiers[normalizedModel] ?? []
        let preferredColorHints = preferredColorHints(from: preferredTypes)
        let expandedPreferredTypes = preferredTypes.isEmpty
            ? Set<String>()
            : expandTypeIdentifiers(preferredTypes, conformance: metadata.typeConformanceGraph)
        let expandedMappedTypes = mappedTypes.isEmpty
            ? Set<String>()
            : expandTypeIdentifiers(mappedTypes, conformance: metadata.typeConformanceGraph)
        let machineFamilyHint = hardwareMachineFamily(modelIdentifier: normalizedModel, iconName: nil)

        if preferredTypes.isEmpty, let preferredModelTag {
            MirageLogger.host(
                "Host icon color-specific model tag unavailable: \(preferredModelTag), falling back to family/model matching"
            )
        }

        var best: (name: String, score: Int, size: Int)?

        for icon in iconEntries {
            let lowercasedName = icon.lowercasedName
            var score = 0

            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: preferredTypes,
                    exactWeight: 22_000,
                    prefixWeight: 20_500,
                    containsWeight: 18_000
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: mappedTypes,
                    exactWeight: 15_000,
                    prefixWeight: 13_500,
                    containsWeight: 11_500
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: expandedPreferredTypes,
                    exactWeight: 9_000,
                    prefixWeight: 7_800,
                    containsWeight: 6_600
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: expandedMappedTypes,
                    exactWeight: 5_200,
                    prefixWeight: 4_300,
                    containsWeight: 3_500
                )
            )

            guard score > 0 else {
                continue
            }

            score += min(icon.size / 4_096, 900)
            if isMacHardwareIconName(icon.lowercasedName) {
                score += 500
            }
            if let machineFamilyHint,
               matchesMachineFamilyHint(machineFamilyHint, iconName: lowercasedName) {
                score += 1_600
            }
            if matchesColorHint(iconName: lowercasedName, colorHints: preferredColorHints) {
                score += 2_100
            }

            if let currentBest = best {
                if score > currentBest.score || (score == currentBest.score && icon.size > currentBest.size) {
                    best = (name: icon.originalName, score: score, size: icon.size)
                }
            } else {
                best = (name: icon.originalName, score: score, size: icon.size)
            }
        }

        if let resolved = best?.name {
            return resolved
        }

        if let familyFallback = bestFamilyFallbackIconName(
            machineFamily: machineFamilyHint,
            iconEntries: iconEntries,
            preferredColorHints: preferredColorHints
        ) {
            return familyFallback
        }

        return iconEntries
            .filter { isMacHardwareIconName($0.lowercasedName) }
            .max(by: { lhs, rhs in lhs.size < rhs.size })?
            .originalName
    }

    private static func hardwareMachineFamily(modelIdentifier: String?, iconName: String?) -> String? {
        if let iconName {
            let normalizedIconName = iconName.lowercased()
            if normalizedIconName.contains("macbook") || normalizedIconName.contains("sidebarlaptop") {
                return "macBook"
            }
            if normalizedIconName.contains("imac") || normalizedIconName.contains("sidebarimac") {
                return "iMac"
            }
            if normalizedIconName.contains("macmini") || normalizedIconName.contains("sidebarmacmini") {
                return "macMini"
            }
            if normalizedIconName.contains("macstudio") {
                return "macStudio"
            }
            if normalizedIconName.contains("macpro") || normalizedIconName.contains("sidebarmacpro") {
                return "macPro"
            }
        }

        if let modelIdentifier {
            let normalizedModel = modelIdentifier.lowercased()
            if normalizedModel.contains("macbook") {
                return "macBook"
            }
            if normalizedModel.contains("imac") {
                return "iMac"
            }
            if normalizedModel.contains("macmini") {
                return "macMini"
            }
            if normalizedModel.contains("macstudio") {
                return "macStudio"
            }
            if normalizedModel.contains("macpro") {
                return "macPro"
            }
        }

        guard let machineName = hardwareMachineName()?.lowercased() else {
            return "macGeneric"
        }
        if machineName.contains("macbook") {
            return "macBook"
        }
        if machineName.contains("imac") {
            return "iMac"
        }
        if machineName.contains("mini") {
            return "macMini"
        }
        if machineName.contains("studio") {
            return "macStudio"
        }
        if machineName.contains("pro") {
            return "macPro"
        }
        return "macGeneric"
    }

    private static func hardwareMachineName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting for exit so verbose subprocess output
        // cannot fill the pipe buffer and block startup.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: outputData),
            let dictionary = jsonObject as? [String: Any],
            let hardwareEntries = dictionary["SPHardwareDataType"] as? [[String: Any]],
            let firstEntry = hardwareEntries.first,
            let machineName = firstEntry["machine_name"] as? String
        else {
            return nil
        }

        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func coreTypesBundlePath() -> String? {
        if let bundlePath = Bundle(identifier: "com.apple.CoreTypes")?.bundlePath,
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        let fallbacks = [
            "/System/Library/CoreServices/CoreTypes.bundle",
            "/System/Library/Templates/Data/System/Library/CoreServices/CoreTypes.bundle",
        ]
        return fallbacks.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func normalizeModelIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let markerIndex = normalized.firstIndex(of: "@") {
            return String(normalized[..<markerIndex])
        }
        return normalized
    }

    private static func normalizeModelTagIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        var normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let nulIndex = normalized.firstIndex(of: "\u{0}") {
            normalized = String(normalized[..<nulIndex])
        }
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func parseStringCollection(_ value: Any?) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let strings = value as? [String] {
            return strings
        }
        return []
    }

    private static func parseCoreTypesMetadata(plistPaths: [String]) -> (
        modelTagToTypeIdentifiers: [String: Set<String>],
        modelToTypeIdentifiers: [String: Set<String>],
        typeConformanceGraph: [String: Set<String>]
    ) {
        var modelTagToTypeIdentifiers: [String: Set<String>] = [:]
        var modelToTypeIdentifiers: [String: Set<String>] = [:]
        var typeConformanceGraph: [String: Set<String>] = [:]

        for plistPath in plistPaths {
            guard
                let data = FileManager.default.contents(atPath: plistPath),
                let plistObject = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let plist = plistObject as? [String: Any],
                let declarations = plist["UTExportedTypeDeclarations"] as? [[String: Any]]
            else {
                continue
            }

            for declaration in declarations {
                guard let typeIdentifier = (declaration["UTTypeIdentifier"] as? String)?
                    .lowercased(), !typeIdentifier.isEmpty else {
                    continue
                }

                let conformsTo = parseStringCollection(declaration["UTTypeConformsTo"])
                    .map { $0.lowercased() }
                if !conformsTo.isEmpty {
                    typeConformanceGraph[typeIdentifier, default: []].formUnion(conformsTo)
                }

                guard let tagSpecification = declaration["UTTypeTagSpecification"] as? [String: Any] else {
                    continue
                }

                let rawModelCodes = parseStringCollection(tagSpecification["com.apple.device-model-code"])
                    .map { normalizeModelTagIdentifier($0) }
                    .compactMap { $0 }
                guard !rawModelCodes.isEmpty else {
                    continue
                }

                let relatedTypes = Set([typeIdentifier] + conformsTo)
                for rawModelCode in rawModelCodes {
                    modelTagToTypeIdentifiers[rawModelCode, default: []].formUnion(relatedTypes)
                    if let baseModelCode = normalizeModelIdentifier(rawModelCode) {
                        modelToTypeIdentifiers[baseModelCode, default: []].formUnion(relatedTypes)
                    }
                }
            }
        }

        return (modelTagToTypeIdentifiers, modelToTypeIdentifiers, typeConformanceGraph)
    }

    private static func expandTypeIdentifiers(
        _ initial: Set<String>,
        conformance: [String: Set<String>]
    ) -> Set<String> {
        var visited = initial
        var queue = Array(initial)

        while let next = queue.popLast() {
            for parent in conformance[next, default: []] where !visited.contains(parent) {
                visited.insert(parent)
                queue.append(parent)
            }
        }

        return visited
    }

    private static func isMacHardwareIconName(_ lowercasedName: String) -> Bool {
        lowercasedName.contains("macbook") ||
            lowercasedName.contains("imac") ||
            lowercasedName.contains("macmini") ||
            lowercasedName.contains("macstudio") ||
            lowercasedName.contains("macpro") ||
            lowercasedName.contains("sidebarlaptop") ||
            lowercasedName.contains("sidebarmac")
    }

    private static func scoreForTypeMatch(
        iconName: String,
        typeIdentifiers: Set<String>,
        exactWeight: Int,
        prefixWeight: Int,
        containsWeight: Int
    ) -> Int {
        guard !typeIdentifiers.isEmpty else {
            return 0
        }

        var bestScore = 0
        for typeIdentifier in typeIdentifiers {
            if iconName == "\(typeIdentifier).icns" {
                bestScore = max(bestScore, exactWeight)
            } else if iconName.hasPrefix(typeIdentifier + "-") {
                bestScore = max(bestScore, prefixWeight)
            } else if iconName.contains(typeIdentifier) {
                bestScore = max(bestScore, containsWeight)
            }
        }

        return bestScore
    }

    private static func matchesMachineFamilyHint(_ family: String, iconName: String) -> Bool {
        switch family.lowercased() {
        case "macbook":
            return iconName.contains("macbook") || iconName.contains("sidebarlaptop")
        case "imac":
            return iconName.contains("imac") || iconName.contains("sidebarimac")
        case "macmini":
            return iconName.contains("macmini") || iconName.contains("sidebarmacmini")
        case "macstudio":
            return iconName.contains("macstudio")
        case "macpro":
            return iconName.contains("macpro") || iconName.contains("sidebarmacpro")
        default:
            return isMacHardwareIconName(iconName)
        }
    }

    private static func bestFamilyFallbackIconName(
        machineFamily: String?,
        iconEntries: [CoreTypesHostIconEntry],
        preferredColorHints: Set<String>
    ) -> String? {
        guard !iconEntries.isEmpty else {
            return nil
        }

        let matching = iconEntries.filter { entry in
            guard isMacHardwareIconName(entry.lowercasedName) else {
                return false
            }
            guard let machineFamily else {
                return true
            }
            return matchesMachineFamilyHint(machineFamily, iconName: entry.lowercasedName)
        }

        let bestMatching = matching.max { lhs, rhs in
            let lhsColor = matchesColorHint(iconName: lhs.lowercasedName, colorHints: preferredColorHints) ? 8_000 : 0
            let rhsColor = matchesColorHint(iconName: rhs.lowercasedName, colorHints: preferredColorHints) ? 8_000 : 0
            let lhsScore = lhsColor + lhs.size / 8_192
            let rhsScore = rhsColor + rhs.size / 8_192
            if lhsScore == rhsScore {
                return lhs.size < rhs.size
            }
            return lhsScore < rhsScore
        }

        if let bestMatching {
            return bestMatching.originalName
        }

        return iconEntries
            .filter { isMacHardwareIconName($0.lowercasedName) }
            .max(by: { lhs, rhs in lhs.size < rhs.size })?
            .originalName
    }

    private static func preferredColorHints(from typeIdentifiers: Set<String>) -> Set<String> {
        guard !typeIdentifiers.isEmpty else {
            return []
        }

        let knownColorHints = [
            "space-black",
            "space-gray",
            "silver",
            "midnight",
            "starlight",
            "stardust",
            "sky-blue",
            "gold",
            "rose-gold",
            "blue",
        ]

        var hints: Set<String> = []
        for typeIdentifier in typeIdentifiers {
            for colorHint in knownColorHints where typeIdentifier.contains(colorHint) {
                hints.insert(colorHint)
            }
        }
        return hints
    }

    private static func matchesColorHint(iconName: String, colorHints: Set<String>) -> Bool {
        guard !colorHints.isEmpty else {
            return false
        }

        return colorHints.contains { iconName.contains($0) }
    }

    private static func hardwareColorCode() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-lw0", "-p", "IODeviceTree", "-n", "chosen", "-r"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting for exit so the child cannot block when
        // writing large IORegistry payloads.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return nil
        }

        return parseHousingColorCode(from: output)
    }

    private static func parseHousingColorCode(from output: String) -> Int? {
        let pattern = #""housing-color"\s*=\s*<([0-9A-Fa-f]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsOutput = output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        guard let match = regex.firstMatch(in: output, range: range), match.numberOfRanges > 1 else {
            return nil
        }

        let hexRange = match.range(at: 1)
        guard hexRange.location != NSNotFound else {
            return nil
        }

        let hexString = nsOutput.substring(with: hexRange)
        let bytes = hexBytes(from: hexString)
        guard !bytes.isEmpty else {
            return nil
        }

        var values: [UInt32] = []
        let stride = 4
        let usableLength = bytes.count - (bytes.count % stride)
        guard usableLength >= stride else {
            return nil
        }

        var index = 0
        while index + 3 < usableLength {
            let value = UInt32(bytes[index]) |
                (UInt32(bytes[index + 1]) << 8) |
                (UInt32(bytes[index + 2]) << 16) |
                (UInt32(bytes[index + 3]) << 24)
            values.append(value)
            index += stride
        }

        guard let resolved = values.last(where: { $0 != 0 }) else {
            return nil
        }
        return Int(resolved)
    }

    private static func hexBytes(from value: String) -> [UInt8] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count.isMultiple(of: 2) else {
            return []
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)

        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let nextIndex = trimmed.index(index, offsetBy: 2)
            let pair = trimmed[index..<nextIndex]
            guard let byte = UInt8(pair, radix: 16) else {
                return []
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
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

        guard let virtualResolution,
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

    func setRemoteControlPort(_ port: UInt16?) {
        remoteControlPort = port
    }

    /// Resolve the current virtual display bounds for secondary desktop streaming.
    /// Uses CoreGraphics coordinates for input injection.
    func resolveDesktopDisplayBounds() -> CGRect? {
        if let cached = desktopDisplayBounds, cached.width > 0, cached.height > 0 {
            return cached
        }

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
    ///   - bitDepth: Optional client-requested stream bit depth
    ///   - captureQueueDepth: Optional ScreenCaptureKit queue depth override
    ///   - bitrate: Optional target bitrate (bits per second)
    ///   - targetFrameRate: Optional frame rate override (60/120 based on client capability)

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
