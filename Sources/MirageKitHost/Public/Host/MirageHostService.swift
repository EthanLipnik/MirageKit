//
//  MirageHostService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import Dispatch
import Foundation
import Loom
import MirageBootstrapShared
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
    public internal(set) var availableWindows: [MirageMedia.MirageWindow] = []

    /// Currently active streams
    public internal(set) var activeStreams: [MirageStreamSession] = []

    /// Connected clients
    public internal(set) var connectedClients: [MirageConnectedClient] = []

    /// Current host state
    public internal(set) var state: HostState = .idle

    /// Current session state (locked, unlocked, sleeping, etc.)
    public internal(set) var sessionState: LoomSessionAvailability = .ready

    /// Mirage-owned projection of the host login-session availability for product policy.
    var mirageSessionAvailability: MirageWire.MirageHostSessionAvailability {
        get {
            MirageWire.MirageHostSessionAvailability(loomAvailability: sessionState)
        }
        set {
            sessionState = newValue.loomAvailability
        }
    }

    /// Whether shared clipboard sync is enabled for eligible active sessions.
    public var sharedClipboardEnabled: Bool = false {
        didSet {
            guard oldValue != sharedClipboardEnabled else { return }
            syncSharedClipboardState(forceStatusBroadcast: true)
        }
    }

    /// Whether app-stream window close on the client should attempt to close the host window.
    public var closeHostWindowOnClientWindowClose: Bool = false

    /// Preferred low-power policy for host encoder sessions.
    public var encoderLowPowerModePreference: MirageMedia.MirageCodecLowPowerModePreference = .auto {
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
    public internal(set) var desktopCursorPresentation: MirageWire.MirageDesktopCursorPresentation = .simulatedCursor

    /// Latest client-owned stream-option state mirrored back to the host UI.
    public internal(set) var remoteClientStreamStatusOverlayEnabled = false

    /// Latest client-owned stream-options display mode mirrored back to the host UI.
    public internal(set) var remoteClientStreamOptionsDisplayMode: MirageWire.MirageStreamOptionsDisplayMode = .inStream

    /// Whether the connected client currently exposes desktop cursor lock controls.
    public internal(set) var remoteClientDesktopCursorLockAvailable = false

    /// Latest client-owned desktop cursor lock mode mirrored back to the host UI.
    public internal(set) var remoteClientDesktopCursorLockMode: MirageWire.MirageDesktopCursorLockMode = .off

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
            if let adapter = mirageTrustProviderAdapter,
               trustProvider !== adapter {
                mirageTrustProvider = nil
                mirageTrustProviderAdapter = nil
            }
            loomNode.trustProvider = trustProvider
        }
    }

    /// Mirage-owned trust provider consulted through a Loom adapter during the authenticated session handshake.
    @ObservationIgnored public var mirageTrustProvider: (any MirageTrustProvider)? {
        didSet {
            guard let mirageTrustProvider else {
                if let adapter = mirageTrustProviderAdapter,
                   trustProvider === adapter {
                    trustProvider = nil
                }
                mirageTrustProviderAdapter = nil
                return
            }

            let adapter = MirageTrustProviderLoomAdapter(provider: mirageTrustProvider)
            mirageTrustProviderAdapter = adapter
            trustProvider = adapter
        }
    }

    @ObservationIgnored private var mirageTrustProviderAdapter: MirageTrustProviderLoomAdapter?

    /// Software update controller used for client-initiated host update status and install requests.
    public weak var softwareUpdateController: (any MirageHostSoftwareUpdateController)?

    /// Provider used for client-initiated host support log archive export.
    public var hostSupportLogArchiveProvider: (@MainActor @Sendable () async throws -> URL)?

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

    @ObservationIgnored private var cachedPermissionManager: MirageAccessibilityPermissionManager?

    /// Accessibility permission manager for host UI permission state.
    public var permissionManager: MirageAccessibilityPermissionManager {
        if let cachedPermissionManager {
            return cachedPermissionManager
        }
        let manager = MirageAccessibilityPermissionManager()
        cachedPermissionManager = manager
        return manager
    }

    /// Whether the most recent capture inventory attempt hit an explicit screen-recording denial.
    public internal(set) var lastScreenRecordingPermissionDenied = false

    /// Window controller for host window management.
    public let windowController = MirageHostWindowController()

    /// Input controller for injecting remote input.
    public nonisolated let inputController = MirageHostInputController()

    /// Whether direct remote control transport is enabled.
    public var remoteTransportEnabled: Bool = false {
        didSet {
            Task { @MainActor [weak self] in
                await self?.updateRemoteControlListenerState()
            }
        }
    }

    /// Bound local port for the remote control listener.
    public internal(set) var remoteControlPort: UInt16?

    /// Whether the remote control listener is currently ready to accept connections.
    public internal(set) var remoteControlListenerReady = false

    /// Whether the host can currently accept a new client session.
    public var allowsNewClientConnections: Bool {
        !softwareUpdateMaintenanceModeActive && singleClientSessionID == nil
    }

    var advertisedConnectionAvailabilityReason: MirageConnectivity.MiragePeerAdvertisementMetadata.AvailabilityReason {
        if softwareUpdateMaintenanceModeActive {
            return .softwareUpdate
        }
        return singleClientSessionID == nil ? .available : .busy
    }

    /// Callback fired when host connection availability changes.
    public var onConnectionAvailabilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    /// Callback fired when the CloudKit-only local endpoint hint changes.
    @ObservationIgnored @_spi(HostApp) public var onCloudKitLocalEndpointHintChanged: (@MainActor @Sendable () -> Void)?

    /// STUN keepalive that refreshes the NAT mapping for the remote control port.
    var stunKeepalive: LoomSTUNKeepalive?

    /// NAT-PMP / PCP port mapping that provides a stable external port.
    var natPortMapping: LoomNATPortMapping?

    /// Called when host should resize a window before streaming begins.
    /// The callback receives the window and the target size in points.
    /// This allows the app to resize and center the window via Accessibility API.
    public var onResizeWindowForStream: ((MirageMedia.MirageWindow, CGSize) -> Void)?

    /// Loom node that owns host discovery, control sessions, and media streams.
    public let loomNode: LoomNode
    /// Current host advertisement payload before Loom republishes it.
    var advertisedPeerAdvertisement: LoomPeerAdvertisement
    /// Last local endpoint hint fingerprint that triggered a CloudKit registration refresh.
    var lastCloudKitLocalEndpointHintFingerprint: String?
    /// Debounced task that republishes updated host advertisement metadata.
    var advertisementRefreshTask: Task<Void, Never>?
    /// Control listener used for direct remote clients.
    var remoteControlListener: NWListener?
    /// Encoder configuration applied to newly created stream contexts.
    let encoderConfig: MirageEncoderConfiguration
    /// Loom network configuration used for discovery and listener setup.
    let networkConfig: LoomNetworkConfiguration
    /// User-visible host name advertised to clients.
    let serviceName: String
    /// Stable host identifier advertised during discovery and bootstrap.
    var hostID: UUID = .init()
    /// Color-depth modes the host currently advertises to clients.
    public internal(set) var supportedColorDepths: [MirageMedia.MirageStreamColorDepth] = [.standard, .pro]
    /// Whether the host currently advertises ProRes 4444 app/window stream support.
    public internal(set) var supportsProRes4444 = false
    let localNetworkMonitor = MirageLocalNetworkMonitor(label: "host")
    /// Power-state monitor used by the encoder low-power policy extension.
    let encoderPowerStateMonitor = MiragePowerStateMonitor()
    /// Latest power-state sample used to decide encoder low-power mode.
    var encoderPowerStateSnapshot = MiragePowerStateSnapshot(
        isSystemLowPowerModeEnabled: false,
        isOnBattery: nil
    )

    /// Current peer advertisement payload published through Loom discovery.
    public var currentPeerAdvertisement: LoomPeerAdvertisement {
        advertisedPeerAdvertisement
    }

    /// Active app/window stream routing and connected client state.
    var nextStreamID: StreamID = 1
    var streamsByID: [StreamID: StreamContext] = [:]
    // O(1) lookup maps for active app/window stream routing.
    var activeSessionByStreamID: [StreamID: MirageStreamSession] = [:]
    var activeStreamIDByWindowID: [WindowID: StreamID] = [:]
    var activeWindowIDByStreamID: [StreamID: WindowID] = [:]
    var clientsBySessionID: [UUID: ClientContext] = [:]
    var clientsByID: [UUID: ClientContext] = [:]
    var disconnectingClientIDs: Set<UUID> = []
    var mediaPathObserverTasksBySessionID: [UUID: Task<Void, Never>] = [:]
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
    /// Thread-safe stream routing table used by input and media fast paths.
    nonisolated let streamRegistry = HostStreamRegistry()
    /// Active receive loops keyed by authenticated client session.
    nonisolated let receiveLoopsBySessionID = Locked<[UUID: HostReceiveLoop]>([:])
    /// Active priority input routes keyed by authenticated client session.
    nonisolated let priorityInputRoutesBySessionID = Locked<[UUID: HostPriorityInputRoute]>([:])
    /// Per-client serial queues for ordered control-message dispatch.
    nonisolated let controlQueuesByClientID = Locked<[UUID: DispatchQueue]>([:])
    /// Queue for nonisolated transport callbacks and packet send completions.
    nonisolated let transportQueue = DispatchQueue(
        label: "com.mirage.host.transport",
        qos: .userInteractive
    )

    /// Active video media streams by stream ID.
    var videoMediaStreamsByStreamID: [StreamID: any MirageQueuedUnreliableMediaStream] = [:]
    /// Client-side route evidence captured at media stream startup.
    var mediaPathClientEvidenceByStreamID: [StreamID: HostStreamMediaPathClientEvidence] = [:]
    /// Per-client media registration authentication context.
    var mediaSecurityByClientID: [UUID: MirageMediaSecurityContext] = [:]
    /// Per-client media payload encryption policy.
    var mediaEncryptionEnabledByClientID: [UUID: Bool] = [:]
    /// Active audio media streams by client ID.
    var audioMediaStreamsByClientID: [UUID: any MirageQueuedUnreliableMediaStream] = [:]
    /// Active host audio pipelines by client ID.
    var audioPipelinesByClientID: [UUID: HostAudioPipeline] = [:]
    /// Selected source stream for client audio capture.
    var audioSourceStreamByClientID: [UUID: StreamID] = [:]
    /// Latest requested audio configuration by client.
    var audioConfigurationByClientID: [UUID: MirageMedia.MirageAudioConfiguration] = [:]
    /// Last audio streamStarted payload sent to each client.
    var audioStartedMessageByClientID: [UUID: MirageWire.AudioStreamStartedMessage] = [:]
    /// Last audio streamStarted payload acknowledged onto the control channel.
    var sentAudioStartedMessageByClientID: [UUID: MirageWire.AudioStreamStartedMessage] = [:]
    /// Clients whose current audio transport send failure has already been logged.
    var audioSendErrorReportedByClientID: Set<UUID> = []
    /// First-sample watchdogs for newly activated host audio capture.
    var audioFirstSampleWatchdogsByClientID: [UUID: Task<Void, Never>] = [:]
    /// Clients that already retried audio startup after the first-sample watchdog fired.
    var audioFirstSampleRetryAttemptedByClientID: Set<UUID> = []
    /// Most recent host audio sample time by client.
    var audioLastSampleTimeByClientID: [UUID: CFAbsoluteTime] = [:]
    /// Capture-level diagnostics for host audio samples by client.
    var audioCaptureLevelStateByClientID: [UUID: HostAudioCaptureLevelState] = [:]
    /// Minimum window sizes reported by clients and enforced before stream startup.
    var minimumSizesByWindowID: [WindowID: CGSize] = [:]
    /// Base times used for host-side stream startup telemetry.
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]
    /// Streams whose media-registration startup milestone has already been logged.
    var streamStartupRegistrationLogged: Set<StreamID> = []
    /// Pending startup attempts awaiting media registration or terminal failure.
    var pendingStartupAttemptsByStreamID: [StreamID: PendingStartupAttempt] = [:]
    /// Timeout tasks for pending startup attempts.
    var startupAttemptTimeoutTasksByStreamID: [StreamID: Task<Void, Never>] = [:]
    /// Registered custom-stream source factories keyed by custom stream kind.
    var customStreamSourcesByKind: [String: any MirageCustomStreamSource] = [:]
    /// Active custom-stream source sessions by stream ID.
    var customStreamSessionsByStreamID: [StreamID: any MirageCustomStreamSession] = [:]
    /// Custom-stream descriptors advertised for active custom streams.
    var customStreamDescriptorsByStreamID: [StreamID: MirageMedia.MirageCustomStreamDescriptor] = [:]
    /// Owning client session for each custom stream.
    var customStreamClientSessionIDByStreamID: [StreamID: UUID] = [:]
    /// Startup request IDs for active or starting custom streams.
    var customStreamStartupRequestIDByStreamID: [StreamID: UUID] = [:]
    /// App-atlas coordinators keyed by connected client ID.
    var appAtlasCoordinatorsByClientID: [UUID: AppAtlasMediaCoordinator] = [:]
    /// Client IDs currently creating an app-atlas coordinator.
    var appAtlasCoordinatorCreationClientIDs: Set<UUID> = []
    /// App stream requests accepted while the host session is locked.
    var pendingLockedAppStreamIntentsByAppSessionID: [UUID: PendingLockedAppStreamIntent] = [:]
    /// Pending locked app-stream app-session IDs in resume order.
    var pendingLockedAppStreamIntentOrder: [UUID] = []
    /// Host window IDs reserved by app-stream startup before activation.
    var appStreamStartupReservedWindowIDs: Set<WindowID> = []
    /// Maximum time a stream startup attempt may wait for registration.
    let startupAttemptTimeoutSeconds: Duration = .seconds(5)
    nonisolated static let lightsOutDisableEnvironmentKey = "MIRAGE_DISABLE_LIGHTS_OUT"
    let lightsOutDisabledByEnvironment: Bool = MirageHostService.isLightsOutDisabledByEnvironment()
    var sendErrorBursts: UInt64 = 0
    var transportRefreshRequests: UInt64 = 0
    var transportSendErrorReported: Set<StreamID> = []
    var controlChannelSendFailureReported: Set<UUID> = []

    /// Time after which a client error is treated as stale for reporting.
    let clientErrorTimeoutSeconds: CFAbsoluteTime = 2.0

    /// Approval timeout to avoid wedging the single-client slot.
    let connectionApprovalTimeoutSeconds: CFAbsoluteTime = 15.0

    // MARK: - Client Liveness

    /// Last control or media activity time by client.
    nonisolated let clientLastActivityByID = Locked<[UUID: CFAbsoluteTime]>([:])
    /// Last media activity time by client.
    nonisolated let clientLastMediaActivityByID = Locked<[UUID: CFAbsoluteTime]>([:])
    /// Last successful control send activity time by client.
    nonisolated let clientLastControlSendActivityByID = Locked<[UUID: CFAbsoluteTime]>([:])
    /// Periodic task that expires inactive clients and background leases.
    var clientLivenessTask: Task<Void, Never>?
    /// Background lease expiration dates by client.
    var backgroundLeaseExpirationsByClientID: [UUID: Date] = [:]
    /// Non-expiring suspended-stream lease IDs by client.
    var suspendedBackgroundLeaseIDsByClientID: [UUID: UUID] = [:]
    /// Background lease timeout tasks by client.
    var backgroundLeaseTasksByClientID: [UUID: Task<Void, Never>] = [:]

    /// Per-window dedicated virtual display state for app/window streams.
    var windowVirtualDisplayStateByWindowID: [WindowID: WindowVirtualDisplayState] = [:]
    /// Per-stream queued resize targets for dedicated app/window displays.
    var pendingWindowResizeResolutionByStreamID: [StreamID: CGSize] = [:]
    /// Streams currently applying a dedicated app/window resize transaction.
    var windowResizeInFlightStreamIDs: Set<StreamID> = []
    /// Monotonic request counters for dedicated app/window resize transactions.
    var windowResizeRequestCounterByStreamID: [StreamID: UInt64] = [:]
    /// Debounced visible-frame drift monitor tasks by stream.
    var windowVisibleFrameMonitorTasks: [StreamID: Task<Void, Never>] = [:]
    /// Per-stream drift-stability state for visible-frame monitor hysteresis.
    var windowVisibleFrameDriftStateByStreamID: [StreamID: WindowVisibleFrameDriftState] = [:]
    /// Cooldown tracking for authoritative placement repairs (window -> last repair time).
    var lastWindowPlacementRepairAtByWindowID: [WindowID: CFAbsoluteTime] = [:]
    /// Shared-display generation for desktop/login shared-consumer flows.
    var sharedVirtualDisplayGeneration: UInt64 = 0
    /// Shared-display scale factor for desktop/login shared-consumer flows.
    var sharedVirtualDisplayScaleFactor: CGFloat = 2.0

    /// Active desktop stream and virtual-display mirroring state.
    var desktopStreamContext: StreamContext?
    /// Active desktop stream ID.
    var desktopStreamID: StreamID?
    /// Session ID that owns the active desktop stream.
    var desktopSessionID: UUID?
    /// Connected client context that owns the active desktop stream.
    var desktopStreamClientContext: ClientContext?
    /// Capture/display bounds for the active desktop stream.
    var desktopDisplayBounds: CGRect?
    /// Virtual display ID backing the active desktop stream, when applicable.
    var desktopVirtualDisplayID: CGDirectDisplayID?
    /// Client-requested desktop scale factor for the active stream.
    var desktopRequestedScaleFactor: CGFloat?
    /// Whether the desktop stream should use host-native resolution.
    var desktopUsesHostResolution: Bool = false
    /// Capture source selected for the active desktop stream.
    var desktopCaptureSource: MirageWire.MirageDesktopCaptureSource = .virtualDisplay
    /// Desktop stream mode selected for the active desktop stream.
    var desktopStreamMode: MirageMedia.MirageDesktopStreamMode = .unified
    /// Resize request currently being applied by the host.
    var activeDesktopResizeRequest: DesktopResizeRequestState?
    /// Latest desktop resize request queued behind an active resize.
    var queuedDesktopResizeRequest: DesktopResizeRequestState?
    /// Transaction lifecycle for host-side desktop resize acknowledgements.
    var desktopResizeTransactionState: DesktopResizeTransactionState = .idle
    /// Nesting depth for shared-display desktop transitions.
    var desktopSharedDisplayTransitionDepth: Int = 0
    /// Host-authoritative generation for desktop presentation updates.
    var desktopPresentationGeneration: UInt64 = 0
    /// Contract ID for the current host-accepted desktop geometry, when supplied by the client.
    var desktopCurrentGeometryContractID: UUID?
    /// Scene identity for the current host-accepted desktop geometry, when supplied by the client.
    var desktopCurrentGeometrySceneIdentity: String?
    /// Logical presentation size for the current host-accepted desktop geometry.
    var desktopCurrentGeometryPresentationResolution: CGSize?
    /// Display pixel size for the current host-accepted desktop geometry.
    var desktopCurrentGeometryDisplayPixelResolution: CGSize?
    /// Encoded pixel size for the current host-accepted desktop geometry.
    var desktopCurrentGeometryEncodedPixelResolution: CGSize?
    /// Display scale accepted for the current host-accepted desktop geometry.
    var desktopCurrentGeometryDisplayScaleFactor: CGFloat?
    /// Refresh target for the current host-accepted desktop geometry, when supplied by the client.
    var desktopCurrentGeometryRefreshTargetHz: Int?
    /// Periodic task that publishes host-visible desktop bounds to the client.
    var desktopVisibleBoundsUpdateTask: Task<Void, Never>?
    /// Last desktop visible-bounds snapshot sent to the client.
    var lastSentDesktopVisibleBounds: DesktopVisibleBoundsSnapshot?
    /// Active desktop media-pipeline restart caused by a media route policy-class change.
    var desktopMediaPathPipelineRestartStreamID: StreamID?
    /// Debounced task refreshing desktop display topology.
    @ObservationIgnored nonisolated(unsafe) var desktopDisplayTopologyRefreshTask: Task<Void, Never>?
    /// Deferred cleanup task for virtual displays created during desktop startup.
    @ObservationIgnored nonisolated(unsafe) var deferredDesktopStartupDisplayCleanupTask: Task<Void, Never>?
    /// Cancellable cleanup task for display restoration after an established desktop stream stops.
    @ObservationIgnored nonisolated(unsafe) var deferredDesktopDisplayCleanupTask: Task<Void, Never>?
    /// Generation token invalidating stale deferred desktop display cleanup work.
    var desktopDisplayCleanupGeneration: UInt64 = 0

    /// Request-scoped stream setups cancelled before a stream ID is established.
    var cancelledStreamSetupRequestIDs: Set<StreamSetupCancellationKey> = []
    /// Stream setup lifecycle state keyed by startup app-session ID.
    var streamSetupLifecycleBySessionID: [UUID: StreamSetupSessionLifecycle] = [:]
    /// Whether software update maintenance currently blocks new clients.
    var softwareUpdateMaintenanceModeActive = false

    /// Displays mirrored during desktop streaming (for restoration).
    var mirroredDesktopDisplayIDs: Set<CGDirectDisplayID> = []
    /// Snapshot of display mirroring state before desktop streaming.
    var desktopMirroringSnapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    /// Last known current Space for each physical display before Mirage reconfigures mirroring.
    var desktopDisplaySpaceSnapshot: [CGDirectDisplayID: CGSSpaceID] = [:]
    /// Primary physical display information captured before mirroring.
    var desktopPrimaryPhysicalDisplayID: CGDirectDisplayID?
    /// Bounds of the primary physical display before mirroring.
    var desktopPrimaryPhysicalBounds: CGRect?
    /// Topology signature used to detect physical display changes during mirroring.
    var desktopPhysicalDisplayTopologySignature: String?
    /// Virtual display resolution used while mirroring a desktop stream.
    var desktopMirroredVirtualResolution: CGSize?
    /// Temporary wake/cursor guard active during virtual-display setup.
    var activeVirtualDisplaySetupGuard: VirtualDisplaySetupGuardState?

    /// Cursor monitoring counters and cached bounds for desktop streams.
    var cursorMonitor: CursorMonitor?
    var cursorMonitoringStartTask: Task<Void, Never>?
    var cursorUpdateMessagesSinceLastSample: UInt64 = 0
    var cursorPositionMessagesSinceLastSample: UInt64 = 0
    var droppedCursorUpdateMessagesSinceLastSample: UInt64 = 0
    var droppedCursorPositionMessagesSinceLastSample: UInt64 = 0
    var lastCursorControlSampleTime: CFAbsoluteTime = 0
    let cursorControlSampleInterval: CFAbsoluteTime = 1.0
    /// Last successfully resolved cursor-monitor bounds for the virtual display.
    /// Prevents transient resolution failures from dropping the stream.
    var lastResolvedCursorMonitorBounds: CGRect?

    /// Host session-state monitoring and periodic refresh state.
    var sessionStateMonitor: SessionStateMonitor?
    var currentSessionToken: String = ""
    var sessionRefreshTask: Task<Void, Never>?
    var sessionRefreshGeneration: UInt64 = 0
    let sessionRefreshInterval: Duration = .seconds(3)

    /// App-stream runtime orchestrator (host-authoritative stream tiering + budgets).
    let appStreamRuntimeOrchestrator = AppStreamRuntimeOrchestrator()
    /// Unified stream policy applier with idempotent/cooldown reconfiguration.
    let streamPolicyApplier = StreamPolicyApplier()

    /// App-centric streaming manager for launch, inventory, and multi-window state.
    let appStreamManager = AppStreamManager()

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
    /// Active app-list request task.
    var appListRequestTask: Task<Void, Never>?
    /// Token that invalidates stale app-list request completions.
    var appListRequestToken: UUID = .init()
    /// Whether app-list refresh is deferred until interactive stream workload settles.
    var appListRequestDeferredForInteractiveWorkload: Bool = false
    /// Client IDs with an active host support-log export or transfer.
    var activeHostSupportLogClientIDs: Set<UUID> = []

    /// Pending host hardware-icon request, if any.
    var pendingHostHardwareIconRequest: PendingHostHardwareIconRequest?
    /// Active host hardware-icon request task.
    var hostHardwareIconRequestTask: Task<Void, Never>?
    /// Token that invalidates stale hardware-icon request completions.
    var hostHardwareIconRequestToken: UUID = .init()

    /// Pending host wallpaper request, if any.
    var pendingHostWallpaperRequest: PendingHostWallpaperRequest?
    /// Active host wallpaper request task.
    var hostWallpaperRequestTask: Task<Void, Never>?
    /// Token that invalidates stale wallpaper request completions.
    var hostWallpaperRequestToken: UUID = .init()

    /// Pending host software-update status request, if any.
    var pendingHostSoftwareUpdateStatusRequest: PendingHostSoftwareUpdateStatusRequest?
    /// Active host software-update status request task.
    var hostSoftwareUpdateStatusRequestTask: Task<Void, Never>?
    /// Token that invalidates stale software-update status completions.
    var hostSoftwareUpdateStatusRequestToken: UUID = .init()
    /// Disk-backed app icon catalog cache.
    let appIconCatalogStore = HostAppIconCatalogStore()
    /// Host shared-clipboard bridge for active clients.
    @ObservationIgnored var sharedClipboardBridge: MirageHostSharedClipboardBridge?
    /// Latest shared-clipboard enablement status per client.
    @ObservationIgnored var sharedClipboardStatusByClientID: [UUID: Bool] = [:]
    /// Chunk reassembler for incoming shared-clipboard payloads.
    @ObservationIgnored var clipboardChunkBuffer = MirageSharedClipboardChunkBuffer()

    /// Menu bar passthrough monitor for forwarding host app menu state.
    let menuBarMonitor = MenuBarMonitor()

    /// Platform backend used for host window and application catalog operations.
    @ObservationIgnored var platformWindowCatalogBackend: any MirageHostWindowCatalogBackend = MacOSHostWindowCatalogBackend()

    /// Platform backend used for host input injection and close-alert actions.
    @ObservationIgnored nonisolated(unsafe) var platformInputInjectionBackend: any MirageHostInputInjectionBackend =
        MacOSHostInputInjectionBackend()

    /// Platform backend used for host video encoder construction.
    @ObservationIgnored var platformVideoEncoderFactoryBackend: any MirageHostVideoEncoderFactoryBackend =
        MacOSHostVideoEncoderFactoryBackend()

    /// Platform backend used for host capture engine construction.
    @ObservationIgnored var platformCaptureEngineFactoryBackend: any MirageHostCaptureEngineFactoryBackend =
        MacOSHostCaptureEngineFactoryBackend()

    /// Platform backend used for host capture content discovery.
    @ObservationIgnored var platformCaptureContentProviderBackend: any MirageHostCaptureContentProviderBackend =
        MacOSHostCaptureContentProviderBackend()

    /// Platform backend used for host audio pipeline construction.
    @ObservationIgnored var platformAudioPipelineFactoryBackend: any MirageHostAudioPipelineFactoryBackend =
        MacOSHostAudioPipelineFactoryBackend()

    /// Platform backend used for shared host virtual display management.
    @ObservationIgnored var platformVirtualDisplayBackend: any MirageHostVirtualDisplayBackend =
        MacOSHostVirtualDisplayBackend()

    /// Lights Out (curtain) preference for app/window and desktop streams.
    public var lightsOutEnabled: Bool = false {
        didSet {
            Task { @MainActor [weak self] in
                await self?.updateLightsOutState()
            }
        }
    }

    /// Host-side shortcut that force stops streams and locks the Mac while Lights Out is active.
    public var lightsOutEmergencyShortcut: MirageInput.MirageClientShortcutBinding =
        MirageHostLightsOutShortcut.defaultEmergencyShortcut {
        didSet {
            guard oldValue != lightsOutEmergencyShortcut else { return }
            Task { @MainActor [weak self] in
                await self?.updateLightsOutState()
            }
        }
    }

    /// Whether to lock the host when all active streaming has stopped.
    public var lockHostWhenStreamingStops: Bool = false

    /// Optional override for host lock behavior (defaults to CGSession if nil).
    public var lockHostHandler: (@MainActor () -> Void)?

    /// Called when the Lights Out emergency shortcut is triggered.
    @ObservationIgnored public var onLightsOutEmergencyShortcut: (@MainActor () async -> Void)? {
        didSet {
            lightsOutController.onEmergencyShortcut = onLightsOutEmergencyShortcut
        }
    }

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
    nonisolated let inputStreamCache = InputStreamCache()

    /// Fast input handler called on `inputQueue`, outside the main actor, for lowest-latency event delivery.
    @ObservationIgnored public nonisolated(unsafe) var onInputEvent: ((
        _ event: MirageInput.MirageInputEvent,
        _ window: MirageMedia.MirageWindow,
        _ client: MirageConnectedClient
    )
        -> Void)?

    var controlMessageHandlers: [MirageWire.ControlMessageType: ControlMessageHandler] = [:]
    @ObservationIgnored nonisolated(unsafe) var diagnosticsContextProviderToken: MirageDiagnosticsContextProviderToken?

    /// Creates a host service with optional identity and transport configuration overrides.
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
        resolvedConfiguration.enabledDirectTransports = MirageKit.mirageAppDirectTransports
        resolvedConfiguration.quicPort = 0
        resolvedConfiguration.quicALPN = []

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
        let supportsProRes4444 = Self.detectProRes4444Support()
        let resolvedDeviceID = deviceID ?? UUID()
        let peerAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: resolvedDeviceID,
            identityKeyID: identityKeyID,
            modelIdentifier: hardwareModelIdentifier,
            iconName: hardwareIconName,
            machineFamily: hardwareMachineFamily,
            hostName: MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            supportedColorDepths: supportedColorDepths,
            supportsProRes4444: supportsProRes4444
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
        self.supportsProRes4444 = supportsProRes4444

        windowController.hostService = self
        inputController.hostService = self
        inputController.windowController = windowController
        platformInputInjectionBackend = MacOSHostInputInjectionBackend(inputController: inputController)

        onResizeWindowForStream = { [weak windowController] window, size in
            windowController?.resizeAndCenterWindowForStream(window, targetSize: size)
        }

        lightsOutController.onOverlayWindowsChanged = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshLightsOutCaptureExclusions()
            }
        }
        lightsOutController.onEmergencyShortcut = onLightsOutEmergencyShortcut
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
        desktopDisplayTopologyRefreshTask?.cancel()
        let powerStateMonitor = encoderPowerStateMonitor
        Task { @MainActor in
            powerStateMonitor.stop()
        }
        guard let diagnosticsContextProviderToken else { return }
        Task {
            await MirageDiagnosticsContextRegistry.unregisterContextProvider(diagnosticsContextProviderToken)
        }
    }
}

#endif
