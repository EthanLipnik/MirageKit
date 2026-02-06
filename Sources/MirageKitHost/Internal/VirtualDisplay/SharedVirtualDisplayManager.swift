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

/// Manages a single shared virtual display for all Mirage streams
/// Uses reference counting to create on first client and destroy when last client releases
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
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let generation: UInt64
        let createdAt: Date
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
        case stream(StreamID)
        case loginDisplay
        case unlockKeyboard
        case desktopStream
        case qualityTest
    }

    /// Error types for shared display operations
    enum SharedDisplayError: Error, LocalizedError {
        case apiNotAvailable
        case creationFailed(String)
        case noActiveDisplay
        case clientNotFound(StreamID)
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
            case let .clientNotFound(streamID):
                "No client found for stream \(streamID)"
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

    /// Active consumers using the shared display
    var activeConsumers: [DisplayConsumer: ClientDisplayInfo] = [:]

    /// Counter for display naming
    var displayCounter: UInt32 = 0

    /// Monotonic display generation incremented when the shared display instance changes.
    var displayGeneration: UInt64 = 0

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
