//
//  MirageHostService+DesktopMirroring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation
import Network

#if os(macOS)
import ScreenCaptureKit

extension MirageHostService {
    func resolvePrimaryPhysicalDisplayID() -> CGDirectDisplayID? {
        let mainDisplayID = CGMainDisplayID()
        if !platformVirtualDisplayBackend.isVirtualDisplay(mainDisplayID) { return mainDisplayID }

        return platformVirtualDisplayBackend.onlineDisplayIDs()
            .first { !platformVirtualDisplayBackend.isVirtualDisplay($0) }
    }

    func resolvePrimaryNonMirageDisplayID() -> CGDirectDisplayID? {
        return primaryNonMirageDisplayID(
            mainDisplayID: CGMainDisplayID(),
            onlineDisplayIDs: platformVirtualDisplayBackend.onlineDisplayIDs(),
            isMirageDisplay: { platformVirtualDisplayBackend.isMirageDisplay($0) }
        )
    }

    func captureDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID])
    -> [CGDirectDisplayID: CGDirectDisplayID] {
        var snapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for displayID in displayIDs {
            snapshot[displayID] = platformVirtualDisplayBackend.mirroredDisplay(displayID)
        }
        return snapshot
    }

    func isDisplayMirroringRestored(targetDisplayID: CGDirectDisplayID) -> Bool {
        let displaysToMirror = platformVirtualDisplayBackend.displaysToMirror(excludingDisplayID: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return true }
        let mirroredCount = displaysToMirror.count(
            where: { platformVirtualDisplayBackend.mirroredDisplay($0) == targetDisplayID }
        )
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

            let displaysToMirror = platformVirtualDisplayBackend.displaysToMirror(excludingDisplayID: targetDisplayID)
            let mirroredCount = displaysToMirror.count(
                where: { platformVirtualDisplayBackend.mirroredDisplay($0) == targetDisplayID }
            )

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
        let displays = platformVirtualDisplayBackend.onlineDisplayIDs()
        guard !displays.isEmpty else { return }

        let physicalDisplaysMirroringVirtual = displays.compactMap { displayID -> CGDirectDisplayID? in
            guard !platformVirtualDisplayBackend.isVirtualDisplay(displayID) else { return nil }
            let mirroredDisplayID = platformVirtualDisplayBackend.mirroredDisplay(displayID)
            guard mirroredDisplayID != kCGNullDirectDisplay,
                  platformVirtualDisplayBackend.isVirtualDisplay(mirroredDisplayID) else {
                return nil
            }
            if let targetDisplayID, mirroredDisplayID != targetDisplayID {
                return nil
            }
            return displayID
        }

        guard !physicalDisplaysMirroringVirtual.isEmpty else { return }

        let requests = physicalDisplaysMirroringVirtual.map {
            MirageHostDisplayMirroringRequest(
                displayID: $0,
                mirroredDisplayID: kCGNullDirectDisplay
            )
        }
        let result = await platformVirtualDisplayBackend.applyDisplayMirroring(requests)
        for (displayID, error) in result.failedDisplayErrors {
            MirageLogger.host("Physical display unmirror skipped display \(displayID): \(error)")
        }
        guard result.completed else {
            MirageLogger.host(
                "Physical display unmirror unavailable: \(result.failureDescription ?? "no displays accepted unmirroring configuration")"
            )
            return
        }
        MirageLogger.host("Unmirrored \(result.committedDisplayIDs.count) physical displays from virtual displays")
    }

    /// Set up display mirroring so every non-Mirage display mirrors the target display.
    /// Normal desktop streams target the shared virtual display; host-resolution streams target the main display.
    func setupDisplayMirroring(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize? = nil,
        requiresResidualMirageDisplaysClear: Bool = true
    )
    async -> Bool {
        let displaysToMirror = platformVirtualDisplayBackend.displaysToMirror(excludingDisplayID: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return true
        }

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

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: false)

        let mirroredDisplayIDs = displaysToMirror.filter {
            platformVirtualDisplayBackend.mirroredDisplay($0) == targetDisplayID
        }
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

        let alreadyMirrored = Set(mirroredDisplayIDs)
        let mirrorRequests = displaysToMirror
            .filter { !alreadyMirrored.contains($0) }
            .map {
                MirageHostDisplayMirroringRequest(
                    displayID: $0,
                    mirroredDisplayID: targetDisplayID
                )
            }
        let result = await platformVirtualDisplayBackend.applyDisplayMirroring(mirrorRequests)
        for (displayID, error) in result.failedDisplayErrors {
            MirageLogger.host("Display mirroring setup skipped display \(displayID): \(error)")
        }
        guard result.completed else {
            MirageLogger.host(
                "Display mirroring setup unavailable: \(result.failureDescription ?? "no displays accepted mirroring configuration")"
            )
            return false
        }

        for displayID in result.committedDisplayIDs {
            MirageLogger.host("Configured display \(displayID) to mirror target display \(targetDisplayID)")
        }

        let successfullyMirrored = alreadyMirrored.union(result.committedDisplayIDs)
        mirroredDesktopDisplayIDs = successfullyMirrored
        MirageLogger
            .host(
                "Display mirroring enabled for \(successfullyMirrored.count) displays → target display \(targetDisplayID)"
            )
        _ = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup")
        return successfullyMirrored.count == displaysToMirror.count
    }

    /// Temporarily suspend desktop mirroring before a virtual-display resize.
    /// This keeps resize transactions deterministic and avoids resize+mirror contention.
    func suspendDisplayMirroringForResize(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = platformVirtualDisplayBackend.displaysToMirror(excludingDisplayID: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return }

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: true)

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        let mirroredToTarget = displaysToMirror.filter {
            platformVirtualDisplayBackend.mirroredDisplay($0) == targetDisplayID
        }
        guard !mirroredToTarget.isEmpty else { return }

        let requests = mirroredToTarget.map {
            MirageHostDisplayMirroringRequest(
                displayID: $0,
                mirroredDisplayID: kCGNullDirectDisplay
            )
        }
        let result = await platformVirtualDisplayBackend.applyDisplayMirroring(requests)
        for (displayID, error) in result.failedDisplayErrors {
            MirageLogger.host("Display mirroring suspend skipped display \(displayID): \(error)")
        }
        guard result.completed else {
            MirageLogger.host(
                "Display mirroring suspend unavailable: \(result.failureDescription ?? "no displays accepted suspend configuration")"
            )
            return
        }

        mirroredDesktopDisplayIDs.removeAll()
        MirageLogger.host("Temporarily suspended mirroring for \(result.committedDisplayIDs.count) displays before resize")
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

        let onlineDisplays = Set(platformVirtualDisplayBackend.onlineDisplayIDs())
        let requests = desktopMirroringSnapshot.compactMap { displayID, mirroredDisplayID -> MirageHostDisplayMirroringRequest? in
            guard onlineDisplays.contains(displayID) else {
                MirageLogger.host("Skipping mirroring restore for offline display \(displayID)")
                return nil
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
            guard platformVirtualDisplayBackend.mirroredDisplay(displayID) != targetMirrorID else { return nil }

            return MirageHostDisplayMirroringRequest(
                displayID: displayID,
                mirroredDisplayID: targetMirrorID
            )
        }

        guard !requests.isEmpty else {
            let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_noop")
            mirroredDesktopDisplayIDs.removeAll()
            desktopMirroringSnapshot.removeAll()
            if restored {
                desktopDisplaySpaceSnapshot.removeAll()
            }
            return restored
        }

        let result = await platformVirtualDisplayBackend.applyDisplayMirroring(requests)
        for (displayID, error) in result.failedDisplayErrors {
            MirageLogger.host("Failed to restore mirroring for display \(displayID): \(error)")
        }
        guard result.completed else {
            MirageLogger.host(
                "Display mirroring restore unavailable: \(result.failureDescription ?? "no displays accepted restore configuration")"
            )
            return false
        }

        MirageLogger.host("Display mirroring disabled for \(result.committedDisplayIDs.count) displays")
        let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable")
        mirroredDesktopDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
        if restored {
            desktopDisplaySpaceSnapshot.removeAll()
        }
        return restored
    }

}

#endif
