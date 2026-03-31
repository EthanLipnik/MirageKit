//
//  SharedVirtualDisplayManager+Access.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    // MARK: - Display Access

    func snapshot(from display: ManagedDisplayContext) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: display.displayID,
            spaceID: display.spaceID,
            resolution: display.resolution,
            scaleFactor: display.scaleFactor,
            refreshRate: display.refreshRate,
            colorSpace: display.colorSpace,
            displayP3CoverageStatus: display.displayP3CoverageStatus,
            generation: display.generation,
            createdAt: display.createdAt
        )
    }

    /// Get the shared display ID
    func getDisplayID() -> CGDirectDisplayID? {
        sharedDisplay?.displayID
    }

    /// Get the shared display space ID
    func getSpaceID() -> CGSSpaceID? {
        sharedDisplay?.spaceID
    }

    /// Get the shared display snapshot
    func getDisplaySnapshot() -> DisplaySnapshot? {
        guard let display = sharedDisplay else { return nil }
        return snapshot(from: display)
    }

    /// Get the shared display generation.
    func getDisplayGeneration() -> UInt64 {
        sharedDisplay?.generation ?? 0
    }

    /// Register a handler for shared-display generation changes.
    func setGenerationChangeHandler(_ handler: (@Sendable (DisplaySnapshot, UInt64) -> Void)?) {
        generationChangeHandler = handler
    }

    /// Get the shared display bounds in logical points.
    /// Uses the known logical resolution instead of CGDisplayBounds (which can return stale values for new displays).
    func getDisplayBounds() -> CGRect? {
        guard let display = sharedDisplay else { return nil }
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: display.resolution,
            scaleFactor: display.scaleFactor
        )
        return CGVirtualDisplayBridge.getDisplayBounds(display.displayID, knownResolution: logicalResolution)
    }

    /// Check if there's an active shared display
    func hasActiveDisplay() -> Bool {
        sharedDisplay != nil
    }

    /// Get count of active consumers
    func activeConsumerCount() -> Int {
        activeConsumers.count
    }

    /// Get the shared app-stream display snapshot.
    func getAppStreamDisplaySnapshot() -> DisplaySnapshot? {
        guard let display = appStreamDisplay else { return nil }
        return snapshot(from: display)
    }

    /// Get a dedicated display snapshot for a stream.
    func getDedicatedDisplaySnapshot(for streamID: StreamID) -> DisplaySnapshot? {
        guard let display = dedicatedDisplaysByStreamID[streamID] else { return nil }
        return snapshot(from: display)
    }

    /// Get dedicated display bounds in logical points for a stream.
    func getDedicatedDisplayBounds(for streamID: StreamID) -> CGRect? {
        guard let display = dedicatedDisplaysByStreamID[streamID] else { return nil }
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: display.resolution,
            scaleFactor: display.scaleFactor
        )
        return CGVirtualDisplayBridge.getDisplayBounds(display.displayID, knownResolution: logicalResolution)
    }

    /// Check whether a dedicated display exists for a stream.
    func hasDedicatedDisplay(for streamID: StreamID) -> Bool {
        dedicatedDisplaysByStreamID[streamID] != nil
    }

    /// Get count of dedicated stream displays.
    func dedicatedDisplayCount() -> Int {
        dedicatedDisplaysByStreamID.count
    }
}
#endif
