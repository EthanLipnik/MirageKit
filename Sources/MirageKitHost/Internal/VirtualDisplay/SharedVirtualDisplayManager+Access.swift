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
            refreshRate: display.refreshRate,
            colorSpace: display.colorSpace,
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
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(for: display.resolution)
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

    /// Get all active stream IDs (filters out non-stream consumers)
    func activeStreamIDs() -> [StreamID] {
        activeConsumers.keys.compactMap { consumer in
            if case let .stream(streamID) = consumer { return streamID }
            return nil
        }
    }
}
#endif
