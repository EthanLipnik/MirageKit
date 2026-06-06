//
//  SharedVirtualDisplayManager+Cleanup.swift
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
    // MARK: - Cleanup

    func waitForDisplayRemoval(displayID: CGDirectDisplayID, timeoutMs: Int = 1500) async {
        let clampedTimeoutMs = max(0, timeoutMs)
        let deadline = Date().addingTimeInterval(Double(clampedTimeoutMs) / 1000.0)
        while Date() < deadline {
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    func destroyAttemptDisplay(
        _ displayContext: CGVirtualDisplayBridge.VirtualDisplayContext,
        removalWaitMs: Int = 1500
    )
    async {
        let displayID = displayContext.displayID
        let invalidateSelector = NSSelectorFromString("invalidate")
        let displayObject = displayContext.display

        await withDisplayMutation(kind: .virtualDisplayDestroy) {
            if (displayObject as AnyObject).responds(to: invalidateSelector) {
                _ = (displayObject as AnyObject).perform(invalidateSelector)
                MirageLogger.host("Invalidated failed-attempt virtual display object \(displayID)")
            }

            CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayID)
            await waitForDisplayRemoval(displayID: displayID, timeoutMs: removalWaitMs)
        }

        if CGVirtualDisplayBridge.isDisplayOnline(displayID) {
            orphanedDisplayIDs.insert(displayID)
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(for: displayContext.colorSpace)
            CGVirtualDisplayBridge.invalidatePersistentSerial(for: displayContext.colorSpace)
            MirageLogger.debug(
                .host,
                "WARNING: Failed-attempt virtual display \(displayID) remained online after invalidation; marked orphaned and rotated descriptor profile/serial"
            )
            return
        }

        orphanedDisplayIDs.remove(displayID)
        MirageLogger.host("Failed-attempt virtual display \(displayID) successfully destroyed")
    }

    func destroyDisplay(_ display: ManagedDisplayContext, removalWaitMs: Int = 3000) async {
        let displayID = display.displayID
        MirageLogger.host("Destroying virtual display, displayID=\(displayID)")

        let invalidateSelector = NSSelectorFromString("invalidate")
        let displayObject = display.displayRef.value
        await withDisplayMutation(kind: .virtualDisplayDestroy) {
            if (displayObject as AnyObject).responds(to: invalidateSelector) {
                _ = (displayObject as AnyObject).perform(invalidateSelector)
                MirageLogger.host("Invalidated virtual display object \(displayID)")
            }

            CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayID)
            await waitForDisplayRemoval(displayID: displayID, timeoutMs: removalWaitMs)
        }

        if CGVirtualDisplayBridge.isDisplayOnline(displayID) {
            orphanedDisplayIDs.insert(displayID)
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(for: display.colorSpace)
            CGVirtualDisplayBridge.invalidatePersistentSerial(for: display.colorSpace)
            MirageLogger.debug(
                .host,
                "WARNING: Virtual display \(displayID) still online after invalidation; marked orphaned and rotated descriptor profile/serial"
            )
            return
        }

        orphanedDisplayIDs.remove(displayID)
        MirageLogger.host("Virtual display \(displayID) successfully destroyed")
    }

    /// Destroy the shared display.
    func destroyDisplay() async {
        await destroyDisplay(removalWaitMs: 1500)
    }

    /// Destroy the shared display with a custom removal wait budget.
    func destroyDisplay(removalWaitMs: Int) async {
        guard let display = sharedDisplay else { return }
        sharedDisplay = nil
        await destroyDisplay(display, removalWaitMs: removalWaitMs)
    }

    /// Destroy all managed displays and clear all consumers
    /// Called during host shutdown
    func destroyAllAndClear() async {
        let dedicatedDisplays = Array(dedicatedDisplaysByStreamID.values)
        dedicatedDisplaysByStreamID.removeAll()
        activeConsumers.removeAll()
        for display in dedicatedDisplays {
            await destroyDisplay(display)
        }
        await destroyDisplay()
        MirageLogger.host(
            "Destroyed shared display, \(dedicatedDisplays.count) dedicated displays, and cleared all consumers"
        )
    }

    /// Statistics about shared and dedicated displays.
    var statistics: (
        hasDisplay: Bool,
        consumerCount: Int,
        resolution: CGSize?,
        dedicatedDisplayCount: Int
    ) {
        (
            hasDisplay: sharedDisplay != nil,
            consumerCount: activeConsumers.count,
            resolution: sharedDisplay?.resolution,
            dedicatedDisplayCount: dedicatedDisplaysByStreamID.count
        )
    }

    func withDisplayMutation<T>(
        kind: VirtualDisplayMutationKind,
        operation: () async -> T
    ) async -> T {
        let lease = await VirtualDisplayMutationCoordinator.shared.acquire(kind: kind)
        let result = await operation()
        await VirtualDisplayMutationCoordinator.shared.release(lease)
        return result
    }
}
#endif
