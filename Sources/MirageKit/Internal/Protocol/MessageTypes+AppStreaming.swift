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

public enum MirageStreamRecoveryProfile: String, Codable, Sendable {
    case activeAggressive
    case passiveBounded
}

public struct MirageStreamPolicy: Codable, Sendable, Equatable {
    public let streamID: StreamID
    public let tier: MirageStreamRuntimeTier
    public let targetFPS: Int
    public let targetBitrateBps: Int?
    public let recoveryProfile: MirageStreamRecoveryProfile

    package init(
        streamID: StreamID,
        tier: MirageStreamRuntimeTier,
        targetFPS: Int,
        targetBitrateBps: Int?,
        recoveryProfile: MirageStreamRecoveryProfile
    ) {
        self.streamID = streamID
        self.tier = tier
        self.targetFPS = max(1, min(120, targetFPS))
        self.targetBitrateBps = targetBitrateBps
        self.recoveryProfile = recoveryProfile
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

/// Request for list of installed apps (Client → Host)
package struct AppListRequestMessage: Codable {
    /// Whether to include app icons in the response
    package let includeIcons: Bool
    /// Whether host-side app-list caches should be bypassed for this request
    package let forceRefresh: Bool

    package init(includeIcons: Bool, forceRefresh: Bool = false) {
        self.includeIcons = includeIcons
        self.forceRefresh = forceRefresh
    }
}

/// List of installed apps available for streaming (Host → Client)
package struct AppListMessage: Codable {
    /// Available apps (filtered by host's allow/blocklist, excludes apps already streaming)
    package let apps: [MirageInstalledApp]

    package init(apps: [MirageInstalledApp]) {
        self.apps = apps
    }
}

/// Request to stream an app (Client → Host)
package struct SelectAppMessage: Codable {
    /// Bundle identifier of the app to stream
    package let bundleIdentifier: String
    /// Client's data port for video
    package let dataPort: UInt16?
    /// Client's display scale factor
    package let scaleFactor: CGFloat?
    /// Client's display dimensions
    package let displayWidth: Int?
    package let displayHeight: Int?
    /// Client refresh rate override in Hz (60/120 based on client capability)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    package let maxRefreshRate: Int
    /// Client-requested keyframe interval in frames
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream bit depth.
    package var bitDepth: MirageVideoBitDepth?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?
    /// Client-requested host performance profile.
    package var performanceMode: MirageStreamPerformanceMode?
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
    /// Maximum concurrent visible app windows requested by the client tier policy.
    package let maxConcurrentVisibleWindows: Int
    /// Client-requested shared bitrate allocation policy for multi-window app streaming.
    package let bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy?
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case dataPort
        case scaleFactor
        case displayWidth
        case displayHeight
        case maxRefreshRate
        case keyFrameInterval
        case captureQueueDepth
        case bitDepth
        case bitrate
        case latencyMode
        case performanceMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case maxConcurrentVisibleWindows
        case bitrateAllocationPolicy
    }

    package init(
        bundleIdentifier: String,
        dataPort: UInt16? = nil,
        scaleFactor: CGFloat? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        maxRefreshRate: Int,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        performanceMode: MirageStreamPerformanceMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        maxConcurrentVisibleWindows: Int = 1,
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.dataPort = dataPort
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.maxRefreshRate = maxRefreshRate
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.performanceMode = performanceMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.maxConcurrentVisibleWindows = max(1, maxConcurrentVisibleWindows)
        self.bitrateAllocationPolicy = bitrateAllocationPolicy
    }
}

/// Confirmation that app streaming has started (Host → Client)
public struct AppStreamStartedMessage: Codable {
    /// Bundle identifier of the app being streamed
    public let bundleIdentifier: String
    /// App display name
    public let appName: String
    /// Initial windows that are now streaming
    public let windows: [AppStreamWindow]

    public struct AppStreamWindow: Codable {
        public let streamID: StreamID
        public let windowID: WindowID
        public let title: String?
        /// Calibrated stream viewport width in points (derived from dedicated virtual-display visible frame).
        public let width: Int
        /// Calibrated stream viewport height in points (derived from dedicated virtual-display visible frame).
        public let height: Int
        public let isResizable: Bool

        package init(
            streamID: StreamID,
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool
        ) {
            self.streamID = streamID
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
        }
    }

    package init(bundleIdentifier: String, appName: String, windows: [AppStreamWindow]) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windows = windows
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
        public let window: WindowMetadata

        package init(slotIndex: Int, streamID: StreamID, window: WindowMetadata) {
            self.slotIndex = slotIndex
            self.streamID = streamID
            self.window = window
        }
    }

    public let bundleIdentifier: String
    public let maxVisibleSlots: Int
    public let slots: [Slot]
    public let hiddenWindows: [WindowMetadata]

    package init(
        bundleIdentifier: String,
        maxVisibleSlots: Int,
        slots: [Slot],
        hiddenWindows: [WindowMetadata]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.maxVisibleSlots = max(1, maxVisibleSlots)
        self.slots = slots
        self.hiddenWindows = hiddenWindows
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
    public let windowID: WindowID
    public let success: Bool
    public let reason: String?

    package init(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        windowID: WindowID,
        success: Bool,
        reason: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetSlotStreamID = targetSlotStreamID
        self.windowID = windowID
        self.success = success
        self.reason = reason
    }
}

/// New window added to the app stream (Host → Client)
public struct WindowAddedToStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app
    public let bundleIdentifier: String
    /// Details of the new window
    public let streamID: StreamID
    public let windowID: WindowID
    public let title: String?
    public let width: Int
    public let height: Int
    public let isResizable: Bool

    package init(
        bundleIdentifier: String,
        streamID: StreamID,
        windowID: WindowID,
        title: String?,
        width: Int,
        height: Int,
        isResizable: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.streamID = streamID
        self.windowID = windowID
        self.title = title
        self.width = width
        self.height = height
        self.isResizable = isResizable
    }
}

/// Window removed from app stream (Host → Client)
public struct WindowRemovedFromStreamMessage: Codable, Sendable {
    /// Bundle identifier of the app
    public let bundleIdentifier: String
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

    package init(bundleIdentifier: String, windowID: WindowID, reason: RemovalReason) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.reason = reason
    }
}

/// Window stream failed (Host -> Client).
public struct WindowStreamFailedMessage: Codable, Sendable {
    /// Bundle identifier of the app.
    public let bundleIdentifier: String
    /// Host window identifier that failed to stream.
    public let windowID: WindowID
    /// Optional host window title.
    public let title: String?
    /// Failure reason suitable for diagnostics and user-facing notice text.
    public let reason: String

    package init(bundleIdentifier: String, windowID: WindowID, title: String?, reason: String) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.title = title
        self.reason = reason
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
