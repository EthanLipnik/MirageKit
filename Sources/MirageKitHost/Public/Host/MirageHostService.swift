//
//  MirageHostService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import Foundation
import Loom
import MirageBootstrapShared
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

    /// Whether shared clipboard sync is enabled for eligible active sessions.
    public var sharedClipboardEnabled: Bool = false {
        didSet {
            guard oldValue != sharedClipboardEnabled else { return }
            syncSharedClipboardState(reason: "setting_changed", forceStatusBroadcast: true)
        }
    }

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

    /// Effective cursor presentation for the active desktop stream.
    public internal(set) var desktopCursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor

    /// Latest client-owned stream-option state mirrored back to the host UI.
    public internal(set) var remoteClientStreamStatusOverlayEnabled = false

    /// Latest client-owned stream-options display mode mirrored back to the host UI.
    public internal(set) var remoteClientStreamOptionsDisplayMode: MirageStreamOptionsDisplayMode = .inStream

    /// Whether the connected client currently exposes desktop cursor lock controls.
    public internal(set) var remoteClientDesktopCursorLockAvailable = false

    /// Latest client-owned desktop cursor lock mode mirrored back to the host UI.
    public internal(set) var remoteClientDesktopCursorLockMode: MirageDesktopCursorLockMode = .off

    /// Callback fired when host battery-policy support changes.
    public var onEncoderLowPowerBatteryPolicySupportChanged: ((Bool) -> Void)?

    /// Host delegate for events
    public weak var delegate: MirageHostDelegate?

    /// Trust provider consulted during the authenticated Loom session handshake.
    ///
    /// The provider must resolve to a final trust decision before Mirage bootstrap continues.
    /// Product-specific approval UX should therefore live inside the provider or the higher-level
    /// owner that wraps it, not in the host delegate.
    public weak var trustProvider: (any LoomTrustProvider)? {
        didSet {
            loomNode.trustProvider = trustProvider
        }
    }

    /// Software update controller used for client-initiated host update status and install requests.
    public weak var softwareUpdateController: (any MirageHostSoftwareUpdateController)?

    /// Provider used for client-initiated host support log archive export.
    public var hostSupportLogArchiveProvider: (@MainActor @Sendable () async throws -> URL)?

    /// Provider for the most recent cached host capture benchmark capability.
    public var hostCaptureCapabilityProvider: (@MainActor @Sendable () -> MirageHostCaptureCapability?)?

    /// Authorizer used for client-initiated Mirage Host app relaunch requests.
    public var hostApplicationRestartAuthorizer: (@MainActor @Sendable (MirageConnectedClient) async -> Bool)?

    /// Handler used for client-initiated Mirage Host app relaunch requests.
    public var hostApplicationRestartHandler: (@MainActor @Sendable () -> Void)?

    /// Identity manager for signed handshake envelopes.
    public var identityManager: LoomIdentityManager? = MirageKit.identityManager {
        didSet {
            loomNode.identityManager = identityManager
            let keyID = Self.identityKeyID(for: identityManager)
            updateAdvertisedIdentityKeyID(keyID)
        }
    }

    /// Accessibility permission manager for input injection.
    public let permissionManager = MirageAccessibilityPermissionManager()

    /// Whether the most recent capture inventory attempt hit an explicit screen-recording denial.
    public internal(set) var lastScreenRecordingPermissionDenied = false

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

    /// Whether the remote QUIC control listener is currently ready to accept connections.
    public internal(set) var remoteControlListenerReady = false

    /// Whether the host can currently accept a new client session.
    public var allowsNewClientConnections: Bool {
        singleClientSessionID == nil
    }

    /// Callback fired when host connection availability changes.
    public var onConnectionAvailabilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    /// STUN keepalive that refreshes the NAT mapping for the QUIC listener port.
    var stunKeepalive: LoomSTUNKeepalive?

    /// NAT-PMP / PCP port mapping that provides a stable external port.
    var natPortMapping: LoomNATPortMapping?

    /// Called when host should resize a window before streaming begins.
    /// The callback receives the window and the target size in points.
    /// This allows the app to resize and center the window via Accessibility API.
    public var onResizeWindowForStream: ((MirageWindow, CGSize) -> Void)?

    public let loomNode: LoomNode
    var advertisedPeerAdvertisement: LoomPeerAdvertisement
    var advertisementRefreshTask: Task<Void, Never>?
    var remoteControlListener: NWListener?
    var remoteRelayPublicationState = MirageRemoteRelayPublicationState()
    let encoderConfig: MirageEncoderConfiguration
    let networkConfig: LoomNetworkConfiguration
    let serviceName: String
    var hostID: UUID = .init()
    public internal(set) var supportedColorDepths: [MirageStreamColorDepth] = [.standard, .pro]
    let handshakeReplayProtector = LoomReplayProtector()
    let localNetworkMonitor = MirageLocalNetworkMonitor(label: "host")
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
    var clientsBySessionID: [UUID: ClientContext] = [:]
    var clientsByID: [UUID: ClientContext] = [:]
    var disconnectingClientIDs: Set<UUID> = []
    var peerIdentityByClientID: [UUID: LoomPeerIdentity] = [:]
    var singleClientReservationStartedAt: CFAbsoluteTime?
    var singleClientSessionID: UUID? {
        didSet {
            guard oldValue != singleClientSessionID else { return }
            singleClientReservationStartedAt = if singleClientSessionID == nil {
                nil
            } else {
                CFAbsoluteTimeGetCurrent()
            }
            updateAdvertisedConnectionAvailability()
            onConnectionAvailabilityChanged?(allowsNewClientConnections)
        }
    }
    nonisolated let transportRegistry = HostTransportRegistry()
    nonisolated let streamRegistry = HostStreamRegistry()
    nonisolated let receiveLoopsBySessionID = Locked<[UUID: HostReceiveLoop]>([:])
    nonisolated let controlWorkersByClientID = Locked<[UUID: SerialWorker]>([:])
    nonisolated let transportWorker = SerialWorker(
        label: "com.mirage.host.transport",
        qos: .userInteractive
    )

    // Loom multiplexed video streams by stream ID.
    var loomVideoStreamsByStreamID: [StreamID: LoomMultiplexedStream] = [:]
    // Per-client media registration authentication context.
    var mediaSecurityByClientID: [UUID: MirageMediaSecurityContext] = [:]
    // Per-client media payload encryption policy.
    var mediaEncryptionEnabledByClientID: [UUID: Bool] = [:]
    // Loom multiplexed audio streams by client ID.
    var loomAudioStreamsByClientID: [UUID: LoomMultiplexedStream] = [:]
    // Active host audio pipelines by client ID.
    var audioPipelinesByClientID: [UUID: HostAudioPipeline] = [:]
    // Selected source stream for client audio capture.
    var audioSourceStreamByClientID: [UUID: StreamID] = [:]
    // Latest requested audio configuration by client.
    var audioConfigurationByClientID: [UUID: MirageAudioConfiguration] = [:]
    // Last audio streamStarted payload sent to each client.
    var audioStartedMessageByClientID: [UUID: AudioStreamStartedMessage] = [:]
    // Last audio streamStarted payload acknowledged onto the control channel.
    var sentAudioStartedMessageByClientID: [UUID: AudioStreamStartedMessage] = [:]
    var minimumSizesByWindowID: [WindowID: CGSize] = [:]
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]
    var streamStartupRegistrationLogged: Set<StreamID> = []
    var pendingStartupAttemptsByStreamID: [StreamID: PendingStartupAttempt] = [:]
    var startupAttemptTimeoutTasksByStreamID: [StreamID: Task<Void, Never>] = [:]
    let startupAttemptTimeoutSeconds: Duration = .seconds(5)
    let awdlExperimentEnabled: Bool = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    nonisolated static let lightsOutDisableEnvironmentKey = "MIRAGE_DISABLE_LIGHTS_OUT"
    let lightsOutDisabledByEnvironment: Bool = MirageHostService.isLightsOutDisabledByEnvironment()
    var mediaPathSnapshotByStreamID: [StreamID: MirageNetworkPathSnapshot] = [:]
    var sendErrorBursts: UInt64 = 0
    var transportRefreshRequests: UInt64 = 0
    var transportSendErrorReported: Set<StreamID> = []
    var controlChannelSendFailureReported: Set<UUID> = []

    // Quality test tasks
    var qualityTestTasksByClientID: [UUID: Task<Void, Never>] = [:]
    var qualityTestSessionTokensByClientID: [UUID: UUID] = [:]
    var qualityTestIDsByClientID: [UUID: UUID] = [:]
    var qualityTestStreamsByClientID: [UUID: LoomMultiplexedStream] = [:]

    let clientErrorTimeoutSeconds: CFAbsoluteTime = 2.0

    /// Approval timeout to avoid wedging the single-client slot.
    let connectionApprovalTimeoutSeconds: CFAbsoluteTime = 15.0

    // Host-side client liveness monitoring.
    nonisolated let clientLastActivityByID = Locked<[UUID: CFAbsoluteTime]>([:])
    var clientLivenessTask: Task<Void, Never>?

    struct WindowVirtualDisplayState: Sendable {
        let streamID: StreamID
        let displayID: CGDirectDisplayID
        let generation: UInt64
        let bounds: CGRect
        let displayVisibleBounds: CGRect
        let targetContentAspectRatio: CGFloat?
        let captureSourceRect: CGRect
        let visiblePixelResolution: CGSize
        let displayVisiblePixelResolution: CGSize
        let scaleFactor: CGFloat
        let pixelResolution: CGSize
        let clientScaleFactor: CGFloat
    }

    struct WindowVisibleFrameDriftState: Sendable {
        let candidateBounds: CGRect
        let candidateVisiblePixelResolution: CGSize
        let consecutiveSamples: Int
    }

    struct DesktopResizeRequestState: Sendable, Equatable {
        let logicalResolution: CGSize
        let transitionID: UUID?
        let requestedDisplayScaleFactor: CGFloat?
        let requestedStreamScale: CGFloat?
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?
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
    // Shared-display generation for desktop/login shared-consumer flows.
    var sharedVirtualDisplayGeneration: UInt64 = 0
    // Shared-display scale factor for desktop/login shared-consumer flows.
    var sharedVirtualDisplayScaleFactor: CGFloat = 2.0

    // Desktop stream (full virtual display mirroring) - internal for extension access
    var desktopStreamContext: StreamContext?
    var desktopStreamID: StreamID?
    var desktopSessionID: UUID?
    var desktopStreamClientContext: ClientContext?
    var desktopDisplayBounds: CGRect?
    var desktopVirtualDisplayID: CGDirectDisplayID?
    var desktopRequestedScaleFactor: CGFloat?
    var desktopUsesHostResolution: Bool = false
    var desktopStreamMode: MirageDesktopStreamMode = .unified
    var activeDesktopResizeRequest: DesktopResizeRequestState?
    var queuedDesktopResizeRequest: DesktopResizeRequestState?
    var desktopSharedDisplayTransitionDepth: Int = 0

    /// Set when the client cancels stream setup before a stream ID is established.
    /// Checked at suspension points in desktop and app stream setup flows.
    var streamSetupCancelled = false

    /// Displays mirrored during desktop streaming (for restoration).
    var mirroredDesktopDisplayIDs: Set<CGDirectDisplayID> = []
    /// Snapshot of display mirroring state before desktop streaming.
    var desktopMirroringSnapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    /// Last known current Space for each physical display before Mirage reconfigures mirroring.
    var desktopDisplaySpaceSnapshot: [CGDirectDisplayID: CGSSpaceID] = [:]
    /// Primary physical display information captured before mirroring.
    var desktopPrimaryPhysicalDisplayID: CGDirectDisplayID?
    var desktopPrimaryPhysicalBounds: CGRect?
    var desktopMirroredVirtualResolution: CGSize?
    var activeVirtualDisplaySetupGuard: VirtualDisplaySetupGuardState?

    /// Cursor monitoring - internal for extension access
    var cursorMonitor: CursorMonitor?
    var cursorUpdateMessagesSinceLastSample: UInt64 = 0
    var cursorPositionMessagesSinceLastSample: UInt64 = 0
    var droppedCursorUpdateMessagesSinceLastSample: UInt64 = 0
    var droppedCursorPositionMessagesSinceLastSample: UInt64 = 0
    var lastCursorControlSampleTime: CFAbsoluteTime = 0
    let cursorControlSampleInterval: CFAbsoluteTime = 1.0

    // Session state monitoring - internal for extension access
    var sessionStateMonitor: SessionStateMonitor?
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
    struct PendingHostHardwareIconRequest: Sendable {
        let clientID: UUID
        var preferredMaxPixelSize: Int
    }
    var pendingHostHardwareIconRequest: PendingHostHardwareIconRequest?
    var hostHardwareIconRequestTask: Task<Void, Never>?
    var hostHardwareIconRequestToken: UUID = .init()
    struct PendingHostWallpaperRequest: Sendable {
        let clientID: UUID
        let requestID: UUID
        var preferredMaxPixelWidth: Int
        var preferredMaxPixelHeight: Int
    }
    var pendingHostWallpaperRequest: PendingHostWallpaperRequest?
    var hostWallpaperRequestTask: Task<Void, Never>?
    var hostWallpaperRequestToken: UUID = .init()
    struct PendingHostSoftwareUpdateStatusRequest: Sendable {
        let clientID: UUID
        var forceRefresh: Bool
    }
    var pendingHostSoftwareUpdateStatusRequest: PendingHostSoftwareUpdateStatusRequest?
    var hostSoftwareUpdateStatusRequestTask: Task<Void, Never>?
    var hostSoftwareUpdateStatusRequestToken: UUID = .init()
    let appIconCatalogStore = HostAppIconCatalogStore()
    @ObservationIgnored var sharedClipboardBridge: MirageHostSharedClipboardBridge?
    @ObservationIgnored var sharedClipboardStatusByClientID: [UUID: Bool] = [:]
    @ObservationIgnored var clipboardChunkBuffer = MirageSharedClipboardChunkBuffer()

    /// Menu bar passthrough - internal for extension access
    let menuBarMonitor = MenuBarMonitor()

    /// Window activation (robust multi-method for headless Macs)
    @ObservationIgnored let windowActivator: WindowActivator = .forCurrentEnvironment()

    /// Lights Out (curtain) preference for app/window and desktop streams.
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

    /// Called when the Lights Out hold-Escape emergency recovery is triggered.
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
    @ObservationIgnored nonisolated(unsafe) var screenParametersObserver: NSObjectProtocol?
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
    typealias ControlMessageHandler = @MainActor (ControlMessage, ClientContext) async -> Void
    var controlMessageHandlers: [ControlMessageType: ControlMessageHandler] = [:]
    nonisolated(unsafe) var diagnosticsContextProviderToken: LoomDiagnosticsContextProviderToken?

    public enum HostState: Equatable {
        case idle
        case starting
        case advertising(controlPort: UInt16)
        case error(String)
    }

    struct PendingAppListRequest: Equatable {
        let clientID: UUID
        var requestID: UUID
        var requestedForceRefresh: Bool
        var forceIconReset: Bool
        var priorityBundleIdentifiers: [String]
        var knownIconSignaturesByBundleIdentifier: [String: String]
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
        resolvedConfiguration.quicALPN = ["mirage-v2"]

        let name = hostName ?? Host.current().localizedName ?? "Mac"
        let identityKeyID = Self.identityKeyID(for: MirageKit.identityManager)
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
        let supportedColorDepths = Self.detectSupportedColorDepths()
        let resolvedDeviceID = deviceID ?? UUID()
        let peerAdvertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: resolvedDeviceID,
            identityKeyID: identityKeyID,
            modelIdentifier: hardwareModelIdentifier,
            iconName: hardwareIconName,
            machineFamily: hardwareMachineFamily,
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            supportedColorDepths: supportedColorDepths
        )
        MirageLogger.host(
            "Hardware metadata model=\(hardwareModelIdentifier ?? "nil") icon=\(hardwareIconName ?? "nil") family=\(hardwareMachineFamily ?? "nil") color=\(hardwareColorCode?.description ?? "nil")"
        )
        advertisedPeerAdvertisement = peerAdvertisement
        hostID = resolvedDeviceID
        serviceName = name
        loomNode = LoomNode(
            configuration: resolvedConfiguration,
            identityManager: MirageKit.identityManager
        )
        encoderConfig = encoderConfiguration
        networkConfig = resolvedConfiguration
        self.supportedColorDepths = supportedColorDepths

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
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
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

            "host.remoteTransportEnabled": .bool(remoteTransportEnabled),
            "host.lightsOutEnabled": .bool(lightsOutEnabled),
            "host.lightsOutDisabledByEnvironment": .bool(lightsOutDisabledByEnvironment),
            "host.lockHostWhenStreamingStops": .bool(lockHostWhenStreamingStops),
            "host.connectedClientsCount": .int(connectedClients.count),
            "host.activeStreamsCount": .int(activeStreams.count),
            "host.availableWindowsCount": .int(availableWindows.count),
            "host.desktopStreamActive": .bool(desktopStreamID != nil),

            "host.desktopResizeInFlight": .bool(activeDesktopResizeRequest != nil),
            "host.desktopSharedDisplayTransitionInFlight": .bool(desktopSharedDisplayTransitionInFlight),
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
            hostName: advertisedPeerAdvertisement.hostName,
            directTransports: advertisedPeerAdvertisement.directTransports,
            metadata: advertisedPeerAdvertisement.metadata
        )
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
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

        return String.mirageDecodedCString(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectSupportedColorDepths() -> [MirageStreamColorDepth] {
        let ultraProbe = strictUltraColorDepthProbeResult()
        var supported: [MirageStreamColorDepth] = [.standard]

        if supportsProColorDepth() {
            supported.append(.pro)
        }
        if ultraProbe.supportsUltra444 {
            supported.append(.ultra)
        }

        let chromaText = ultraProbe.encodedChromaSampling?.rawValue ?? "unknown"
        let hardwareText = ultraProbe.usingHardwareEncoder.map { String($0) } ?? "unknown"
        MirageLogger.host(
            "Color depth support: supported=\(supported.map(\.rawValue).joined(separator: ",")) " +
                "ultraCaptureXF44=\(ultraProbe.captureAcceptsXF44) " +
                "ultraSessionCreated=\(ultraProbe.encoderSessionCreated) " +
                "ultraChroma=\(chromaText) " +
                "ultraHardware=\(hardwareText)"
        )

        return supported
    }

    private static func supportsProColorDepth() -> Bool {
        true
    }

    private static func supportsStrictUltraColorDepth() -> Bool {
        strictUltraColorDepthProbeResult().supportsUltra444
    }

    private static func strictUltraColorDepthProbeResult() -> VideoEncoderUltraProbeResult {
        UltraColorDepthProbeCache.result
    }

    private enum UltraColorDepthProbeCache {
        static let result = VideoEncoder.probeStrictUltra444Support()
    }

    func effectiveColorDepth(
        for requested: MirageStreamColorDepth?
    ) -> MirageStreamColorDepth? {
        guard let requested else { return nil }
        if supportedColorDepths.contains(requested) {
            return requested
        }

        return supportedColorDepths
            .filter { $0.sortRank <= requested.sortRank }
            .max(by: { lhs, rhs in
                lhs.sortRank < rhs.sortRank
            })
            ?? supportedColorDepths.first
            ?? .standard
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
        return Self.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )
    }

    nonisolated static func resolvedMirroredDesktopInputBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?
    )
    -> CGRect {
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

        return CGRect(
            x: physicalBounds.minX + (physicalBounds.width - fittedSize.width) * 0.5,
            y: physicalBounds.minY + (physicalBounds.height - fittedSize.height) * 0.5,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    nonisolated static func resolvedDesktopCursorStartPoint(
        inputBounds: CGRect
    )
    -> CGPoint? {
        guard inputBounds.width > 0, inputBounds.height > 0 else { return nil }
        return CGPoint(x: inputBounds.midX, y: inputBounds.midY)
    }

    nonisolated static func cocoaRect(fromCGDisplayRect cgRect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    nonisolated static func resolvedMirroredDesktopCursorMonitorBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?,
        primaryHeight: CGFloat
    )
    -> CGRect {
        cocoaRect(
            fromCGDisplayRect: resolvedMirroredDesktopInputBounds(
                physicalBounds: physicalBounds,
                virtualResolution: virtualResolution
            ),
            primaryHeight: primaryHeight
        )
    }

    func setRemoteControlPort(_ port: UInt16?) {
        remoteControlPort = port
    }

    struct VirtualDisplaySetupGuardState {
        let token: UUID
        let periodicTask: Task<Void, Never>
    }

    func resolvedPrimaryPhysicalDisplayVisibleBounds() -> CGRect? {
        let displayID = desktopPrimaryPhysicalDisplayID ?? resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
        let fullBounds = CGDisplayBounds(displayID)
        guard fullBounds.width > 0, fullBounds.height > 0 else { return nil }

        desktopPrimaryPhysicalDisplayID = displayID
        desktopPrimaryPhysicalBounds = fullBounds

        var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            displayID,
            knownBounds: fullBounds
        )
        visibleBounds = visibleBounds.intersection(fullBounds)
        if visibleBounds.isEmpty {
            visibleBounds = fullBounds
        }
        return visibleBounds
    }

    func centerCursorOnPrimaryPhysicalDisplay(reason: String) {
        guard let visibleBounds = resolvedPrimaryPhysicalDisplayVisibleBounds() else { return }
        let point = CGPoint(x: visibleBounds.midX, y: visibleBounds.midY)
        CGWarpMouseCursorPosition(point)
        MirageLogger.host(
            "Virtual display setup cursor centered reason=\(reason) x=\(Int(point.x.rounded())) y=\(Int(point.y.rounded()))"
        )
    }

    func performVirtualDisplaySetupWakeAndCenter(reason: String) {
        PowerAssertionManager.wakeDisplay()
        centerCursorOnPrimaryPhysicalDisplay(reason: reason)
    }

    func beginVirtualDisplaySetupGuard(reason: String) async -> UUID {
        if let existing = activeVirtualDisplaySetupGuard {
            await cancelVirtualDisplaySetupGuard(existing.token, reason: "superseded:\(reason)")
        }

        await PowerAssertionManager.shared.enable()
        performVirtualDisplaySetupWakeAndCenter(reason: "\(reason):begin")

        let token = UUID()
        let periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.performVirtualDisplaySetupWakeAndCenter(reason: "\(reason):keepalive")
            }
        }

        activeVirtualDisplaySetupGuard = VirtualDisplaySetupGuardState(
            token: token,
            periodicTask: periodicTask
        )
        MirageLogger.host("Virtual display setup guard started reason=\(reason) token=\(token.uuidString)")
        return token
    }

    func completeVirtualDisplaySetupGuard(
        _ token: UUID?,
        reason: String
    ) async {
        guard let token,
              let activeGuard = activeVirtualDisplaySetupGuard,
              activeGuard.token == token else {
            return
        }

        activeGuard.periodicTask.cancel()
        activeVirtualDisplaySetupGuard = nil
        performVirtualDisplaySetupWakeAndCenter(reason: "\(reason):settled")
        MirageLogger.host("Virtual display setup guard completed reason=\(reason) token=\(token.uuidString)")

        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                await PowerAssertionManager.shared.disable()
                return
            }

            if self?.activeVirtualDisplaySetupGuard == nil {
                self?.performVirtualDisplaySetupWakeAndCenter(reason: "\(reason):delayed")
            }
            await PowerAssertionManager.shared.disable()
        }
    }

    func cancelVirtualDisplaySetupGuard(
        _ token: UUID?,
        reason: String
    ) async {
        guard let token,
              let activeGuard = activeVirtualDisplaySetupGuard,
              activeGuard.token == token else {
            return
        }

        activeGuard.periodicTask.cancel()
        activeVirtualDisplaySetupGuard = nil
        await PowerAssertionManager.shared.disable()
        MirageLogger.host("Virtual display setup guard cancelled reason=\(reason) token=\(token.uuidString)")
    }

    /// Resolve the current virtual display bounds for secondary desktop streaming.
    /// Uses CoreGraphics coordinates for input injection.
    func resolveDesktopDisplayBounds() -> CGRect? {
        guard let displayID = desktopVirtualDisplayID else {
            return resolvedDesktopDisplayBounds(
                cachedBounds: desktopDisplayBounds,
                liveBounds: nil,
                displayModeSize: nil,
                displayOrigin: desktopDisplayBounds?.origin ?? .zero
            )
        }

        let bounds = CGDisplayBounds(displayID)
        let displayModeSize = CGDisplayCopyDisplayMode(displayID).map {
            CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
        }
        let resolvedBounds = resolvedDesktopDisplayBounds(
            cachedBounds: desktopDisplayBounds,
            liveBounds: bounds,
            displayModeSize: displayModeSize,
            displayOrigin: bounds.origin
        )
        if let resolvedBounds { desktopDisplayBounds = resolvedBounds }
        return resolvedBounds
    }

    /// Last successfully resolved cursor-monitor bounds for the virtual display.
    /// Prevents transient resolution failures from dropping the stream.
    private var lastResolvedCursorMonitorBounds: CGRect?

    /// Resolve the current virtual display bounds for cursor monitoring (Cocoa coordinates).
    func resolveDesktopDisplayBoundsForCursorMonitor() -> CGRect? {
        if let bounds = resolveDesktopDisplayBoundsForCursorMonitorCore() {
            lastResolvedCursorMonitorBounds = bounds
            return bounds
        }
        return lastResolvedCursorMonitorBounds
    }

    private func resolveDesktopDisplayBoundsForCursorMonitorCore() -> CGRect? {
        // Preferred: NSScreen.frame is already in Cocoa coordinates (bottom-left origin).
        if let displayID = desktopVirtualDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen.frame
        }

        // Fallback paths use CGDisplayBounds / desktopDisplayBounds which are in CG
        // coordinates (top-left origin). Convert to Cocoa so the CursorMonitor's
        // NSEvent.mouseLocation containment check uses a consistent coordinate space.
        if let displayID = desktopVirtualDisplayID {
            let cgBounds = CGDisplayBounds(displayID)
            if let resolved = resolvedDesktopDisplayBounds(
                cachedBounds: desktopDisplayBounds,
                liveBounds: cgBounds,
                displayModeSize: nil,
                displayOrigin: cgBounds.origin
            ) {
                return cocoaRectFromCGDisplayRect(resolved)
            }
            return nil
        }
        if let resolved = resolvedDesktopDisplayBounds(
            cachedBounds: desktopDisplayBounds,
            liveBounds: nil,
            displayModeSize: nil,
            displayOrigin: desktopDisplayBounds?.origin ?? .zero
        ) {
            return cocoaRectFromCGDisplayRect(resolved)
        }
        return nil
    }

    /// Convert a CG display rect (top-left origin) to Cocoa screen coordinates (bottom-left origin).
    private func cocoaRectFromCGDisplayRect(_ cgRect: CGRect) -> CGRect {
        Self.cocoaRect(
            fromCGDisplayRect: cgRect,
            primaryHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
    }

    nonisolated static func resolvedDesktopPrimaryPhysicalDisplaySnapshot(
        cachedDisplayID: CGDirectDisplayID?,
        cachedBounds: CGRect?,
        resolvedPrimaryDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID,
        boundsProvider: (CGDirectDisplayID) -> CGRect
    ) -> (displayID: CGDirectDisplayID, bounds: CGRect?) {
        var candidateDisplayIDs: [CGDirectDisplayID] = []

        func appendCandidate(_ displayID: CGDirectDisplayID?) {
            guard let displayID else { return }
            guard !candidateDisplayIDs.contains(displayID) else { return }
            candidateDisplayIDs.append(displayID)
        }

        appendCandidate(cachedDisplayID)
        appendCandidate(resolvedPrimaryDisplayID)
        appendCandidate(mainDisplayID)

        for displayID in candidateDisplayIDs {
            let bounds = boundsProvider(displayID)
            if bounds.width > 0, bounds.height > 0 {
                return (displayID, bounds)
            }
        }

        let fallbackBounds: CGRect? = if let cachedBounds,
                                         cachedBounds.width > 0,
                                         cachedBounds.height > 0 {
            cachedBounds
        } else {
            nil
        }

        return (candidateDisplayIDs.first ?? mainDisplayID, fallbackBounds)
    }

    /// Refresh cached physical display bounds after mirroring changes.
    /// Returns the updated physical bounds.
    func refreshDesktopPrimaryPhysicalBounds() -> CGRect {
        let snapshot = Self.resolvedDesktopPrimaryPhysicalDisplaySnapshot(
            cachedDisplayID: desktopPrimaryPhysicalDisplayID,
            cachedBounds: desktopPrimaryPhysicalBounds,
            resolvedPrimaryDisplayID: resolvePrimaryPhysicalDisplayID(),
            mainDisplayID: CGMainDisplayID(),
            boundsProvider: { CGDisplayBounds($0) }
        )
        desktopPrimaryPhysicalDisplayID = snapshot.displayID
        if let bounds = snapshot.bounds {
            desktopPrimaryPhysicalBounds = bounds
            return bounds
        }
        return desktopPrimaryPhysicalBounds ?? .zero
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
    ///   - clientDisplayResolution: Client's display resolution for virtual display sizing
    ///   - keyFrameInterval: Optional client-requested keyframe interval (in frames)
    ///   - bitDepth: Optional client-requested stream bit depth
    ///   - captureQueueDepth: Optional ScreenCaptureKit queue depth override
    ///   - bitrate: Optional target bitrate (bits per second)
    ///   - targetFrameRate: Optional client-selected frame rate override

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
