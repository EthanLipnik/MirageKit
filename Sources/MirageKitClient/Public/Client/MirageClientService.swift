//
//  MirageClientService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation
import Loom
import MirageKit
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
    /// Last completed disconnect reason from the host or local client lifecycle.
    public internal(set) var lastDisconnectReason: String?
    /// Current host authorization/trust evaluation state.
    public internal(set) var authorizationState: AuthorizationState = .idle
    /// Whether the host connection is awaiting explicit manual approval.
    public var isAwaitingManualApproval: Bool {
        authorizationState == .awaitingManualApproval
    }

    /// Available windows on the connected host
    public internal(set) var availableWindows: [MirageWindow] = []

    /// Active stream views
    public internal(set) var activeStreams: [ClientStreamSession] = []

    /// Whether we've received the initial window list from the host
    public internal(set) var hasReceivedWindowList: Bool = false

    /// Current session state of the connected host (locked, unlocked, etc.)
    public internal(set) var hostSessionState: LoomSessionAvailability?
    /// Whether the host currently allows shared clipboard for this connection.
    public internal(set) var sharedClipboardEnabled: Bool = false
    /// Whether the client sends its clipboard to the host before forwarding paste commands.
    public var clientClipboardSharingEnabled: Bool = true
    /// Whether media payload encryption is active for the current host session.
    public internal(set) var mediaPayloadEncryptionEnabled: Bool = true

    /// Current session token from the host (for unlock requests)
    var currentSessionToken: String?

    /// Desktop stream ID (when streaming full virtual display)
    public internal(set) var desktopStreamID: StreamID?

    /// Session identifier for the active desktop stream.
    public internal(set) var desktopSessionID: UUID?

    /// Desktop stream resolution
    public internal(set) var desktopStreamResolution: CGSize?
    /// Desktop stream presentation/window sizing resolution.
    public internal(set) var desktopStreamPresentationResolution: CGSize?
    /// Effective backing scale of the host desktop stream.
    public internal(set) var desktopStreamDisplayScaleFactor: CGFloat?
    /// Effective host capture source for the current desktop stream.
    package internal(set) var desktopCaptureSource: MirageDesktopCaptureSource = .virtualDisplay
    /// Whether the host currently accepts client-driven desktop resize requests.
    public internal(set) var desktopStreamAllowsClientResize: Bool = true

    /// Active codec per stream for codec-specific fallback decisions.
    var activeStreamCodecs: [StreamID: MirageVideoCodec] = [:]

    /// Desktop stream mode (mirrored vs secondary display)
    public internal(set) var desktopStreamMode: MirageDesktopStreamMode?

    /// Effective desktop cursor presentation for the active or pending desktop stream.
    public internal(set) var desktopCursorPresentation: MirageDesktopCursorPresentation?
    /// Last seen desktop dimension token per stream. Used to detect host-side hard resets.
    var desktopDimensionTokenByStream: [StreamID: UInt16] = [:]
    /// Last host-authoritative desktop presentation generation per active session.
    var desktopPresentationGenerationBySessionID: [UUID: UInt64] = [:]
    /// Last seen app/window stream dimension token per stream.
    var appDimensionTokenByStream: [StreamID: UInt16] = [:]
    /// Last app/window stream-start acknowledgement per stream.
    var appStreamStartAcknowledgementByStreamID: [StreamID: StreamStartAcknowledgement] = [:]

    /// Stream scale for post-capture downscaling
    /// 1.0 = native resolution, lower values reduce encoded size
    public var resolutionScale: CGFloat = 1.0

    /// Optional refresh rate override sent to the host.
    public var maxRefreshRateOverride: Int?

    /// Host-authoritative target frame rate observed for active streams.
    var observedFrameRateByStream: [StreamID: Int] = [:]

    /// Preferred low-power policy for local decoder sessions.
    public var decoderLowPowerModePreference: MirageCodecLowPowerModePreference = .auto {
        didSet {
            guard oldValue != decoderLowPowerModePreference else { return }
            scheduleDecoderLowPowerPolicyApply(reason: "preference_change")
        }
    }

    /// Whether battery-based low-power policy is currently supported on this client device.
    public internal(set) var decoderLowPowerSupportsBatteryPolicy: Bool = false

    /// Whether the local decoder is currently using low-power mode.
    public internal(set) var isDecoderLowPowerModeActive: Bool = false

    /// Callback fired when client battery-policy support changes.
    public var onDecoderLowPowerBatteryPolicySupportChanged: ((Bool) -> Void)?

    /// Callback when desktop stream starts
    public var onDesktopStreamStarted: ((StreamID, CGSize, Int) -> Void)?

    /// Callback when desktop stream stops
    public var onDesktopStreamStopped: ((StreamID, DesktopStreamStopReason) -> Void)?

    /// Handler for minimum window size updates from the host
    public var onStreamMinimumSizeUpdate: ((StreamID, CGSize) -> Void)?

    /// Handler for cursor updates from the host
    public var onCursorUpdate: ((StreamID, MirageCursorType, Bool) -> Void)?

    /// Thread-safe cursor position store for desktop cursor sync
    public let cursorPositionStore = MirageClientCursorPositionStore()

    // MARK: - App-Centric Streaming Properties

    /// Available apps on the connected host
    public internal(set) var availableApps: [MirageInstalledApp] = []

    /// Whether we've received the initial app list from the host
    public internal(set) var hasReceivedAppList: Bool = false

    /// Request identifier for the latest app list snapshot received from the host.
    var activeAppListRequestID: UUID?
    /// Bundle identifiers received for the active app-list request.
    var activeAppListReceivedBundleIdentifiers: Set<String> = []
    /// Incremental app-list state keyed by normalized bundle identifier.
    var availableAppsByBundleIdentifier: [String: MirageInstalledApp] = [:]
    /// Stable app-list order for the active app-list request.
    var orderedAvailableAppBundleIdentifiers: [String] = []
    /// Active stream setup request used for scoped cancellation before a stream ID exists.
    var pendingStreamSetupRequestID: UUID?
    var pendingStreamSetupKind: StreamSetupKind?
    var pendingStreamSetupAppSessionID: UUID?
    var customStreamStartedContinuations: [UUID: CheckedContinuation<ClientStreamSession, Error>] = [:]
    /// Custom stream descriptors keyed by active stream ID.
    public internal(set) var customStreamDescriptorsByStreamID: [StreamID: MirageCustomStreamDescriptor] = [:]
    /// Startup-attempt identifiers keyed by stream for explicit ready-ack gating.
    var startupAttemptIDByStream: [StreamID: UUID] = [:]

    /// Policy controlling whether non-essential control updates should be processed.
    public internal(set) var controlUpdatePolicy: ControlUpdatePolicy = .normal
    /// Deferred refresh requirements gathered while non-essential updates are suppressed.
    var deferredControlRefreshRequirements: DeferredControlRefreshRequirements = .none
    /// Whether a connection or first-frame startup critical section is active.
    public internal(set) var startupCriticalSectionActive = false
    /// Streams still waiting for the first presented frame while startup is gated.
    var pendingStartupCriticalStreamIDs: Set<StreamID> = []
    /// Delayed release task used after connect when no stream start follows immediately.
    var startupCriticalIdleReleaseTask: Task<Void, Never>?
    let startupCriticalIdleGrace: Duration = .seconds(2)
    /// Callback fired when startup-critical suppression changes.
    public var onStartupCriticalSectionChanged: (@MainActor @Sendable (Bool) -> Void)?
    /// Cursor update/control counters sampled at 1s windows to avoid per-message logging overhead.
    var cursorUpdateMessagesSinceLastSample: UInt64 = 0
    var cursorPositionMessagesSinceLastSample: UInt64 = 0
    var lastCursorControlSampleTime: CFAbsoluteTime = 0
    let cursorControlSampleInterval: CFAbsoluteTime = 1.0
    var streamMetricsMessagesSinceLastSample: UInt64 = 0
    var lastStreamMetricsSampleTime: CFAbsoluteTime = 0
    let streamMetricsSampleInterval: CFAbsoluteTime = 1.0

    /// Currently streaming app's bundle identifier
    public internal(set) var streamingAppBundleID: String?
    /// Latest host-owned inventory for the currently streamed app session.
    public internal(set) var appWindowInventory: AppWindowInventoryMessage?
    /// App-atlas layouts indexed by physical media stream and layout epoch.
    public internal(set) var appAtlasLayoutsByMediaStreamID: [StreamID: [UInt64: MirageAppAtlasLayout]] = [:]

    /// Callback when app list is received
    public var onAppListReceived: (([MirageInstalledApp]) -> Void)?

    /// Callback when metadata-only app-list progress advances the in-memory app snapshot.
    public var onAppListProgress: (([MirageInstalledApp]) -> Void)?

    /// Callback when host hardware icon payload is received.
    public var onHostHardwareIconReceived: ((UUID, Data, String?, String?, String?) -> Void)?

    /// Callback when host wallpaper image data is received.
    public var onHostWallpaperReceived: ((UUID, Data) -> Void)?

    /// Callback when host software update status is received.
    public var onHostSoftwareUpdateStatus: ((HostSoftwareUpdateStatus) -> Void)?

    /// Callback when host software update install result is received.
    public var onHostSoftwareUpdateInstallResult: ((HostSoftwareUpdateInstallResult) -> Void)?

    /// Callback when a host application restart request completes.
    public var onHostApplicationRestartResult: ((HostApplicationRestartResult) -> Void)?

    /// Callback when a protocol mismatch rejection includes deterministic mismatch metadata.
    public var onProtocolMismatch: ((ProtocolMismatchInfo) -> Void)?

    /// Callback when app streaming starts
    public var onAppStreamStarted: ((AppStreamStartedMessage) -> Void)?

    /// Callback when an app stream fails before any initial window becomes active.
    public var onAppStreamStartupFailed: ((AppStreamStartupFailure) -> Void)?

    /// Callback when a generic custom stream starts.
    public var onCustomStreamStarted: ((MirageCustomStreamStartedMessage) -> Void)?

    /// Callback when a generic custom stream stops.
    public var onCustomStreamStopped: ((MirageCustomStreamStoppedMessage) -> Void)?

    /// Callback when host publishes app-window slot inventory updates.
    public var onAppWindowInventoryUpdate: ((AppWindowInventoryMessage) -> Void)?

    /// Callback when a new window is added to app stream
    public var onWindowAddedToStream: ((WindowAddedToStreamMessage) -> Void)?

    /// Callback when a requested slot swap succeeds or fails.
    public var onAppWindowSwapResult: ((AppWindowSwapResultMessage) -> Void)?

    /// Callback when host close is blocked by an alert after a client window close request.
    public var onAppWindowCloseBlockedAlert: ((AppWindowCloseBlockedAlertMessage) -> Void)?

    /// Callback for host close-alert action execution results.
    public var onAppWindowCloseAlertActionResult: ((AppWindowCloseAlertActionResultMessage) -> Void)?

    /// Callback when a window is removed from app streaming.
    public var onWindowRemovedFromStream: ((WindowRemovedFromStreamMessage) -> Void)?

    /// Callback when host fails to start streaming a candidate window.
    public var onWindowStreamFailed: ((WindowStreamFailedMessage) -> Void)?

    /// Callback when app terminates
    public var onAppTerminated: ((AppTerminatedMessage) -> Void)?

    // MARK: - Menu Bar Passthrough Properties

    /// Callback when menu bar structure is received from host
    public var onMenuBarUpdate: ((StreamID, MirageMenuBar?) -> Void)?

    /// Callback when the host requests a status-overlay change on the client.
    public var onRemoteClientStreamStatusOverlayCommand: ((Bool) -> Void)?

    /// Callback when the host requests a stream-options display-mode change on the client.
    public var onRemoteClientStreamOptionsDisplayModeCommand: ((MirageStreamOptionsDisplayMode) -> Void)?

    /// Callback when the host requests a desktop cursor presentation change on the client.
    public var onRemoteClientDesktopCursorPresentationCommand: ((MirageDesktopCursorPresentation) -> Void)?

    /// Callback when the host requests a desktop cursor lock mode change on the client.
    public var onRemoteClientDesktopCursorLockModeCommand: ((MirageDesktopCursorLockMode) -> Void)?

    /// Callback when the host requests the client stop a specific app stream.
    public var onRemoteClientStopAppStreamCommand: ((String) -> Void)?

    /// Callback when the host requests the client stop its active desktop stream.
    public var onRemoteClientStopDesktopStreamCommand: (() -> Void)?

    /// Client delegate for events
    public weak var delegate: MirageClientDelegate?

    /// Called once per trusted host identity when auto-trust grants access.
    public var onAutoTrustNotice: ((String) -> Void)?

    /// iCloud user record ID to send during connection handshake.
    /// Set this before calling connect(to:) to enable iCloud-based auto-trust.
    public var iCloudUserID: String?

    /// Extra metadata to include in the client's peer advertisement.
    /// Set key-value pairs before calling connect(to:) so the host receives them during handshake.
    public var additionalAdvertisementMetadata: [String: String] = [:]

    /// Identity manager used for Loom authenticated sessions.
    public var identityManager: LoomIdentityManager? {
        didSet {
            loomNode.identityManager = identityManager
        }
    }

    /// Expected host key ID from discovery metadata, if available.
    var expectedHostIdentityKeyID: String?

    /// Last host identity key ID validated by Loom session bootstrap.
    public internal(set) var connectedHostIdentityKeyID: String?

    /// Canonical connected-host identity and aliases validated by bootstrap.
    public internal(set) var connectedHostIdentity: MirageConnectedHostIdentity?

    /// Whether the connected host explicitly allows this client to use host-published off-LAN reachability.
    public internal(set) var connectedHostAllowsRemoteAccess: Bool?

    /// Session store for UI state and stream coordination.
    public let sessionStore: MirageClientSessionStore
    /// Durable desktop resize state shared across SwiftUI view lifecycles.
    let desktopResizeCoordinator = DesktopResizeCoordinator()
    /// Metrics store for stream telemetry (decoupled from SwiftUI).
    public let metricsStore = MirageClientMetricsStore()
    /// Cursor store for pointer updates (decoupled from SwiftUI).
    public let cursorStore = MirageClientCursorStore()
    /// Sender that serializes input events onto the active control channel.
    public nonisolated let inputEventSender = MirageInputEventSender()
    nonisolated let fastPathState = MirageClientFastPathState()

    /// Loom node used for discovery, authenticated control sessions, and media streams.
    public let loomNode: LoomNode
    /// Local network path monitor used to label connection candidates and diagnose path changes.
    let localNetworkMonitor = MirageLocalNetworkMonitor(label: "client")
    /// Loom network configuration used by discovery and outgoing authenticated sessions.
    var networkConfig: LoomNetworkConfiguration
    /// Framed control stream for the active host session.
    var controlChannel: MirageControlChannel?
    /// Active authenticated Loom session, when connected.
    public internal(set) var loomSession: LoomAuthenticatedSession?
    /// Transfer engine attached to the current Loom session for out-of-band payloads.
    @ObservationIgnored var transferEngine: LoomTransferEngine?
    /// Task observing incoming transfer announcements from the active transfer engine.
    @ObservationIgnored var transferObserverTask: Task<Void, Never>?
    /// Incoming transfers retained until the matching request path consumes them.
    var pendingIncomingTransfersByKey: [String: LoomIncomingTransfer] = [:]
    /// Continuations waiting for a transfer announcement keyed by transfer purpose.
    var transferWaitersByKey: [String: CheckedContinuation<LoomIncomingTransfer, Error>] = [:]
    /// Task mirroring Loom control-session state into client connection state.
    @ObservationIgnored var controlSessionStateObserverTask: Task<Void, Never>?
    /// Task mirroring Loom path changes into network path status and history.
    @ObservationIgnored var controlSessionPathObserverTask: Task<Void, Never>?
    /// In-flight transport candidate tasks keyed by connection attempt and candidate identifiers.
    @ObservationIgnored var pendingConnectTasksByAttemptID: [UUID: [UUID: Task<LoomAuthenticatedSession, Error>]] = [:]
    /// Current connection attempt identifier used to ignore late async completions.
    @ObservationIgnored var currentConnectAttemptID: UUID?
    /// Host peer for the active connection.
    public internal(set) var connectedHost: LoomPeer?
    /// Stable device identifier for the client, persisted in UserDefaults.
    public let deviceID: UUID
    let deviceName: String
    var receiveBuffer = Data()
    var isProcessingReceivedData = false
    var hasCompletedBootstrap = false
    var mediaSecurityContext: MirageMediaSecurityContext?

    var controlMessageHandlers: [ControlMessageType: ControlMessageHandler] = [:]
    @ObservationIgnored var sharedClipboardBridge: MirageClientSharedClipboardBridge?
    @ObservationIgnored var clipboardChunkBuffer = MirageSharedClipboardChunkBuffer()
    /// Current local network path kind observed by the client monitor.
    public var currentLocalPathKind: MirageNetworkPathKind {
        localNetworkMonitor.snapshot.currentPathKind
    }

    /// Current network path kind used by the active control session.
    public var currentControlPathKind: MirageNetworkPathKind? {
        controlPathSnapshot?.kind
    }

    /// Current control-session path status exposed to app UI.
    public var currentControlPathStatus: MirageClientNetworkPathStatus? {
        controlPathSnapshot.map { snapshot in
            MirageClientNetworkPathStatus(snapshot: snapshot)
        }
    }

    /// Recent control-session path history entries.
    public internal(set) var controlPathHistory: [MirageClientNetworkPathHistoryEntry] = []

    /// Recent control-session routing attempts included in support diagnostics.
    public internal(set) var recentControlSessionAttemptSummaries: [MirageClientControlSessionAttemptSummary] = []

    var controlPathSnapshot: MirageNetworkPathSnapshot?
    /// Last successful direct host endpoint remembered per device for Bonjour fallback.
    @ObservationIgnored var rememberedDirectEndpointHostByDeviceID: [UUID: NWEndpoint.Host] = [:]
    /// Number of observed control-session path switches onto AWDL.
    var awdlPathSwitches: UInt64 = 0
    /// Count of requested transport refreshes after path or stall diagnostics.
    var transportRefreshRequests: UInt64 = 0
    /// Count of receiver-side stall events observed during the active session.
    var stallEvents: UInt64 = 0
    /// Current jitter hold applied to smooth receiver playback under transport pressure.
    var activeJitterHoldMs: Int = 0
    /// Runtime frame-rate caps applied by workload safety by stream.
    var runtimeWorkloadSafetyFrameRateCapsByStream: [StreamID: RuntimeWorkloadSafetyFrameRateCap] = [:]
    /// Target frame rates restored when temporary workload-safety caps expire.
    var runtimeWorkloadSafetyRestoreFrameRatesByStream: [StreamID: Int] = [:]
    /// Scheduled restore tasks for temporary workload-safety caps.
    @ObservationIgnored var runtimeWorkloadSafetyFrameRateRestoreTasksByStream: [StreamID: Task<Void, Never>] = [:]
    /// Last runtime workload safety fallback reason shown to diagnostics/UI.
    var runtimeWorkloadSafetyLastFallbackReason: String?
    /// Number of memory-pressure events that affected runtime workload safety.
    var runtimeWorkloadSafetyMemoryPressureCount: Int = 0
    /// Wall-clock time of the most recent workload safety memory-pressure event.
    var runtimeWorkloadSafetyLastMemoryPressureTime: CFAbsoluteTime?
    /// Session-scoped stream scale applied by runtime workload safety.
    var runtimeWorkloadSafetyScaleByStream: [StreamID: CGFloat] = [:]
    /// Recent stall timestamps by stream for runtime workload safety decisions.
    var runtimeWorkloadSafetyStallTimesByStream: [StreamID: [CFAbsoluteTime]] = [:]
    /// Last time AWDL telemetry was logged, used to rate-limit diagnostics.
    var lastAwdlTelemetryLogTime: CFAbsoluteTime = 0
    /// Session-local AWDL route suppressions applied after active-stream media degradation.
    var awdlProximityRouteSuppressions: [AwdlProximityRouteSuppressionKey: CFAbsoluteTime] = [:]
    /// User-selected preferred network type for connection racing.
    public var preferredNetworkType: MiragePreferredNetworkType = .automatic

    /// Whether local Wi-Fi/LAN control attempts should be tried before AWDL proximity attempts.
    public var preferWiFiBeforeAwdlProximity = false
    /// Debug route override used to force one transport/interface for the next connection attempt.
    public var debugRouteOverride: MirageDebugRouteOverride?
    let controlSessionConnectTimeout: Duration = .seconds(30)
    /// Manual trust approval happens before the authenticated control session reaches `.ready`.
    let trustPendingControlSessionConnectTimeout: Duration = .seconds(90)
    /// Manual trust approval requires human response time, so bootstrap must outlive normal network latency budgets.
    let bootstrapResponseTimeout: Duration = .seconds(45)

    /// Task accepting incoming Loom multiplexed media streams.
    @ObservationIgnored var mediaStreamListenerTask: Task<Void, Never>?

    /// Active Loom media streams keyed by transport stream name.
    var activeMediaStreams: [String: LoomMultiplexedStream] = [:]

    /// Per-video-stream receive loops.
    var videoStreamReceiveTasks: [StreamID: Task<Void, Never>] = [:]

    /// Per-video-stream hot-path packet ingress processors.
    var videoPacketIngressProcessors: [StreamID: ClientVideoPacketIngressProcessor] = [:]

    /// Thread-safe latest ingress telemetry readable from stream-controller actors.
    nonisolated let videoIngressTelemetryStore = ClientVideoIngressTelemetryStore()

    /// Last cumulative ingress drop count observed per stream for per-window health decisions.
    var videoIngressLastDropCountByStream: [StreamID: UInt64] = [:]

    /// Receive loop for the current audio media stream.
    var audioStreamReceiveTask: Task<Void, Never>?

    /// Receive loops for quality-test media streams keyed by test ID.
    var qualityTestStreamReceiveTasks: [UUID: Task<Void, Never>] = [:]

    /// Stream ID currently registered for host audio playback.
    var audioRegisteredStreamID: StreamID?

    /// Latest audio stream-start message received from the host.
    var activeAudioStreamMessage: AudioStreamStartedMessage?

    /// Generation counter for host audio configuration changes.
    var audioStreamConfigurationGeneration: UInt64 = 0

    /// Decoded PCM frames waiting for playback, keyed by source stream ID.
    var pendingDecodedAudioFramesByStreamID: [StreamID: [DecodedPCMFrame]] = [:]

    /// Pending decoded audio duration by source stream ID.
    var pendingDecodedAudioDurationByStreamID: [StreamID: Double] = [:]

    /// Maximum decoded audio duration retained before trimming.
    let maxPendingDecodedAudioDuration: Double = 0.5

    /// Number of audio frames dropped to keep audio/video sync.
    var audioSyncDropCount: UInt64 = 0

    /// Video stream IDs currently gating audio startup.
    var audioVideoGateActiveStreamIDs: Set<StreamID> = []

    /// Last log time for audio sync drop diagnostics.
    var lastAudioSyncDropLogTime: CFAbsoluteTime = 0

    /// Last log time for audio-ahead diagnostics.
    var lastAudioSyncAheadLogTime: CFAbsoluteTime = 0

    /// Audio decode pipeline shared with the packet ingress queue.
    nonisolated let audioDecodePipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)

    /// Serial ingress queue that decodes audio packets off the main actor.
    nonisolated let audioPacketIngressQueue: ClientAudioPacketIngressQueue

    /// Lazily initialized playback controller storage.
    @ObservationIgnored var audioPlaybackControllerIfInitialized: AudioPlaybackController?

    /// Audio playback controller, created on first access when audio streaming needs playback state.
    @ObservationIgnored public var audioPlaybackController: AudioPlaybackController {
        if let audioPlaybackControllerIfInitialized {
            return audioPlaybackControllerIfInitialized
        }
        let playbackController = AudioPlaybackController()
        audioPlaybackControllerIfInitialized = playbackController
        return playbackController
    }

    /// Audio streaming configuration negotiated for future and active streams.
    public var audioConfiguration: MirageAudioConfiguration = .default {
        didSet {
            guard oldValue != audioConfiguration else { return }
            if !audioConfiguration.enabled { stopAudioConnection() }
        }
    }

    /// Per-stream controllers for decoder, reassembler, and resize lifecycle management.
    var controllersByStream: [StreamID: StreamController] = [:]

    /// Negotiated media packet size limit by stream.
    var mediaMaxPacketSizeByStream: [StreamID: Int] = [:]

    /// Streams already registered with the host for media delivery.
    var registeredStreamIDs: Set<StreamID> = []

    /// Last keyframe request timestamp by stream for cooldown enforcement.
    var lastKeyframeRequestTime: [StreamID: CFAbsoluteTime] = [:]

    /// Last receiver feedback send timestamp by stream.
    var receiverMediaFeedbackLastSendTime: [StreamID: CFAbsoluteTime] = [:]

    /// Last cumulative incomplete-frame timeout counter included in receiver feedback.
    var receiverMediaFeedbackLastIncompleteFrameTimeouts: [StreamID: UInt64] = [:]

    /// Last cumulative forward-gap timeout counter included in receiver feedback.
    var receiverMediaFeedbackLastForwardGapTimeouts: [StreamID: UInt64] = [:]

    /// Last cumulative missing-fragment timeout counter included in receiver feedback.
    var receiverMediaFeedbackLastMissingFragmentTimeouts: [StreamID: UInt64] = [:]

    /// Monotonic sequence for receiver media feedback messages.
    var receiverMediaFeedbackSequence: UInt64 = 0

    /// Minimum spacing between receiver media feedback messages per stream.
    let receiverMediaFeedbackInterval: CFAbsoluteTime = 0.5

    /// Minimum spacing between recovery keyframe requests.
    let keyframeRequestCooldown: CFAbsoluteTime = 0.75

    /// Active retry tasks for recovery keyframe requests.
    var recoveryKeyframeRetryTasks: [StreamID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Delay between recovery keyframe retry attempts.
    let recoveryKeyframeRetryInterval: Duration = .seconds(1)

    /// Maximum number of recovery keyframe retry attempts.
    let recoveryKeyframeRetryLimit: Int = 2

    /// Wall-clock time for the current desktop stream request.
    var desktopStreamRequestStartTime: CFAbsoluteTime = 0

    /// Last desktop start request retained for one bounded restart attempt.
    var lastDesktopStreamStartRequest: StartDesktopStreamMessage?

    /// Number of desktop stream restart attempts for the current request.
    var desktopStreamRestartAttempts: Int = 0

    /// Maximum desktop stream restart attempts for startup recovery.
    let desktopStreamRestartLimit: Int = 1

    /// Timeout task for desktop stream startup.
    var desktopStreamStartTimeoutTask: Task<Void, any Error>?

    /// Timeout task for desktop stream stop acknowledgements.
    var desktopStreamStopTimeoutTask: Task<Void, Never>?

    /// Delay that lets host-side desktop resize settle before reconciling the window.
    @ObservationIgnored var desktopResizeWindowSettlingDelay: Duration = .milliseconds(750)

    /// Maximum time to keep post-resize transition UI before clearing it locally.
    @ObservationIgnored var desktopPostResizeTransitionTimeout: Duration = .seconds(10)

    /// Post-resize transition timeout tasks keyed by stream.
    var postResizeTransitionTimeoutTasks: [StreamID: Task<Void, Never>] = [:]

    /// Local desktop stop stream ID awaiting host acknowledgement.
    var pendingLocalDesktopStopStreamID: StreamID?

    /// Local desktop stop session ID awaiting host acknowledgement.
    var pendingLocalDesktopStopSessionID: UUID?

    /// Desktop session IDs that should ignore late host updates.
    var retiredDesktopSessionIDs: Set<UUID> = []

    /// Streams waiting for host app activation recovery after startup.
    var pendingApplicationActivationRecoveryStreamIDs: Set<StreamID> = []

    /// Timeout for desktop stream stop acknowledgements.
    let desktopStreamStopTimeout: Duration = .seconds(2)

    /// Startup baseline timestamps keyed by stream.
    var streamStartupBaseTimes: [StreamID: CFAbsoluteTime] = [:]

    /// Streams that already sent their first registration packet.
    var streamStartupFirstRegistrationSent: Set<StreamID> = []

    /// Streams that received their first media packet during startup.
    var streamStartupFirstPacketReceived: Set<StreamID> = []

    // MARK: - Quality Test State

    /// Continuation waiting for a quality-test benchmark result from the host.
    var qualityTestBenchmarkContinuation: CheckedContinuation<QualityTestBenchmarkMessage?, Never>?
    /// Continuation waiting for the next quality-test stage completion.
    var qualityTestStageCompletionContinuation: CheckedContinuation<QualityTestStageCompleteMessage?, Never>?
    /// Stage completion messages that arrived before a waiter was installed.
    var qualityTestStageCompletionBuffer: [QualityTestStageCompleteMessage] = []
    /// Quality-test identifier currently awaiting benchmark or stage-completion responses.
    var qualityTestPendingTestID: UUID?
    /// Monotonic waiter token used to invalidate stale benchmark timeouts.
    var qualityTestBenchmarkWaiterID: UInt64 = 0
    /// Monotonic waiter token used to invalidate stale stage-completion timeouts.
    var qualityTestStageCompletionWaiterID: UInt64 = 0
    /// Timeout task for the active quality-test benchmark waiter.
    var qualityTestBenchmarkTimeoutTask: Task<Void, Never>?
    /// Timeout task for the active quality-test stage-completion waiter.
    var qualityTestStageCompletionTimeoutTask: Task<Void, Never>?
    /// Continuation waiting for the host support-log archive URL.
    var hostSupportLogArchiveContinuation: CheckedContinuation<URL, Error>?
    /// Request identifier for the active host support-log archive transfer.
    var hostSupportLogArchiveRequestID: UUID?
    /// Task consuming the active host support-log archive transfer.
    var hostSupportLogArchiveTransferTask: Task<Void, Never>?
    /// Timeout task for host support-log archive transfer setup and delivery.
    var hostSupportLogArchiveTimeoutTask: Task<Void, Never>?
    /// Maximum time to wait for a support-log archive transfer.
    let hostSupportLogArchiveTimeout: Duration = .seconds(45)
    /// Request identifier for the active host wallpaper transfer.
    var hostWallpaperRequestID: UUID?
    /// Continuation waiting for the active host wallpaper payload.
    var hostWallpaperContinuation: CheckedContinuation<Void, Error>?
    /// Timeout task for the active host wallpaper request.
    var hostWallpaperTimeoutTask: Task<Void, Never>?
    /// Maximum time to wait for host wallpaper payload delivery.
    let hostWallpaperTimeout: Duration = .seconds(45)
    /// Ping waiters currently awaiting host pong responses.
    var pingContinuations: [CheckedContinuation<Void, Error>] = []
    /// Monotonic ping request identifier.
    var pingRequestID: UInt64 = 0
    /// Timeout task for active ping waiters.
    var pingTimeoutTask: Task<Void, Never>?

    // MARK: - Heartbeat State

    /// Periodic host heartbeat task and grace deadline for disconnect detection.
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored var heartbeatGraceDeadline: ContinuousClock.Instant?

    /// Retry tasks that request keyframes while a stream startup packet is still pending.
    var startupRegistrationRetryTasks: [StreamID: Task<Void, Never>] = [:]

    /// Interval between startup registration retry requests.
    let startupRegistrationRetryInterval: Duration = .seconds(1)

    /// Maximum startup registration retries before giving up.
    let startupRegistrationRetryLimit: Int = 5

    /// Continuation waiting for the host-assigned stream ID during startup.
    var streamStartedContinuation: CheckedContinuation<StreamID, Error>?

    /// Minimum window sizes per stream received from the host.
    var streamMinSizes: [StreamID: (minWidth: Int, minHeight: Int)] = [:]

    /// Per-stream refresh-rate override state and fallback counters.
    var refreshRateOverridesByStream: [StreamID: Int] = [:]
    var refreshRateMismatchCounts: [StreamID: Int] = [:]
    var refreshRateFallbackTargets: [StreamID: Int] = [:]

    /// Decoder color-depth fallback state used after repeated decode failures.
    var decoderCompatibilityCurrentColorDepthByStream: [StreamID: MirageStreamColorDepth] = [:]
    var decoderCompatibilityBaselineColorDepthByStream: [StreamID: MirageStreamColorDepth] = [:]

    /// Requested color depth and latency modes retained while a stream setup is in flight.
    var pendingRequestedColorDepthByWindowID: [WindowID: MirageStreamColorDepth] = [:]
    var pendingDesktopRequestedColorDepth: MirageStreamColorDepth?
    var pendingAppRequestedColorDepth: MirageStreamColorDepth?
    var pendingDesktopRequestedLatencyMode: MirageStreamLatencyMode?
    var pendingAppRequestedLatencyMode: MirageStreamLatencyMode?
    var pendingStreamSetupLatencyMode: MirageStreamLatencyMode?

    /// Render latency mode currently applied per active stream.
    var renderLatencyModeByStream: [StreamID: MirageStreamLatencyMode] = [:]

    /// Diagnostics context registration token for appending client runtime state to Loom diagnostics.
    @ObservationIgnored nonisolated(unsafe) var diagnosticsContextProviderToken: LoomDiagnosticsContextProviderToken?

    /// Power-state monitor backing decoder low-power policy.
    let decoderPowerStateMonitor = MiragePowerStateMonitor()

    /// Latest power-state snapshot used by decoder low-power policy.
    var decoderPowerStateSnapshot = MiragePowerStateSnapshot(
        isSystemLowPowerModeEnabled: false,
        isOnBattery: nil
    )

    /// Client protocol version used for session bootstrap.
    public static let clientProtocolVersion = Int(MirageKit.protocolVersion)

    /// Creates a client service with optional device, transport, and session-store overrides.
    public init(
        deviceName: String? = nil,
        loomConfiguration: LoomNetworkConfiguration = .default,
        sessionStore: MirageClientSessionStore = MirageClientSessionStore()
    ) {
        #if os(macOS)
        self.deviceName = deviceName ?? Host.current().localizedName ?? "Mac"
        #else
        self.deviceName = deviceName ?? MirageSupportInfo.deviceDisplayName
        #endif

        let resolvedConfiguration = Self.resolvedNetworkConfiguration(from: loomConfiguration)
        networkConfig = resolvedConfiguration
        loomNode = LoomNode(
            configuration: resolvedConfiguration,
            identityManager: MirageKit.identityManager
        )
        self.sessionStore = sessionStore

        let persistedDeviceID = MirageKit.getOrCreateSharedDeviceID(
            suiteName: MirageKit.sharedDeviceIDSuiteName
        )
        deviceID = persistedDeviceID
        MirageLogger.client("Loaded shared device ID: \(persistedDeviceID)")
        audioPacketIngressQueue = ClientAudioPacketIngressQueue(pipeline: audioDecodePipeline)
        configureAudioPacketIngressQueue()
        identityManager = MirageKit.identityManager
        configureSessionStoreCallbacks()
        registerControlMessageHandlers()
        registerDiagnosticsContextProvider()
        configureDecoderLowPowerMonitoring()
    }

    deinit {
        let powerStateMonitor = decoderPowerStateMonitor
        Task { @MainActor in
            powerStateMonitor.stop()
        }
        guard let diagnosticsContextProviderToken else { return }
        Task {
            await LoomDiagnostics.unregisterContextProvider(diagnosticsContextProviderToken)
        }
    }
}
