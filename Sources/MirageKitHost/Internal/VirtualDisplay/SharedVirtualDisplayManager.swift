//
//  SharedVirtualDisplayManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

/// Manages Mirage virtual displays.
/// - Shared consumer display: desktop/login/unlock flows.
/// - Dedicated stream displays: one per window stream.
actor SharedVirtualDisplayManager {
    // MARK: - Singleton

    static let shared = SharedVirtualDisplayManager()

    private init() {}

    // MARK: - Types

    /// Context for a managed virtual display
    struct ManagedDisplayContext: Sendable {
        let displayID: CGDirectDisplayID
        let spaceID: CGSSpaceID
        let resolution: CGSize
        let scaleFactor: CGFloat
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let generation: UInt64
        let createdAt: Date

        /// Display reference (non-Sendable, managed internally)
        let displayRef: UncheckedSendableBox<AnyObject>
    }

    /// Public snapshot of a managed virtual display (no display reference).
    struct DisplaySnapshot: Sendable {
        let displayID: CGDirectDisplayID
        let spaceID: CGSSpaceID
        let resolution: CGSize
        let scaleFactor: CGFloat
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let generation: UInt64
        let createdAt: Date
    }

    /// Cache key for dedicated-display inset calibration.
    struct DedicatedInsetCacheKey: Hashable, Sendable {
        let colorSpace: MirageColorSpace
        let scaleBucket: Int
    }

    /// Box for non-Sendable display reference
    final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) {
            self.value = value
            MirageLogger.host("UncheckedSendableBox created for display reference")
        }

        deinit {
            MirageLogger.host("UncheckedSendableBox DEALLOCATED - display reference released")
        }
    }

    /// Information about a client using the shared display
    struct ClientDisplayInfo: Sendable {
        let resolution: CGSize
        let windowID: WindowID
        let colorSpace: MirageColorSpace
        let acquiredAt: Date
    }

    /// Consumer types that can acquire the shared display
    enum DisplayConsumer: Hashable, Sendable {
        case loginDisplay
        case unlockKeyboard
        case desktopStream
        case qualityTest
    }

    /// Error types for shared and dedicated display operations
    enum SharedDisplayError: Error, LocalizedError {
        case apiNotAvailable
        case creationFailed(String)
        case noActiveDisplay
        case streamDisplayNotFound(StreamID)
        case spaceNotFound(CGDirectDisplayID)
        case scDisplayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .apiNotAvailable:
                "CGVirtualDisplay APIs are not available"
            case let .creationFailed(reason):
                "Failed to create virtual display: \(reason)"
            case .noActiveDisplay:
                "No active shared virtual display"
            case let .streamDisplayNotFound(streamID):
                "No dedicated display found for stream \(streamID)"
            case let .spaceNotFound(displayID):
                "No space found for display \(displayID)"
            case let .scDisplayNotFound(displayID):
                "SCDisplay not found for virtual display \(displayID)"
            }
        }
    }

    // MARK: - State

    /// The single shared virtual display (nil when no clients)
    var sharedDisplay: ManagedDisplayContext?

    /// Dedicated virtual displays keyed by stream ID (one display per stream).
    var dedicatedDisplaysByStreamID: [StreamID: ManagedDisplayContext] = [:]

    /// Active consumers using the shared display
    var activeConsumers: [DisplayConsumer: ClientDisplayInfo] = [:]

    /// Counter for display naming
    var displayCounter: UInt32 = 0

    /// Monotonic display generation incremented when the shared display instance changes.
    var displayGeneration: UInt64 = 0

    /// Consecutive non-Retina fallback streak by color space.
    var fallbackStreakByColorSpace: [MirageColorSpace: Int] = [:]

    /// Cached observed inset pixels keyed by color-space + display scale.
    var dedicatedInsetsByKey: [DedicatedInsetCacheKey: CGSize] = [:]

    /// Last successfully validated Retina pixel resolution by color space.
    /// Used as an optional fallback candidate when nearby requests fail.
    var lastKnownGoodRetinaResolutionByColorSpace: [MirageColorSpace: CGSize] = [:]

    /// Display IDs that remained online after explicit invalidation + timeout.
    var orphanedDisplayIDs: Set<CGDirectDisplayID> = []

    /// Handler invoked when the shared display generation changes while streams are active.
    var generationChangeHandler: (@Sendable (DisplaySnapshot, UInt64) -> Void)?

    static let preferredStreamRefreshRate: Int = 60

    static func streamRefreshRate(for requested: Int) -> Int {
        requested >= 120 ? 120 : preferredStreamRefreshRate
    }

    func resolvedRefreshRate(_ requested: Int) -> Int {
        if requested >= 120 { return 120 }
        return Self.preferredStreamRefreshRate
    }
}

#endif
