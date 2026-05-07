//
//  MessageTypes+AppStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - App-Centric Streaming Messages

public enum MirageStreamRuntimeTier: String, Codable, Sendable {
    case activeLive
    case passiveSnapshot
}

public struct MirageStreamPolicy: Codable, Sendable, Equatable {
    public let streamID: StreamID
    public let tier: MirageStreamRuntimeTier
    public let targetFPS: Int
    public let targetBitrateBps: Int?

    package init(
        streamID: StreamID,
        tier: MirageStreamRuntimeTier,
        targetFPS: Int,
        targetBitrateBps: Int?
    ) {
        self.streamID = streamID
        self.tier = tier
        self.targetFPS = max(1, min(120, targetFPS))
        self.targetBitrateBps = targetBitrateBps
    }
}

public struct StreamPolicyUpdateMessage: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let policies: [MirageStreamPolicy]

    package init(epoch: UInt64, policies: [MirageStreamPolicy]) {
        self.epoch = epoch
        self.policies = policies.sorted { lhs, rhs in
            lhs.streamID < rhs.streamID
        }
    }
}

public struct AppAtlasMediaUpdateMessage: Codable, Sendable, Equatable {
    public let mediaStreamID: StreamID
    public let width: Int
    public let height: Int
    public let codec: MirageVideoCodec
    public let frameRate: Int
    public let dimensionToken: UInt16?
    public let layoutEpoch: UInt64
    public let acceptedPacketSize: Int?
    public let layout: MirageAppAtlasLayout
    public let startupAttemptID: UUID

    package init(
        mediaStreamID: StreamID,
        width: Int,
        height: Int,
        codec: MirageVideoCodec,
        frameRate: Int,
        dimensionToken: UInt16? = nil,
        layoutEpoch: UInt64,
        acceptedPacketSize: Int? = nil,
        layout: MirageAppAtlasLayout,
        startupAttemptID: UUID
    ) {
        self.mediaStreamID = mediaStreamID
        self.width = width
        self.height = height
        self.codec = codec
        self.frameRate = frameRate
        self.dimensionToken = dimensionToken
        self.layoutEpoch = layoutEpoch
        self.acceptedPacketSize = acceptedPacketSize
        self.layout = layout
        self.startupAttemptID = startupAttemptID
    }
}

/// Request for list of installed apps (Client → Host)
package struct AppListRequestMessage: Codable {
    /// Whether host-side app-list caches should be bypassed for this request
    package let forceRefresh: Bool
    /// Whether host should ignore client icon-presence hints and resend all icon payloads.
    package let forceIconReset: Bool
    /// Preferred icon-priority ordering from the client (pinned/recent first).
    package let priorityBundleIdentifiers: [String]
    /// Bundle identifiers whose icon payloads the client has already persisted.
    package let knownIconBundleIdentifiers: [String]
    /// Client-generated request identifier for correlating metadata + icon updates.
    package let requestID: UUID

    package init(
        forceRefresh: Bool = false,
        forceIconReset: Bool = false,
        priorityBundleIdentifiers: [String] = [],
        knownIconBundleIdentifiers: [String] = [],
        requestID: UUID = UUID()
    ) {
        self.forceRefresh = forceRefresh
        self.forceIconReset = forceIconReset
        self.priorityBundleIdentifiers = priorityBundleIdentifiers
        self.knownIconBundleIdentifiers = Self.normalizedBundleIdentifiers(knownIconBundleIdentifiers)
        self.requestID = requestID
    }

    private static func normalizedBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var normalizedBundleIdentifiers: [String] = []
        normalizedBundleIdentifiers.reserveCapacity(bundleIdentifiers.count)

        for bundleIdentifier in bundleIdentifiers {
            let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedBundleIdentifier.isEmpty, seen.insert(normalizedBundleIdentifier).inserted else {
                continue
            }
            normalizedBundleIdentifiers.append(normalizedBundleIdentifier)
        }

        return normalizedBundleIdentifiers
    }
}

/// Completion marker for an app-list metadata stream (Host -> Client)
package struct AppListCompleteMessage: Codable {
    /// Correlates this completion marker with progress and icon update messages.
    package let requestID: UUID
    /// Total available apps emitted through progress messages for this request.
    package let totalAppCount: Int

    package init(requestID: UUID, totalAppCount: Int) {
        self.requestID = requestID
        self.totalAppCount = max(0, totalAppCount)
    }
}

/// Incremental app-list progress (Host -> Client)
package struct AppListProgressMessage: Codable {
    /// Correlates this progress snapshot with the active app-list request.
    package let requestID: UUID
    /// Newly discovered app details. Icon payloads are included when the client does not already have them.
    package let apps: [MirageInstalledApp]

    package init(requestID: UUID, apps: [MirageInstalledApp]) {
        self.requestID = requestID
        self.apps = apps
    }
}

/// Request to stream an app (Client → Host)
package struct SelectAppMessage: Codable {
    /// Request-scoped identifier used to cancel or reject stale startup work.
    package let startupRequestID: UUID
    /// Host/client app-session identifier for this app-stream startup.
    package let appSessionID: UUID
    /// Bundle identifier of the app to stream
    package let bundleIdentifier: String
    /// Client's data port for video
    package let dataPort: UInt16?
    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int
    /// Client's display scale factor
    package let scaleFactor: CGFloat?
    /// Client's display dimensions
    package let displayWidth: Int?
    package let displayHeight: Int?
    /// Client-requested keyframe interval in frames
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream color depth preset.
    package var colorDepth: MirageStreamColorDepth?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    package let streamScale: CGFloat?
    /// Client audio streaming configuration
    package let audioConfiguration: MirageAudioConfiguration?
    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    package var bitrateAdaptationCeiling: Int?
    /// Maximum encoded width in pixels for host-computed stream scaling.
    package var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels for host-computed stream scaling.
    package var encoderMaxHeight: Int?
    /// Requested media packet size for this stream.
    package var mediaMaxPacketSize: Int?
    /// Client-requested MetalFX upscaling mode.
    package var upscalingMode: MirageUpscalingMode?
    /// Client-requested video codec.
    package var codec: MirageVideoCodec?
    /// Maximum concurrent visible app windows requested by the client tier policy.
    package let maxConcurrentVisibleWindows: Int
    /// Client-requested shared bitrate allocation policy for multi-window app streaming.
    private let bitrateAllocationPolicyRawValue: String?
    /// Client-requested virtual display size preset for app streaming.
    package var sizePreset: MirageDisplaySizePreset?

    package var bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy? {
        guard let bitrateAllocationPolicyRawValue else { return nil }
        return MirageAppStreamBitrateAllocationPolicy(rawValue: bitrateAllocationPolicyRawValue)
    }

    enum CodingKeys: String, CodingKey {
        case startupRequestID
        case appSessionID
        case bundleIdentifier
        case dataPort
        case targetFrameRate
        case scaleFactor
        case displayWidth
        case displayHeight
        case keyFrameInterval
        case captureQueueDepth
        case colorDepth
        case bitrate
        case latencyMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case bitrateAdaptationCeiling
        case encoderMaxWidth
        case encoderMaxHeight
        case mediaMaxPacketSize
        case upscalingMode
        case codec
        case maxConcurrentVisibleWindows
        case bitrateAllocationPolicyRawValue = "bitrateAllocationPolicy"
        case sizePreset
    }

    package init(
        startupRequestID: UUID = UUID(),
        appSessionID: UUID = UUID(),
        bundleIdentifier: String,
        dataPort: UInt16? = nil,
        targetFrameRate: Int,
        scaleFactor: CGFloat? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        maxConcurrentVisibleWindows: Int = 1,
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy? = nil,
        sizePreset: MirageDisplaySizePreset? = nil,
        mediaMaxPacketSize: Int? = nil,
        codec: MirageVideoCodec? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.appSessionID = appSessionID
        self.bundleIdentifier = bundleIdentifier
        self.dataPort = dataPort
        self.targetFrameRate = targetFrameRate
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.maxConcurrentVisibleWindows = max(1, maxConcurrentVisibleWindows)
        self.bitrateAllocationPolicyRawValue = bitrateAllocationPolicy?.rawValue
        self.sizePreset = sizePreset
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.codec = codec
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupRequestID = (try? container.decodeIfPresent(UUID.self, forKey: .startupRequestID)) ?? UUID()
        appSessionID = (try? container.decodeIfPresent(UUID.self, forKey: .appSessionID)) ?? UUID()
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        dataPort = container.decodeLossyIfPresent(UInt16.self, forKey: .dataPort)
        targetFrameRate = container.decodeLossyIfPresent(Int.self, forKey: .targetFrameRate) ?? 60
        scaleFactor = container.decodeLossyIfPresent(CGFloat.self, forKey: .scaleFactor)
        displayWidth = container.decodeLossyIfPresent(Int.self, forKey: .displayWidth)
        displayHeight = container.decodeLossyIfPresent(Int.self, forKey: .displayHeight)
        keyFrameInterval = container.decodeLossyIfPresent(Int.self, forKey: .keyFrameInterval)
        captureQueueDepth = container.decodeLossyIfPresent(Int.self, forKey: .captureQueueDepth)
        colorDepth = container.decodeLossyIfPresent(MirageStreamColorDepth.self, forKey: .colorDepth)
        bitrate = container.decodeLossyIfPresent(Int.self, forKey: .bitrate)
        latencyMode = container.decodeLossyIfPresent(MirageStreamLatencyMode.self, forKey: .latencyMode)
        allowRuntimeQualityAdjustment = container.decodeLossyIfPresent(
            Bool.self,
            forKey: .allowRuntimeQualityAdjustment
        )
        lowLatencyHighResolutionCompressionBoost = container.decodeLossyIfPresent(
            Bool.self,
            forKey: .lowLatencyHighResolutionCompressionBoost
        )
        disableResolutionCap = container.decodeLossyIfPresent(Bool.self, forKey: .disableResolutionCap)
        streamScale = container.decodeLossyIfPresent(CGFloat.self, forKey: .streamScale)
        audioConfiguration = container.decodeLossyIfPresent(
            MirageAudioConfiguration.self,
            forKey: .audioConfiguration
        )
        bitrateAdaptationCeiling = container.decodeLossyIfPresent(Int.self, forKey: .bitrateAdaptationCeiling)
        encoderMaxWidth = container.decodeLossyIfPresent(Int.self, forKey: .encoderMaxWidth)
        encoderMaxHeight = container.decodeLossyIfPresent(Int.self, forKey: .encoderMaxHeight)
        mediaMaxPacketSize = container.decodeLossyIfPresent(Int.self, forKey: .mediaMaxPacketSize)
        upscalingMode = container.decodeLossyIfPresent(MirageUpscalingMode.self, forKey: .upscalingMode)
        codec = container.decodeLossyIfPresent(MirageVideoCodec.self, forKey: .codec)
        maxConcurrentVisibleWindows = max(
            1,
            container.decodeLossyIfPresent(Int.self, forKey: .maxConcurrentVisibleWindows) ?? 1
        )
        bitrateAllocationPolicyRawValue = container.decodeLossyIfPresent(
            String.self,
            forKey: .bitrateAllocationPolicyRawValue
        )
        sizePreset = container.decodeLossyIfPresent(MirageDisplaySizePreset.self, forKey: .sizePreset)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// Confirmation that app streaming has started (Host → Client)
public struct AppStreamStartedMessage: Codable {
    /// Stable app-session identifier for this app stream.
    public let appSessionID: UUID
    /// Startup request that produced this app session.
    public let startupRequestID: UUID?
    /// Bundle identifier of the app being streamed
    public let bundleIdentifier: String
    /// App display name
    public let appName: String
    /// Initial windows that are now streaming
    public let windows: [AppStreamWindow]
    /// Optional atlas layouts for physical media streams carrying logical app-window regions.
    public let atlasLayouts: [MirageAppAtlasLayout]?

    public struct AppStreamWindow: Codable {
        public let streamID: StreamID
        public let mediaStreamID: StreamID
        public let windowID: WindowID
        public let title: String?
        /// Calibrated stream viewport width in points (derived from dedicated virtual-display visible frame).
        public let width: Int
        /// Calibrated stream viewport height in points (derived from dedicated virtual-display visible frame).
        public let height: Int
        public let isResizable: Bool
        public let atlasRegion: MirageAppAtlasRegion?

        package init(
            streamID: StreamID,
            mediaStreamID: StreamID? = nil,
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool,
            atlasRegion: MirageAppAtlasRegion? = nil
        ) {
            self.streamID = streamID
            self.mediaStreamID = mediaStreamID ?? streamID
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
            self.atlasRegion = atlasRegion
        }
    }

    package init(
        appSessionID: UUID,
        startupRequestID: UUID?,
        bundleIdentifier: String,
        appName: String,
        windows: [AppStreamWindow],
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.appSessionID = appSessionID
        self.startupRequestID = startupRequestID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windows = windows
        self.atlasLayouts = atlasLayouts
    }
}

public struct AppWindowInventoryMessage: Codable, Sendable {
    public struct WindowMetadata: Codable, Sendable, Equatable {
        public let windowID: WindowID
        public let title: String?
        public let width: Int
        public let height: Int
        public let isResizable: Bool

        package init(
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool
        ) {
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
        }
    }

    public struct Slot: Codable, Sendable, Equatable {
        public let slotIndex: Int
        public let streamID: StreamID
        public let mediaStreamID: StreamID
        public let window: WindowMetadata
        public let atlasRegion: MirageAppAtlasRegion?

        package init(
            slotIndex: Int,
            streamID: StreamID,
            mediaStreamID: StreamID? = nil,
            window: WindowMetadata,
            atlasRegion: MirageAppAtlasRegion? = nil
        ) {
            self.slotIndex = slotIndex
            self.streamID = streamID
            self.mediaStreamID = mediaStreamID ?? streamID
            self.window = window
            self.atlasRegion = atlasRegion
        }
    }

    public let bundleIdentifier: String
    public let appSessionID: UUID?
    public let maxVisibleSlots: Int
    public let slots: [Slot]
    public let hiddenWindows: [WindowMetadata]
    public let atlasLayouts: [MirageAppAtlasLayout]?

    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        maxVisibleSlots: Int,
        slots: [Slot],
        hiddenWindows: [WindowMetadata],
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.maxVisibleSlots = max(1, maxVisibleSlots)
        self.slots = slots
        self.hiddenWindows = hiddenWindows
        self.atlasLayouts = atlasLayouts
    }

    public func removingWindow(windowID: WindowID) -> AppWindowInventoryMessage? {
        let remainingSlots = slots.filter { $0.window.windowID != windowID }
        let remainingHiddenWindows = hiddenWindows.filter { $0.windowID != windowID }

        guard !remainingSlots.isEmpty || !remainingHiddenWindows.isEmpty else {
            return nil
        }

        let remainingAtlasLayouts = atlasLayouts?.compactMap { layout -> MirageAppAtlasLayout? in
            let remainingRegions = layout.regions.filter { $0.windowID != windowID }
            guard !remainingRegions.isEmpty else { return nil }
            return MirageAppAtlasLayout(
                mediaStreamID: layout.mediaStreamID,
                layoutEpoch: layout.layoutEpoch,
                width: layout.width,
                height: layout.height,
                regions: remainingRegions
            )
        }

        return AppWindowInventoryMessage(
            bundleIdentifier: bundleIdentifier,
            appSessionID: appSessionID,
            maxVisibleSlots: maxVisibleSlots,
            slots: remainingSlots,
            hiddenWindows: remainingHiddenWindows,
            atlasLayouts: remainingAtlasLayouts
        )
    }
}

package struct AppWindowSwapRequestMessage: Codable {
    package let bundleIdentifier: String
    package let targetSlotStreamID: StreamID
    package let targetWindowID: WindowID

    package init(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetSlotStreamID = targetSlotStreamID
        self.targetWindowID = targetWindowID
    }
}

public struct AppWindowSwapResultMessage: Codable, Sendable {
    public let bundleIdentifier: String
    public let targetSlotStreamID: StreamID
    public let mediaStreamID: StreamID
    public let windowID: WindowID
    public let success: Bool
    public let reason: String?
    public let atlasRegion: MirageAppAtlasRegion?
    public let atlasLayouts: [MirageAppAtlasLayout]?

    package init(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        mediaStreamID: StreamID? = nil,
        windowID: WindowID,
        success: Bool,
        reason: String?,
        atlasRegion: MirageAppAtlasRegion? = nil,
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetSlotStreamID = targetSlotStreamID
        self.mediaStreamID = mediaStreamID ?? targetSlotStreamID
        self.windowID = windowID
        self.success = success
        self.reason = reason
        self.atlasRegion = atlasRegion
        self.atlasLayouts = atlasLayouts
    }
}

public struct AppWindowCloseBlockedAlertMessage: Codable, Sendable, Equatable {
    public struct Action: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let isDestructive: Bool

        package init(id: String, title: String, isDestructive: Bool = false) {
            self.id = id
            self.title = title
            self.isDestructive = isDestructive
        }
    }

    public let bundleIdentifier: String
    public let sourceWindowID: WindowID
    public let presentingStreamID: StreamID
    public let alertToken: String
    public let title: String?
    public let message: String?
    public let actions: [Action]

    package init(
        bundleIdentifier: String,
        sourceWindowID: WindowID,
        presentingStreamID: StreamID,
        alertToken: String,
        title: String?,
        message: String?,
        actions: [Action]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.sourceWindowID = sourceWindowID
        self.presentingStreamID = presentingStreamID
        self.alertToken = alertToken
        self.title = title
        self.message = message
        self.actions = actions
    }
}

package struct AppWindowCloseAlertActionRequestMessage: Codable {
    package let alertToken: String
    package let actionID: String
    package let presentingStreamID: StreamID

    package init(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID
    ) {
        self.alertToken = alertToken
        self.actionID = actionID
        self.presentingStreamID = presentingStreamID
    }
}

public struct AppWindowCloseAlertActionResultMessage: Codable, Sendable, Equatable {
    public let alertToken: String
    public let actionID: String
    public let success: Bool
    public let reason: String?

    package init(
        alertToken: String,
        actionID: String,
        success: Bool,
        reason: String?
    ) {
        self.alertToken = alertToken
        self.actionID = actionID
        self.success = success
        self.reason = reason
    }
}

/// New window added to the app stream (Host → Client)
public struct WindowAddedToStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app
    public let bundleIdentifier: String
    /// App-session identifier for the stream being expanded.
    public let appSessionID: UUID?
    /// Details of the new window
    public let streamID: StreamID
    public let mediaStreamID: StreamID
    public let windowID: WindowID
    public let title: String?
    public let width: Int
    public let height: Int
    public let isResizable: Bool
    public let atlasRegion: MirageAppAtlasRegion?
    public let atlasLayouts: [MirageAppAtlasLayout]?

    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        streamID: StreamID,
        mediaStreamID: StreamID? = nil,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool,
        atlasRegion: MirageAppAtlasRegion? = nil,
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID ?? streamID
        self.windowID = windowID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
        self.atlasRegion = atlasRegion
        self.atlasLayouts = atlasLayouts
    }
}

/// Window removed from app stream (Host → Client)
public struct WindowRemovedFromStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app
    public let bundleIdentifier: String
    /// App-session identifier for the removed window, when known.
    public let appSessionID: UUID?
    /// The stream that was removed.
    public let streamID: StreamID?
    /// The window that was removed
    public let windowID: WindowID
    /// Why it was removed
    public let reason: RemovalReason

    public enum RemovalReason: String, Codable, Sendable {
        /// Host closed the window
        case hostClosed
        /// Window no longer matches stream-eligible criteria
        case noLongerEligible
        /// Host-side app terminated
        case appTerminated
    }

    package init(
        bundleIdentifier: String,
        appSessionID: UUID? = nil,
        streamID: StreamID? = nil,
        windowID: WindowID,
        reason: RemovalReason
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.streamID = streamID
        self.windowID = windowID
        self.reason = reason
    }
}

/// Window stream failed (Host -> Client).
public struct WindowStreamFailedMessage: Codable, Sendable {
    public enum FailureCode: String, Codable, Sendable {
        case unknown
        case windowNotFound
        case windowAlreadyBound
        case virtualDisplayUnavailable
        case virtualDisplayCreationFailed
        case windowPlacementFailed
        case runtimeConditionBlocked
    }

    /// Bundle identifier of the app.
    public let bundleIdentifier: String
    /// Host window identifier that failed to stream.
    public let windowID: WindowID
    /// Optional host window title.
    public let title: String?
    /// Failure reason suitable for diagnostics and user-facing notice text.
    public let reason: String
    /// Stable failure code for client recovery policy.
    public let failureCode: FailureCode
    /// Short user-facing message. Falls back to ``reason`` for older senders.
    public let userMessage: String?

    package init(
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        reason: String,
        failureCode: FailureCode = .unknown,
        userMessage: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.title = title
        self.reason = reason
        self.failureCode = failureCode
        self.userMessage = userMessage
    }
}

/// Window resizability changed (Host → Client)
package struct WindowResizabilityChangedMessage: Codable {
    /// The window whose resizability changed
    package let windowID: WindowID
    /// New resizability state
    package let isResizable: Bool

    package init(windowID: WindowID, isResizable: Bool) {
        self.windowID = windowID
        self.isResizable = isResizable
    }
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

    package init(bundleIdentifier: String, closedWindowIDs: [WindowID], hasRemainingWindows: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.closedWindowIDs = closedWindowIDs
        self.hasRemainingWindows = hasRemainingWindows
    }
}

// MARK: - Auxiliary Window Compositing

/// Auxiliary window position/visibility update (Host → Client)
public struct AuxiliaryWindowUpdateMessage: Codable, Sendable {
    public struct AuxiliaryWindowInfo: Codable, Sendable, Equatable {
        /// Host window ID of the auxiliary window.
        public let windowID: WindowID
        /// Stream ID carrying this auxiliary window's video frames.
        public let streamID: StreamID
        /// Horizontal offset from the parent window origin, in logical points.
        public let offsetX: Int
        /// Vertical offset from the parent window origin, in logical points.
        public let offsetY: Int
        /// Logical width in points.
        public let width: Int
        /// Logical height in points.
        public let height: Int
        /// Whether this auxiliary window is currently visible.
        public let isVisible: Bool

        package init(
            windowID: WindowID,
            streamID: StreamID,
            offsetX: Int,
            offsetY: Int,
            width: Int,
            height: Int,
            isVisible: Bool
        ) {
            self.windowID = windowID
            self.streamID = streamID
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.width = width
            self.height = height
            self.isVisible = isVisible
        }
    }

    /// Bundle identifier of the app owning these auxiliary windows.
    public let bundleIdentifier: String
    /// Stream ID of the parent (primary) window.
    public let parentStreamID: StreamID
    /// Current auxiliary windows and their positions relative to the parent.
    public let auxiliaryWindows: [AuxiliaryWindowInfo]

    package init(
        bundleIdentifier: String,
        parentStreamID: StreamID,
        auxiliaryWindows: [AuxiliaryWindowInfo]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.parentStreamID = parentStreamID
        self.auxiliaryWindows = auxiliaryWindows
    }
}
