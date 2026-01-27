//
//  SharedVirtualDisplayManager+Access.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

#if os(macOS)
import Foundation
import CoreGraphics

extension SharedVirtualDisplayManager {
    // MARK: - Display Access

    /// Get the shared display ID
    func getDisplayID() -> CGDirectDisplayID? {
        return sharedDisplay?.displayID
    }

    /// Get the shared display space ID
    func getSpaceID() -> CGSSpaceID? {
        return sharedDisplay?.spaceID
    }

    /// Get the shared display context
    func getDisplayContext() -> ManagedDisplayContext? {
        return sharedDisplay
    }

    /// Get the shared display generation.
    func getDisplayGeneration() -> UInt64 {
        sharedDisplay?.generation ?? 0
    }

    /// Register a handler for shared-display generation changes.
    func setGenerationChangeHandler(_ handler: (@Sendable (ManagedDisplayContext, UInt64) -> Void)?) {
        generationChangeHandler = handler
    }

    /// Get the shared display bounds
    /// Uses the known resolution instead of CGDisplayBounds (which returns stale values for new displays)
    func getDisplayBounds() -> CGRect? {
        guard let display = sharedDisplay else { return nil }
        return CGVirtualDisplayBridge.getDisplayBounds(display.displayID, knownResolution: display.resolution)
    }

    /// Check if there's an active shared display
    func hasActiveDisplay() -> Bool {
        return sharedDisplay != nil
    }

    /// Get count of active consumers
    func activeConsumerCount() -> Int {
        return activeConsumers.count
    }

    /// Get all active stream IDs (filters out non-stream consumers)
    func activeStreamIDs() -> [StreamID] {
        return activeConsumers.keys.compactMap { consumer in
            if case .stream(let streamID) = consumer {
                return streamID
            }
            return nil
        }
    }

}
#endif
