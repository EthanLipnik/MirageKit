//
//  SharedVirtualDisplayManager+Access.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
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

    /// Current shared virtual display ID.
    var displayID: CGDirectDisplayID? {
        sharedDisplay?.displayID
    }

    /// Current shared virtual display snapshot.
    var displaySnapshot: DisplaySnapshot? {
        guard let display = sharedDisplay else { return nil }
        return snapshot(from: display)
    }

    func updateSharedDisplayObservedResolution(
        displayID: CGDirectDisplayID,
        resolution: CGSize
    )
    -> DisplaySnapshot? {
        guard resolution.width > 0,
              resolution.height > 0,
              let display = sharedDisplay,
              display.displayID == displayID else {
            return nil
        }

        if let existingInfo = activeConsumers[.desktopStream] {
            activeConsumers[.desktopStream] = ClientDisplayInfo(
                resolution: resolution,
                windowID: existingInfo.windowID,
                colorSpace: existingInfo.colorSpace,
                acquiredAt: existingInfo.acquiredAt
            )
        }

        guard display.resolution != resolution else { return snapshot(from: display) }

        let updatedDisplay = ManagedDisplayContext(
            displayID: display.displayID,
            spaceID: display.spaceID,
            resolution: resolution,
            scaleFactor: display.scaleFactor,
            refreshRate: display.refreshRate,
            colorSpace: display.colorSpace,
            displayP3CoverageStatus: display.displayP3CoverageStatus,
            generation: display.generation,
            createdAt: display.createdAt,
            displayRef: display.displayRef
        )
        sharedDisplay = updatedDisplay
        MirageLogger.host(
            "Shared display observed resolution refreshed to \(Int(resolution.width))x\(Int(resolution.height)) px"
        )
        return snapshot(from: updatedDisplay)
    }

    /// Generation of the current shared display snapshot.
    var currentDisplayGeneration: UInt64 {
        sharedDisplay?.generation ?? 0
    }

    /// Register a handler for shared-display generation changes.
    func setGenerationChangeHandler(_ handler: (@Sendable (DisplaySnapshot, UInt64) -> Void)?) {
        generationChangeHandler = handler
    }

    /// Shared display bounds in logical points.
    /// Uses the known logical resolution instead of CGDisplayBounds (which can return stale values for new displays).
    var displayBounds: CGRect? {
        guard let display = sharedDisplay else { return nil }
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: display.resolution,
            scaleFactor: display.scaleFactor
        )
        return CGVirtualDisplayBridge.displayBounds(display.displayID, knownResolution: logicalResolution)
    }
}
#endif
