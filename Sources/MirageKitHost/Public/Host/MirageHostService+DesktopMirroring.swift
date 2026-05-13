//
//  MirageHostService+DesktopMirroring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension MirageHostService {
    func resolvePrimaryPhysicalDisplayID() -> CGDirectDisplayID? {
        let mainDisplayID = CGMainDisplayID()
        if !CGVirtualDisplayBridge.isVirtualDisplay(mainDisplayID) { return mainDisplayID }

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        return displays.first { !CGVirtualDisplayBridge.isVirtualDisplay($0) }
    }

    func captureDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID])
    -> [CGDirectDisplayID: CGDirectDisplayID] {
        var snapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for displayID in displayIDs {
            snapshot[displayID] = CGDisplayMirrorsDisplay(displayID)
        }
        return snapshot
    }

    func isDisplayMirroringRestored(targetDisplayID: CGDirectDisplayID) -> Bool {
        let displaysToMirror = CGVirtualDisplayBridge.displaysToMirror(excludingDisplayID: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return true }
        let mirroredCount = displaysToMirror.count(where: { CGDisplayMirrorsDisplay($0) == targetDisplayID })
        return mirroredCount == displaysToMirror.count
    }

    func restoreDisplayMirroringAfterResize(
        streamID: StreamID,
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize,
        maxAttempts: Int = 3
    )
    async -> Bool {
        switch desktopMirroringRestoreContinuationDecision(
            requestedStreamID: streamID,
            activeDesktopStreamID: desktopStreamID,
            hasDesktopContext: desktopStreamContext != nil,
            desktopStreamMode: desktopStreamMode
        ) {
        case .continueRestore:
            break
        case .abortStreamInactive:
            MirageLogger.host("Aborting desktop mirroring restore because the stream is no longer active")
            return false
        case .abortModeChanged:
            MirageLogger.host("Aborting desktop mirroring restore because desktop stream mode changed")
            return false
        }

        guard await setupDisplayMirroring(
            targetDisplayID: targetDisplayID,
            expectedPixelResolution: expectedPixelResolution
        ) else {
            MirageLogger.host(
                "Desktop mirroring restore could not start; continuing with virtual display capture"
            )
            return false
        }

        var retryDelayMs = 500
        for attempt in 1 ... maxAttempts {
            // Allow CGDisplayMirror reconfiguration to settle before verifying.
            do {
                try await Task.sleep(for: .milliseconds(retryDelayMs))
            } catch {
                return false
            }

            switch desktopMirroringRestoreContinuationDecision(
                requestedStreamID: streamID,
                activeDesktopStreamID: desktopStreamID,
                hasDesktopContext: desktopStreamContext != nil,
                desktopStreamMode: desktopStreamMode
            ) {
            case .continueRestore:
                break
            case .abortStreamInactive:
                MirageLogger.host("Aborting desktop mirroring restore because the stream is no longer active")
                return false
            case .abortModeChanged:
                MirageLogger.host("Aborting desktop mirroring restore because desktop stream mode changed")
                return false
            }

            if isDisplayMirroringRestored(targetDisplayID: targetDisplayID) {
                if attempt > 1 {
                    MirageLogger
                        .host(
                            "Desktop mirroring restore succeeded on attempt \(attempt)/\(maxAttempts)"
                        )
                }
                return true
            }

            let displaysToMirror = CGVirtualDisplayBridge.displaysToMirror(excludingDisplayID: targetDisplayID)
            let mirroredCount = displaysToMirror.count(where: { CGDisplayMirrorsDisplay($0) == targetDisplayID })

            if attempt < maxAttempts {
                MirageLogger
                    .host(
                        "Desktop mirroring restore verification pending (attempt \(attempt)/\(maxAttempts), mirrored=\(mirroredCount)/\(displaysToMirror.count), target=\(targetDisplayID))"
                    )
                _ = await setupDisplayMirroring(
                    targetDisplayID: targetDisplayID,
                    expectedPixelResolution: expectedPixelResolution
                )
                retryDelayMs = min(2000, Int(Double(retryDelayMs) * 1.8))
            } else {
                MirageLogger
                    .host(
                        "Desktop mirroring restore verification failed (attempt \(attempt)/\(maxAttempts), mirrored=\(mirroredCount)/\(displaysToMirror.count), target=\(targetDisplayID))"
                    )
            }
        }

        MirageLogger.host("Desktop mirroring restore failed after \(maxAttempts) attempts")
        return false
    }

    /// Ensure physical displays are not mirroring virtual displays during app/window streaming.
    func unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(
        targetDisplayID: CGDirectDisplayID? = nil
    )
    async {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        let physicalDisplaysMirroringVirtual = displays.compactMap { displayID -> CGDirectDisplayID? in
            guard !CGVirtualDisplayBridge.isVirtualDisplay(displayID) else { return nil }
            let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
            guard mirroredDisplayID != kCGNullDirectDisplay,
                  CGVirtualDisplayBridge.isVirtualDisplay(mirroredDisplayID) else {
                return nil
            }
            if let targetDisplayID, mirroredDisplayID != targetDisplayID {
                return nil
            }
            return displayID
        }

        guard !physicalDisplaysMirroringVirtual.isEmpty else { return }

        await withHostDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                MirageLogger.host("Physical display unmirror unavailable: failed to begin display configuration")
                return
            }

            var unmirroredCount = 0
            for displayID in physicalDisplaysMirroringVirtual {
                let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                if result == .success {
                    unmirroredCount += 1
                } else {
                    MirageLogger.host("Physical display unmirror skipped display \(displayID): \(result)")
                }
            }

            guard unmirroredCount > 0 else {
                CGCancelDisplayConfiguration(config)
                return
            }

            let completion = CGCompleteDisplayConfiguration(config, .forSession)
            if completion == .success {
                MirageLogger.host("Unmirrored \(unmirroredCount) physical displays from virtual displays")
            } else {
                MirageLogger.host("Physical display unmirror unavailable: failed to complete configuration \(completion)")
            }
        }
    }

    /// Set up display mirroring so every non-Mirage display mirrors the target display.
    /// Normal desktop streams target the shared virtual display; host-resolution streams target the main display.
    func setupDisplayMirroring(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize? = nil,
        requiresResidualMirageDisplaysClear: Bool = true
    )
    async -> Bool {
        guard await waitForDisplayMirroringTargetStability(
            targetDisplayID: targetDisplayID,
            expectedPixelResolution: expectedPixelResolution,
            requiresResidualMirageDisplaysClear: requiresResidualMirageDisplaysClear
        ) else {
            MirageLogger.host(
                "Display mirroring setup deferred because target display \(targetDisplayID) did not stabilize"
            )
            return false
        }

        let displaysToMirror = CGVirtualDisplayBridge.displaysToMirror(excludingDisplayID: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return true
        }

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: false)

        let mirroredDisplayIDs = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        if mirroredDisplayIDs.count == displaysToMirror.count {
            if desktopMirroringSnapshot.isEmpty {
                desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
                MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
            }
            mirroredDesktopDisplayIDs = Set(displaysToMirror)
            MirageLogger.host("Display mirroring already enabled for \(displaysToMirror.count) displays")
            _ = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup_noop")
            return true
        }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        MirageLogger.host("Setting up mirroring for \(displaysToMirror.count) displays")

        return await withHostDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                MirageLogger.host("Display mirroring setup unavailable: failed to begin display configuration")
                return false
            }

            var successfullyMirrored: Set<CGDirectDisplayID> = []

            for displayID in displaysToMirror {
                // Skip if already mirroring the target
                if CGDisplayMirrorsDisplay(displayID) == targetDisplayID {
                    successfullyMirrored.insert(displayID)
                    continue
                }

                let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetDisplayID)
                if result == .success {
                    successfullyMirrored.insert(displayID)
                    MirageLogger.host("Configured display \(displayID) to mirror target display \(targetDisplayID)")
                } else {
                    MirageLogger.host("Display mirroring setup skipped display \(displayID): \(result)")
                }
            }

            guard !successfullyMirrored.isEmpty else {
                MirageLogger.host("Display mirroring setup unavailable: no displays accepted mirroring configuration")
                CGCancelDisplayConfiguration(config)
                return false
            }

            let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
            if completeResult != .success {
                MirageLogger.host("Display mirroring setup unavailable: failed to complete configuration \(completeResult)")
                CGCancelDisplayConfiguration(config)
                return false
            }

            mirroredDesktopDisplayIDs = successfullyMirrored
            MirageLogger
                .host(
                    "Display mirroring enabled for \(successfullyMirrored.count) displays → target display \(targetDisplayID)"
                )
            _ = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup")
            return successfullyMirrored.count == displaysToMirror.count
        }
    }

    /// Temporarily suspend desktop mirroring before a virtual-display resize.
    /// This keeps resize transactions deterministic and avoids resize+mirror contention.
    func suspendDisplayMirroringForResize(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = CGVirtualDisplayBridge.displaysToMirror(excludingDisplayID: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return }

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: true)

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        let mirroredToTarget = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        guard !mirroredToTarget.isEmpty else { return }

        await withHostDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                MirageLogger.host("Display mirroring suspend unavailable: failed to begin display configuration")
                return
            }

            var suspendedCount = 0
            for displayID in mirroredToTarget {
                let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                if result == .success {
                    suspendedCount += 1
                } else {
                    MirageLogger.host("Display mirroring suspend skipped display \(displayID): \(result)")
                }
            }

            guard suspendedCount > 0 else {
                CGCancelDisplayConfiguration(config)
                return
            }

            let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
            if completeResult != .success {
                MirageLogger.host("Display mirroring suspend unavailable: failed to complete configuration \(completeResult)")
                return
            }

            mirroredDesktopDisplayIDs.removeAll()
            MirageLogger.host("Temporarily suspended mirroring for \(suspendedCount) displays before resize")
        }
    }

    /// Restore display mirroring to the pre-stream configuration.
    func disableDisplayMirroring(displayID: CGDirectDisplayID) async -> Bool {
        guard !desktopMirroringSnapshot.isEmpty else {
            MirageLogger.host("No display mirroring snapshot to restore")
            mirroredDesktopDisplayIDs.removeAll()
            let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_no_snapshot")
            if restored {
                desktopDisplaySpaceSnapshot.removeAll()
            }
            return restored
        }

        captureDisplaySpaceSnapshot(
            for: desktopMirroringSnapshot.keys.sorted(),
            overwriteExisting: false
        )

        MirageLogger
            .host("Restoring \(desktopMirroringSnapshot.count) displays from mirroring (virtual display \(displayID))")

        return await withHostDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                MirageLogger.host("Display mirroring restore unavailable: failed to begin display configuration")
                return false
            }

            var successfullyRestored = 0

            var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            var onlineCount: UInt32 = 0
            CGGetOnlineDisplayList(16, &onlineIDs, &onlineCount)
            let onlineDisplays = Set(onlineIDs.prefix(Int(onlineCount)))
            for (displayID, mirroredDisplayID) in desktopMirroringSnapshot {
                guard onlineDisplays.contains(displayID) else {
                    MirageLogger.host("Skipping mirroring restore for offline display \(displayID)")
                    continue
                }
                let targetMirrorID: CGDirectDisplayID
                if mirroredDisplayID == 0 {
                    targetMirrorID = kCGNullDirectDisplay
                } else if onlineDisplays.contains(mirroredDisplayID) {
                    targetMirrorID = mirroredDisplayID
                } else {
                    targetMirrorID = kCGNullDirectDisplay
                    MirageLogger.host(
                        "Skipping restore to offline mirror target \(mirroredDisplayID); unmirroring display \(displayID) instead"
                    )
                }
                guard CGDisplayMirrorsDisplay(displayID) != targetMirrorID else { continue }

                let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetMirrorID)
                if result == .success { successfullyRestored += 1 } else {
                    MirageLogger.host("Failed to restore mirroring for display \(displayID): \(result)")
                }
            }

            if successfullyRestored > 0 {
                let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
                if completeResult != .success {
                    MirageLogger.host("Display mirroring restore unavailable: failed to complete configuration \(completeResult)")
                    CGCancelDisplayConfiguration(config)
                    return false
                } else {
                    MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
                    let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable")
                    mirroredDesktopDisplayIDs.removeAll()
                    desktopMirroringSnapshot.removeAll()
                    if restored {
                        desktopDisplaySpaceSnapshot.removeAll()
                    }
                    return restored
                }
            } else {
                CGCancelDisplayConfiguration(config)
                let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_noop")
                mirroredDesktopDisplayIDs.removeAll()
                desktopMirroringSnapshot.removeAll()
                if restored {
                    desktopDisplaySpaceSnapshot.removeAll()
                }
                return restored
            }
        }
    }

}

#endif
