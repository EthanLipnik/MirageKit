//
//  SharedVirtualDisplayManager+Acquisition.swift
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
    // MARK: - App Stream Shared Display

    /// Acquires the shared app-stream virtual display, creating it on first call.
    /// Increments the consumer reference count. Resizes only if the preset changed.
    func acquireAppStreamDisplay(
        preset: MirageDisplaySizePreset = .standard,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace
    )
    async throws -> DisplaySnapshot {
        let targetRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: refreshRate)

        if let existing = appStreamDisplay {
            appStreamConsumerCount += 1
            if preset != appStreamPreset {
                MirageLogger.host(
                    "App stream display preset changed \(appStreamPreset.displayName) → \(preset.displayName); resizing"
                )
                let newResolution = preset.pixelResolution
                if let updated = await updateDisplayInPlace(
                    display: existing,
                    newResolution: newResolution,
                    refreshRate: targetRefreshRate,
                    colorSpace: colorSpace
                ) {
                    appStreamDisplay = updated
                    appStreamPreset = preset
                    return snapshot(from: updated)
                }
                // In-place update failed; recreate
                let recreated = try await recreateDisplay(
                    from: existing,
                    newResolution: newResolution,
                    refreshRate: targetRefreshRate,
                    colorSpace: colorSpace,
                    displayNameOverride: "Mirage App Stream",
                    allowAspectMismatchRetinaCandidate: false,
                    preferFastRecreate: true
                )
                appStreamDisplay = recreated
                appStreamPreset = preset
                return snapshot(from: recreated)
            }
            MirageLogger.host("Reusing app stream display (consumers: \(appStreamConsumerCount))")
            return snapshot(from: existing)
        }

        // First consumer — create the display
        let resolution = preset.pixelResolution
        MirageLogger.host(
            "Creating app stream display at \(Int(resolution.width))x\(Int(resolution.height)) px (\(preset.displayName)), refresh=\(targetRefreshRate)Hz"
        )
        let created = try await createDisplay(
            resolution: resolution,
            refreshRate: targetRefreshRate,
            colorSpace: colorSpace,
            displayNameOverride: "Mirage App Stream",
            allowAspectMismatchRetinaCandidate: false
        )
        appStreamDisplay = created
        appStreamPreset = preset
        appStreamConsumerCount = 1
        return snapshot(from: created)
    }

    /// Decrements the app-stream consumer reference count, destroying when zero.
    func releaseAppStreamDisplay() async {
        appStreamConsumerCount = max(0, appStreamConsumerCount - 1)
        if appStreamConsumerCount > 0 {
            MirageLogger.host("App stream display released (remaining consumers: \(appStreamConsumerCount))")
            return
        }
        guard let display = appStreamDisplay else { return }
        MirageLogger.host("Destroying app stream display \(display.displayID) (no consumers)")
        appStreamDisplay = nil
        await destroyDisplay(display)
    }

    // MARK: - Dedicated Stream Displays

    func acquireDedicatedDisplay(
        for streamID: StreamID,
        resolution: CGSize,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace
    )
    async throws -> DisplaySnapshot {
        guard resolution.width > 0, resolution.height > 0 else {
            throw SharedDisplayError.creationFailed("Invalid dedicated display resolution")
        }
        let requestedRate = refreshRate
        let targetRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        let displayName = dedicatedDisplayName(for: streamID)

        MirageLogger
            .host(
                "Stream \(streamID) acquiring dedicated display at \(Int(resolution.width))x\(Int(resolution.height)) px, color=\(colorSpace.displayName), refresh=\(targetRefreshRate)Hz (requested \(requestedRate)Hz)"
            )

        if let existing = dedicatedDisplaysByStreamID[streamID] {
            let needsRefresh = existing.refreshRate != Double(targetRefreshRate)
            let requiresResize = needsResize(currentResolution: existing.resolution, targetResolution: resolution)

            if !needsRefresh, !requiresResize, existing.colorSpace == colorSpace {
                return snapshot(from: existing)
            }

            if existing.colorSpace != colorSpace {
                MirageLogger
                    .host(
                        "Recreating dedicated display for stream \(streamID) due to color space change (\(existing.colorSpace.displayName) → \(colorSpace.displayName))"
                    )
                let recreated = try await recreateDisplay(
                    from: existing,
                    newResolution: resolution,
                    refreshRate: targetRefreshRate,
                    colorSpace: colorSpace,
                    displayNameOverride: displayName,
                    allowAspectMismatchRetinaCandidate: true
                )
                dedicatedDisplaysByStreamID[streamID] = recreated
                return snapshot(from: recreated)
            }

            if let updated = await updateDisplayInPlace(
                display: existing,
                newResolution: resolution,
                refreshRate: targetRefreshRate,
                colorSpace: colorSpace
            ) {
                dedicatedDisplaysByStreamID[streamID] = updated
                return snapshot(from: updated)
            }

            MirageLogger
                .host(
                    "Dedicated display in-place update failed for stream \(streamID); attempting one-shot recreate fallback"
                )
            let recreated = try await recreateDisplay(
                from: existing,
                newResolution: resolution,
                refreshRate: targetRefreshRate,
                colorSpace: colorSpace,
                displayNameOverride: displayName,
                allowAspectMismatchRetinaCandidate: false,
                preferFastRecreate: true
            )
            dedicatedDisplaysByStreamID[streamID] = recreated
            return snapshot(from: recreated)
        }

        let created = try await createDisplay(
            resolution: resolution,
            refreshRate: targetRefreshRate,
            colorSpace: colorSpace,
            displayNameOverride: displayName,
            allowAspectMismatchRetinaCandidate: true
        )
        dedicatedDisplaysByStreamID[streamID] = created
        return snapshot(from: created)
    }

    func updateDedicatedDisplay(
        for streamID: StreamID,
        newResolution: CGSize,
        refreshRate: Int = 60
    )
    async throws -> DisplaySnapshot {
        guard newResolution.width > 0, newResolution.height > 0 else {
            throw SharedDisplayError.creationFailed("Invalid dedicated display resolution update")
        }
        let requestedRate = refreshRate
        let targetRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        guard let existing = dedicatedDisplaysByStreamID[streamID] else {
            throw SharedDisplayError.streamDisplayNotFound(streamID)
        }

        let needsRefresh = existing.refreshRate != Double(targetRefreshRate)
        let requiresResize = needsResize(currentResolution: existing.resolution, targetResolution: newResolution)
        guard needsRefresh || requiresResize else { return snapshot(from: existing) }

        if let updated = await updateDisplayInPlace(
            display: existing,
            newResolution: newResolution,
            refreshRate: targetRefreshRate,
            colorSpace: existing.colorSpace
        ) {
            dedicatedDisplaysByStreamID[streamID] = updated
            return snapshot(from: updated)
        }

        MirageLogger
            .host(
                "Dedicated display resize update failed for stream \(streamID); attempting one-shot recreate fallback"
            )
        let recreated = try await recreateDisplay(
            from: existing,
            newResolution: newResolution,
            refreshRate: targetRefreshRate,
            colorSpace: existing.colorSpace,
            displayNameOverride: dedicatedDisplayName(for: streamID),
            allowAspectMismatchRetinaCandidate: false,
            preferFastRecreate: true
        )
        dedicatedDisplaysByStreamID[streamID] = recreated
        return snapshot(from: recreated)
    }

    func releaseDedicatedDisplay(for streamID: StreamID) async {
        guard let display = dedicatedDisplaysByStreamID.removeValue(forKey: streamID) else {
            MirageLogger.host("Stream \(streamID) had no dedicated display to release")
            return
        }

        MirageLogger.host("Releasing dedicated display \(display.displayID) for stream \(streamID)")
        await destroyDisplay(display)
    }
}
#endif
