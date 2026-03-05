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
import MirageKit

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
    public enum ControlTransport: Sendable {
        case tcp
        case quic
    }

    public enum ControlUpdatePolicy: Sendable {
        case normal
        case interactiveStreaming
    }

    public struct DeferredControlRefreshRequirements: Sendable {
        public var needsAppListRefresh: Bool
        public var needsWindowListRefresh: Bool
        public var needsHostSoftwareUpdateRefresh: Bool

        public static let none = DeferredControlRefreshRequirements(
            needsAppListRefresh: false,
            needsWindowListRefresh: false,
            needsHostSoftwareUpdateRefresh: false
        )

        public var hasAny: Bool {
            needsAppListRefresh || needsWindowListRefresh || needsHostSoftwareUpdateRefresh
        }
    }

    public enum AdaptiveFallbackMode: Equatable, Sendable {
        case disabled
        case automatic
        case customTemporary
    }

    public enum StreamStopOrigin: Sendable {
        case clientWindowClosed
    }

    public enum HostSoftwareUpdateChannel: String, Sendable, Codable {
        case release
        case nightly
    }

    public enum HostSoftwareUpdateAutomationMode: String, Sendable, Codable {
        case metadataOnly
        case autoDownload
        case autoInstall
    }

    public enum HostSoftwareUpdateInstallDisposition: String, Sendable, Codable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case installing
        case completed
        case blocked
        case failed
    }

    public enum HostSoftwareUpdateBlockReason: String, Sendable, Codable {
        case clientUpdatesDisabled
        case hostUpdaterBusy
        case unattendedInstallUnsupported
        case insufficientPermissions
        case authorizationRequired
        case serviceUnavailable
        case policyDenied
        case unknown
    }

    public enum HostSoftwareUpdateInstallResultCode: String, Sendable, Codable {
        case started
        case alreadyInProgress
        case noUpdateAvailable
        case denied
        case blocked
        case failed
        case unavailable
    }

    public enum HostSoftwareUpdateReleaseNotesFormat: String, Sendable, Codable {
        case plainText
        case html
    }

    public enum HostSoftwareUpdateInstallTrigger: String, Sendable, Codable {
        case manual
        case protocolMismatch
    }

    public struct HostSoftwareUpdateStatus: Sendable, Equatable, Codable {
        public let isSparkleAvailable: Bool
        public let isCheckingForUpdates: Bool
        public let isInstallInProgress: Bool
        public let channel: HostSoftwareUpdateChannel
        public let automationMode: HostSoftwareUpdateAutomationMode?
        public let installDisposition: HostSoftwareUpdateInstallDisposition?
        public let lastBlockReason: HostSoftwareUpdateBlockReason?
        public let lastInstallResultCode: HostSoftwareUpdateInstallResultCode?
        public let currentVersion: String
        public let availableVersion: String?
        public let availableVersionTitle: String?
        public let releaseNotesSummary: String?
        public let releaseNotesBody: String?
        public let releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?
        public let lastCheckedAtMs: Int64?

        public init(
            isSparkleAvailable: Bool,
            isCheckingForUpdates: Bool,
            isInstallInProgress: Bool,
            channel: HostSoftwareUpdateChannel,
            automationMode: HostSoftwareUpdateAutomationMode?,
            installDisposition: HostSoftwareUpdateInstallDisposition?,
            lastBlockReason: HostSoftwareUpdateBlockReason?,
            lastInstallResultCode: HostSoftwareUpdateInstallResultCode?,
            currentVersion: String,
            availableVersion: String?,
            availableVersionTitle: String?,
            releaseNotesSummary: String?,
            releaseNotesBody: String?,
            releaseNotesFormat: HostSoftwareUpdateReleaseNotesFormat?,
            lastCheckedAtMs: Int64?
        ) {
            self.isSparkleAvailable = isSparkleAvailable
            self.isCheckingForUpdates = isCheckingForUpdates
            self.isInstallInProgress = isInstallInProgress
            self.channel = channel
            self.automationMode = automationMode
            self.installDisposition = installDisposition
            self.lastBlockReason = lastBlockReason
            self.lastInstallResultCode = lastInstallResultCode
            self.currentVersion = currentVersion
            self.availableVersion = availableVersion
            self.availableVersionTitle = availableVersionTitle
            self.releaseNotesSummary = releaseNotesSummary
            self.releaseNotesBody = releaseNotesBody
            self.releaseNotesFormat = releaseNotesFormat
            self.lastCheckedAtMs = lastCheckedAtMs
        }
    }

    public struct HostSoftwareUpdateInstallResult: Sendable, Equatable, Codable {
        public let accepted: Bool
        public let message: String
        public let resultCode: HostSoftwareUpdateInstallResultCode?
        public let blockReason: HostSoftwareUpdateBlockReason?
        public let remediationHint: String?
        public let status: HostSoftwareUpdateStatus?

        public init(
            accepted: Bool,
            message: String,
            resultCode: HostSoftwareUpdateInstallResultCode?,
            blockReason: HostSoftwareUpdateBlockReason?,
            remediationHint: String?,
            status: HostSoftwareUpdateStatus?
        ) {
            self.accepted = accepted
            self.message = message
            self.resultCode = resultCode
            self.blockReason = blockReason
            self.remediationHint = remediationHint
            self.status = status
        }
    }

    public struct ProtocolMismatchInfo: Sendable, Equatable, Codable {
        public enum Reason: String, Sendable, Codable {
            case protocolVersionMismatch
            case protocolFeaturesMismatch
            case hostBusy
            case rejected
            case unauthorized
            case unknown
        }

        public let reason: Reason
        public let hostProtocolVersion: Int?
        public let clientProtocolVersion: Int?
        public let hostUpdateTriggerAccepted: Bool?
        public let hostUpdateTriggerMessage: String?

        public init(
            reason: Reason,
            hostProtocolVersion: Int?,
            clientProtocolVersion: Int?,
            hostUpdateTriggerAccepted: Bool?,
            hostUpdateTriggerMessage: String?
        ) {
            self.reason = reason
            self.hostProtocolVersion = hostProtocolVersion
            self.clientProtocolVersion = clientProtocolVersion
            self.hostUpdateTriggerAccepted = hostUpdateTriggerAccepted
            self.hostUpdateTriggerMessage = hostUpdateTriggerMessage
        }
    }

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
    /// Selected protocol features from handshake negotiation.
    var negotiatedFeatures: MirageFeatureSet = []
    /// Whether media payload encryption is active for the current host session.
    public internal(set) var mediaPayloadEncryptionEnabled: Bool = true

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
    /// Last seen desktop dimension token per stream. Used to detect host-side hard resets.
    var desktopDimensionTokenByStream: [StreamID: UInt16] = [:]
    /// Last seen app/window stream dimension token per stream.
    var appDimensionTokenByStream: [StreamID: UInt16] = [:]

    /// Stream scale for post-capture downscaling
    /// 1.0 = native resolution, lower values reduce encoded size
    public var resolutionScale: CGFloat = 1.0

    /// Enables automatic stream fallback when decode overload persists.
    public var adaptiveFallbackEnabled: Bool = true
    public var adaptiveFallbackMode: AdaptiveFallbackMode = .automatic
    /// Policy lock for decode-storm signaling without automatic quality mutation.
    let adaptiveFallbackMutationsEnabled: Bool = false

    /// Optional refresh rate override sent to the host.
    public var maxRefreshRateOverride: Int?

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

    /// Thread-safe cursor position store for secondary display cursor sync
    public let cursorPositionStore = MirageClientCursorPositionStore()

    /// Callback for content bounds updates (when menus, sheets appear on virtual display)
    public var onContentBoundsUpdate: ((StreamID, CGRect) -> Void)?

    // MARK: - App-Centric Streaming Properties

    /// Available apps on the connected host
    public internal(set) var availableApps: [MirageInstalledApp] = []

    /// Whether we've received the initial app list from the host
    public internal(set) var hasReceivedAppList: Bool = false

    /// Request identifier for the latest app list snapshot received from the host.
    var activeAppListRequestID: UUID?

    /// App-icon stream state keyed by app-list request identifier.
    var appIconStreamStateByRequestID: [UUID: AppIconStreamState] = [:]

    /// Whether the next app-list request should force a full icon reset on host.
    var pendingForceIconResetForNextAppListRequest: Bool = false

    /// Policy controlling whether non-essential control updates should be processed.
    public private(set) var controlUpdatePolicy: ControlUpdatePolicy = .normal
    /// Number of app-icon updates dropped while interactive-stream policy is active.
    var droppedAppIconUpdateMessagesWhileSuppressed: Int = 0
    /// Deferred refresh requirements gathered while non-essential updates are suppressed.
    var deferredControlRefreshRequirements: DeferredControlRefreshRequirements = .none
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

    /// Callback when app list is received
    public var onAppListReceived: (([MirageInstalledApp]) -> Void)?

    /// Callback when host hardware icon payload is received.
    public var onHostHardwareIconReceived: ((UUID, Data, String?, String?, String?) -> Void)?

    /// Callback when host software update status is received.
    public var onHostSoftwareUpdateStatus: ((HostSoftwareUpdateStatus) -> Void)?

    /// Callback when host software update install result is received.
    public var onHostSoftwareUpdateInstallResult: ((HostSoftwareUpdateInstallResult) -> Void)?

    /// Callback when a protocol mismatch rejection includes deterministic mismatch metadata.
    public var onProtocolMismatch: ((ProtocolMismatchInfo) -> Void)?

    /// Callback when app streaming starts
    public var onAppStreamStarted: ((String, String, [AppStreamStartedMessage.AppStreamWindow]) -> Void)?

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

    struct AppIconStreamState {
        var receivedBundleIdentifiers: Set<String> = []
        var skippedBundleIdentifiers: Set<String> = []
    }

    // MARK: - Menu Bar Passthrough Properties

    /// Callback when menu bar structure is received from host
    public var onMenuBarUpdate: ((StreamID, MirageMenuBar?) -> Void)?

    /// Callback when menu action result is received
    public var onMenuActionResult: ((StreamID, Bool, String?) -> Void)?

    /// Client delegate for events
    public weak var delegate: MirageClientDelegate?

    /// Called once per trusted host identity when auto-trust grants access.
    public var onAutoTrustNotice: ((String) -> Void)?

    /// iCloud user record ID to send during connection handshake.
    /// Set this before calling connect(to:) to enable iCloud-based auto-trust.
    public var iCloudUserID: String?

    /// Identity manager used for signed handshake envelopes.
    public var identityManager: MirageIdentityManager?

    /// Expected host key ID from discovery metadata, if available.
    var expectedHostIdentityKeyID: String?

    /// Last host identity key ID validated by hello response.
    public internal(set) var connectedHostIdentityKeyID: String?

    /// Replay protection for signed hello responses.
    let handshakeReplayProtector = MirageReplayProtector()

    /// Session store for UI state and stream coordination.
    public let sessionStore: MirageClientSessionStore
    /// Metrics store for stream telemetry (decoupled from SwiftUI).
    public let metricsStore = MirageClientMetricsStore()
    /// Cursor store for pointer updates (decoupled from SwiftUI).
    public let cursorStore = MirageClientCursorStore()
    nonisolated let inputEventSender = MirageInputEventSender()

    var networkConfig: MirageNetworkConfiguration
    var connection: NWConnection?
    var connectedHost: MirageHost?
    /// Stable device identifier for the client, persisted in UserDefaults.
    public let deviceID: UUID
    let deviceName: String
    var receiveBuffer = Data()
    var approvalWaitTask: Task<Void, Never>?
    var hasReceivedHelloResponse = false
    var pendingHelloNonce: String?
    var mediaSecurityContext: MirageMediaSecurityContext?
    let mediaSecurityContextLock = NSLock()
    nonisolated(unsafe) var mediaSecurityContextStorage: MirageMediaSecurityContext?
    nonisolated(unsafe) var mediaSecurityPacketKeyStorage: MirageMediaPacketKey?
    typealias ControlMessageHandler = @MainActor (ControlMessage) async -> Void
    var controlMessageHandlers: [ControlMessageType: ControlMessageHandler] = [:]
    let awdlExperimentEnabled: Bool = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    var controlPathSnapshot: MirageNetworkPathSnapshot?
    var videoPathSnapshot: MirageNetworkPathSnapshot?
    var audioPathSnapshot: MirageNetworkPathSnapshot?
    var awdlPathSwitches: UInt64 = 0
    var registrationRefreshCount: UInt64 = 0
    var transportRefreshRequests: UInt64 = 0
    var stallEvents: UInt64 = 0
    var activeJitterHoldMs: Int = 0
    var lastAwdlTelemetryLogTime: CFAbsoluteTime = 0
    var registrationRefreshTask: Task<Void, Never>?
    let registrationRefreshIntervalMs: UInt64 = 750
    let registrationRefreshJitterMs: UInt64 = 80

    // Video receiving
    var udpConnection: NWConnection?
    var hostDataPort: UInt16 = 0
    var mediaTransportHost: NWEndpoint.Host?
    var mediaTransportIncludePeerToPeer: Bool?
    let mediaTransportConnectTimeout: Duration = .seconds(1)

    // Audio receiving (dedicated low-priority UDP connection)
    var audioConnection: NWConnection?
    var audioRegisteredStreamID: StreamID?
    var activeAudioStreamMessage: AudioStreamStartedMessage?
    nonisolated let audioDecodePipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)
    /// Thread-safe active audio stream ID for nonisolated UDP packet filtering.
    let activeAudioStreamIDLock = NSLock()
    nonisolated(unsafe) var activeAudioStreamIDStorage: StreamID?
    /// Thread-safe preferred decode channel count for off-main audio decode.
    let audioDecodeTargetChannelLock = NSLock()
    nonisolated(unsafe) var audioDecodeTargetChannelCountStorage: Int = 2
    @ObservationIgnored let audioPlaybackController = AudioPlaybackController()
    public var audioConfiguration: MirageAudioConfiguration = .default {
        didSet {
            guard oldValue != audioConfiguration else { return }
            if !audioConfiguration.enabled { stopAudioConnection() }
        }
    }

    /// Per-stream controllers for lifecycle management
    /// StreamController owns decoder, reassembler, and resize state machine
    var controllersByStream: [StreamID: StreamController] = [:]

    // Track which streams have been registered with the host (prevents duplicate registrations)
    var registeredStreamIDs: Set<StreamID> = []
    var lastKeyframeRequestTime: [StreamID: CFAbsoluteTime] = [:]
    let keyframeRequestCooldown: CFAbsoluteTime = 0.75
    var lastDisplayResolutionRequestByStream: [StreamID: CGSize] = [:]
    var lastDisplayResolutionRequestTimeByStream: [StreamID: CFAbsoluteTime] = [:]
    let duplicateDisplayResolutionSuppressionWindow: CFAbsoluteTime = 0.2
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

    /// Thread-safe active audio stream ID for UDP packet filtering from nonisolated callbacks.
    nonisolated var activeAudioStreamIDForFiltering: StreamID? {
        activeAudioStreamIDLock.lock()
        defer { activeAudioStreamIDLock.unlock() }
        return activeAudioStreamIDStorage
    }

    /// Thread-safe target channel count for off-main audio decode.
    nonisolated var audioDecodeTargetChannelCountForPipeline: Int {
        audioDecodeTargetChannelLock.lock()
        defer { audioDecodeTargetChannelLock.unlock() }
        return max(1, audioDecodeTargetChannelCountStorage)
    }

    /// Thread-safe set of streams awaiting a first-packet startup log.
    let startupPacketPendingLock = NSLock()
    nonisolated(unsafe) var startupPacketPendingStorage: Set<StreamID> = []
    var startupRegistrationRetryTasks: [StreamID: Task<Void, Never>] = [:]
    let startupRegistrationRetryInterval: Duration = .seconds(1)
    let startupRegistrationRetryLimit: Int = 5

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

    func setActiveAudioStreamIDForFiltering(_ streamID: StreamID?) {
        activeAudioStreamIDLock.lock()
        activeAudioStreamIDStorage = streamID
        activeAudioStreamIDLock.unlock()
    }

    func setAudioDecodeTargetChannelCountForPipeline(_ count: Int) {
        audioDecodeTargetChannelLock.lock()
        audioDecodeTargetChannelCountStorage = max(1, count)
        audioDecodeTargetChannelLock.unlock()
    }

    nonisolated var mediaSecurityContextForNetworking: MirageMediaSecurityContext? {
        mediaSecurityContextLock.lock()
        defer { mediaSecurityContextLock.unlock() }
        return mediaSecurityContextStorage
    }

    nonisolated var mediaSecurityPacketKeyForNetworking: MirageMediaPacketKey? {
        mediaSecurityContextLock.lock()
        defer { mediaSecurityContextLock.unlock() }
        return mediaSecurityPacketKeyStorage
    }

    func setMediaSecurityContext(_ context: MirageMediaSecurityContext?) {
        mediaSecurityContext = context
        mediaSecurityContextLock.lock()
        mediaSecurityContextStorage = context
        mediaSecurityPacketKeyStorage = context.map { MirageMediaSecurity.makePacketKey(context: $0) }
        mediaSecurityContextLock.unlock()
    }

    func startStartupRegistrationRetry(streamID: StreamID) {
        startupRegistrationRetryTasks[streamID]?.cancel()
        startupRegistrationRetryTasks[streamID] = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, attempt < self.startupRegistrationRetryLimit {
                try? await Task.sleep(for: self.startupRegistrationRetryInterval)
                if Task.isCancelled { return }
                if !self.isStartupPacketPending(streamID) { return }
                attempt += 1
                MirageLogger.client(
                    "Startup packet pending for stream \(streamID); resending registration (\(attempt)/\(self.startupRegistrationRetryLimit))"
                )
                do {
                    if self.udpConnection == nil { try await self.startVideoConnection() }
                    try await self.sendStreamRegistration(streamID: streamID)
                    self.sendKeyframeRequest(for: streamID)
                } catch {
                    MirageLogger.error(.client, error: error, message: "Startup registration retry failed: ")
                }
            }
        }
    }

    func cancelStartupRegistrationRetry(streamID: StreamID) {
        if let task = startupRegistrationRetryTasks.removeValue(forKey: streamID) {
            task.cancel()
        }
    }

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

    var adaptiveFallbackBitrateByStream: [StreamID: Int] = [:]
    var adaptiveFallbackBaselineBitrateByStream: [StreamID: Int] = [:]
    var adaptiveFallbackBitDepthByStream: [StreamID: MirageVideoBitDepth] = [:]
    var adaptiveFallbackBaselineBitDepthByStream: [StreamID: MirageVideoBitDepth] = [:]
    var adaptiveFallbackCollapseTimestampsByStream: [StreamID: [CFAbsoluteTime]] = [:]
    var adaptiveFallbackPressureCountByStream: [StreamID: Int] = [:]
    var adaptiveFallbackLastPressureTriggerTimeByStream: [StreamID: CFAbsoluteTime] = [:]
    var adaptiveFallbackStableSinceByStream: [StreamID: CFAbsoluteTime] = [:]
    var adaptiveFallbackLastRestoreTimeByStream: [StreamID: CFAbsoluteTime] = [:]
    var adaptiveFallbackLastCollapseTimeByStream: [StreamID: CFAbsoluteTime] = [:]
    var adaptiveFallbackLastAppliedTime: [StreamID: CFAbsoluteTime] = [:]
    var pendingAdaptiveFallbackBitrateByWindowID: [WindowID: Int] = [:]
    var pendingAdaptiveFallbackBitDepthByWindowID: [WindowID: MirageVideoBitDepth] = [:]
    var pendingDesktopAdaptiveFallbackBitrate: Int?
    var pendingDesktopAdaptiveFallbackBitDepth: MirageVideoBitDepth?
    var pendingAppAdaptiveFallbackBitrate: Int?
    var pendingAppAdaptiveFallbackBitDepth: MirageVideoBitDepth?
    let adaptiveFallbackCooldown: CFAbsoluteTime = 15.0
    let customAdaptiveFallbackCollapseWindow: CFAbsoluteTime = 20.0
    let customAdaptiveFallbackCollapseThreshold: Int = 2
    let customAdaptiveFallbackRestoreWindow: CFAbsoluteTime = 20.0
    let adaptiveFallbackPressureUnderTargetRatio: Double = 0.90
    let adaptiveFallbackPressureHeadroomFPS: Double = 4.0
    let adaptiveFallbackPressureTriggerCount: Int = 2
    let adaptiveFallbackPressureTriggerCooldown: CFAbsoluteTime = 2.0
    let adaptiveFallbackBitrateStep: Double = 0.85
    let adaptiveRestoreBitrateStep: Double = 1.10
    let adaptiveFallbackBitrateFloorBps: Int = 8_000_000
    nonisolated(unsafe) var diagnosticsContextProviderToken: MirageDiagnosticsContextProviderToken?
    // Internal for low-power policy extension.
    let decoderPowerStateMonitor = MiragePowerStateMonitor()
    var decoderPowerStateSnapshot = MiragePowerStateSnapshot(
        isSystemLowPowerModeEnabled: false,
        isOnBattery: nil
    )

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

    /// Client protocol version used for hello negotiation.
    public static var clientProtocolVersion: Int {
        Int(MirageKit.protocolVersion)
    }

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
        identityManager = MirageIdentityManager.shared
        self.sessionStore.clientService = self
        self.sessionStore.onStreamPresentationTierChanged = { [weak self] streamID, tier in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.applyStreamPresentationTier(tier, to: streamID)
            }
        }
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
            await MirageDiagnostics.unregisterContextProvider(diagnosticsContextProviderToken)
        }
    }

    private func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await MirageDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.makeDiagnosticsContextSnapshot() }
            }
        }
    }

    private func makeDiagnosticsContextSnapshot() -> MirageDiagnosticsContext {
        [
            "client.connectionState": .string(Self.diagnosticsConnectionStateName(connectionState)),
            "client.awaitingManualApproval": .bool(isAwaitingManualApproval),
            "client.mediaPayloadEncryptionEnabled": .bool(mediaPayloadEncryptionEnabled),
            "client.availableWindowsCount": .int(availableWindows.count),
            "client.activeStreamsCount": .int(activeStreams.count),
            "client.availableAppsCount": .int(availableApps.count),
            "client.hasReceivedWindowList": .bool(hasReceivedWindowList),
            "client.hasReceivedAppList": .bool(hasReceivedAppList),
            "client.desktopStreamActive": .bool(desktopStreamID != nil),
            "client.loginDisplayStreamActive": .bool(loginDisplayStreamID != nil),
            "client.adaptiveFallbackMode": .string(diagnosticsAdaptiveFallbackModeName(adaptiveFallbackMode)),
            "client.maxRefreshRateOverride": maxRefreshRateOverride.map(MirageDiagnosticsValue.int) ?? .null,
            "client.hostSessionState": hostSessionState.map { .string(String(describing: $0)) } ?? .null
        ]
    }

    private static func diagnosticsConnectionStateName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .error:
            return "error"
        }
    }

    private func diagnosticsAdaptiveFallbackModeName(_ mode: AdaptiveFallbackMode) -> String {
        switch mode {
        case .disabled:
            return "disabled"
        case .automatic:
            return "automatic"
        case .customTemporary:
            return "customTemporary"
        }
    }

    /// Applies runtime network-policy updates used by discovery and hello validation.
    /// Existing connections keep their current transport/path settings until reconnect.
    public func updateNetworkPolicy(
        enablePeerToPeer: Bool,
        requireEncryptedMediaOnLocalNetwork: Bool
    ) {
        guard networkConfig.enablePeerToPeer != enablePeerToPeer ||
            networkConfig.requireEncryptedMediaOnLocalNetwork != requireEncryptedMediaOnLocalNetwork else {
            return
        }

        networkConfig.enablePeerToPeer = enablePeerToPeer
        networkConfig.requireEncryptedMediaOnLocalNetwork = requireEncryptedMediaOnLocalNetwork
        MirageLogger.client(
            "Updated network policy (p2p=\(enablePeerToPeer), localMediaEncryptionRequired=\(requireEncryptedMediaOnLocalNetwork))"
        )
    }

    /// Sets client control-update policy for active-stream workload isolation.
    public func setControlUpdatePolicy(_ policy: ControlUpdatePolicy) {
        guard controlUpdatePolicy != policy else { return }
        controlUpdatePolicy = policy

        guard policy == .normal else { return }
        if droppedAppIconUpdateMessagesWhileSuppressed > 0 {
            MirageLogger.client(
                "Resumed normal control updates after dropping \(droppedAppIconUpdateMessagesWhileSuppressed) app icon updates"
            )
            droppedAppIconUpdateMessagesWhileSuppressed = 0
        }
    }

    /// Consumes and clears deferred control refresh requirements accumulated while policy was suppressed.
    public func consumeDeferredControlRefreshRequirements() -> DeferredControlRefreshRequirements {
        let requirements = deferredControlRefreshRequirements
        deferredControlRefreshRequirements = .none
        return requirements
    }

    #if os(iOS) || os(visionOS)
    /// Cached drawable size from the Metal view.
    public static var lastKnownViewSize: CGSize = .zero
    public static var lastKnownDrawablePixelSize: CGSize = .zero
    /// Cached active screen bounds in points.
    public static var lastKnownScreenPointSize: CGSize = .zero
    /// Cached active screen scale factor.
    public static var lastKnownScreenScale: CGFloat = 0
    /// Cached active screen native pixel size.
    public static var lastKnownScreenNativePixelSize: CGSize = .zero
    /// Cached active screen native scale factor.
    public static var lastKnownScreenNativeScale: CGFloat = 0
    /// Cached max refresh rate from the active screen (for external display support).
    public static var lastKnownScreenMaxFPS: Int = 0
    #endif
}
