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
        let displayP3CoverageStatus: MirageDisplayP3CoverageStatus
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
        let displayP3CoverageStatus: MirageDisplayP3CoverageStatus
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
        case unlockKeyboard
        case desktopStream
        case qualityTest
    }

    enum DisplayCreationPolicy: Sendable, Equatable {
        case adaptiveRetinaThenFallback1xAndColor
        case singleAttempt(hiDPI: Bool)
    }

    /// Error types for shared and dedicated display operations
    enum SharedDisplayError: Error, LocalizedError {
        case apiNotAvailable
        case creationFailed(String)
        case noActiveDisplay
        case streamDisplayNotFound(StreamID)
        case spaceNotFound(CGDirectDisplayID)
        case screenCaptureKitVisibilityDelayed(CGDirectDisplayID)
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
            case let .screenCaptureKitVisibilityDelayed(displayID):
                "ScreenCaptureKit did not surface virtual display \(displayID) before the startup deadline"
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

    /// Cached observed inset pixels keyed by color-space + display scale.
    var dedicatedInsetsByKey: [DedicatedInsetCacheKey: CGSize] = [:]

    /// Display IDs that remained online after explicit invalidation + timeout.
    var orphanedDisplayIDs: Set<CGDirectDisplayID> = []

    /// Number of in-flight `acquireDisplayForConsumer` calls.  Checked by
    /// `releaseDisplayForConsumer` to avoid destroying a display that another
    /// task is still creating/recreating across an await boundary.
    var pendingAcquisitionCount: Int = 0

    // MARK: - App Stream Shared Display

    /// Single shared virtual display for all app-stream windows.
    var appStreamDisplay: ManagedDisplayContext?

    /// Size preset currently backing the app stream display.
    var appStreamPreset: MirageDisplaySizePreset = .standard

    /// Number of active app streams using the shared display (reference counting).
    var appStreamConsumerCount: Int = 0

    /// Handler invoked when the shared display generation changes while streams are active.
    var generationChangeHandler: (@Sendable (DisplaySnapshot, UInt64) -> Void)?

    /// Register a display ID as orphaned so the next acquisition cleans it up.
    func trackOrphanedDisplay(_ displayID: CGDirectDisplayID) {
        orphanedDisplayIDs.insert(displayID)
        MirageLogger.host("Tracked orphaned display \(displayID); total orphans: \(orphanedDisplayIDs.count)")
    }

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
