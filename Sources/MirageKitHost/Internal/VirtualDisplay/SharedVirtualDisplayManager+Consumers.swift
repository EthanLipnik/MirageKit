//
//  SharedVirtualDisplayManager+Consumers.swift
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
    // MARK: - Consumer-Based Acquisition (for non-stream consumers)

    /// Result of probing whether the virtual display is presenting at the requested cadence.
    struct VirtualDisplayCadenceValidation: Sendable, Equatable {
        /// Requested frame cadence in frames per second.
        let targetFPS: Double
        /// Measured display cadence, or `nil` when probing was unavailable.
        let observedFPS: Double?
        /// Whether the display cadence is close enough to drive capture from native display updates.
        let usesNativeDisplayCadence: Bool

        /// Compact diagnostic label used in host logs.
        var logLabel: String {
            let observedText = observedFPS
                .map { $0.formatted(.number.precision(.fractionLength(1))) }
                ?? "unavailable"
            return "target=\(Int(targetFPS))Hz observed=\(observedText)Hz nativeCadence=\(usesNativeDisplayCadence)"
        }
    }

    /// Updates the tracked color space for an active consumer after display creation falls back.
    func syncActiveConsumerColorSpace(
        _ consumer: DisplayConsumer,
        to colorSpace: MirageColorSpace
    ) {
        guard let info = activeConsumers[consumer], info.colorSpace != colorSpace else { return }
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: info.resolution,
            windowID: info.windowID,
            colorSpace: colorSpace,
            acquiredAt: info.acquiredAt
        )
        MirageLogger
            .host(
                "Consumer \(consumer) using fallback color space \(colorSpace.displayName) for shared display"
            )
    }

    /// Acquires the shared virtual display for a non-stream purpose.
    ///
    /// Unlock, desktop streaming, and benchmark consumers share one display instance. The manager creates the display
    /// for the first consumer and returns the existing display for later consumers unless `allowActiveUpdate` permits
    /// changing the active display mode.
    /// - Parameters:
    ///   - consumer: Consumer type acquiring the display.
    ///   - resolution: Optional display resolution; capture and encoder setup still enforce the host cap.
    ///   - refreshRate: Requested refresh rate in Hz.
    /// - Returns: The managed display snapshot.
    func acquireDisplayForConsumer(
        _ consumer: DisplayConsumer,
        resolution: CGSize? = nil,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace = .displayP3,
        allowActiveUpdate: Bool = false,
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async throws -> DisplaySnapshot {
        try startupBudget?.checkAvailable()
        // Force-destroy any orphaned displays from previous sessions before
        // acquiring.  Orphans block virtual display creation until the OS
        // reclaims them, which can take minutes after an unclean teardown.
        if !orphanedDisplayIDs.isEmpty {
            MirageLogger.host(
                "Cleaning up \(orphanedDisplayIDs.count) orphaned display(s) before acquisition: \(orphanedDisplayIDs)"
            )
            var survivingOrphans: Set<CGDirectDisplayID> = []
            for orphanID in orphanedDisplayIDs {
                CGVirtualDisplayBridge.forceInvalidateOrphan(orphanID)
                if CGVirtualDisplayBridge.isDisplayOnline(orphanID) {
                    survivingOrphans.insert(orphanID)
                }
            }
            orphanedDisplayIDs = survivingOrphans
            if !survivingOrphans.isEmpty {
                MirageLogger.host(
                    "Virtual display orphan cleanup left \(survivingOrphans.count) display(s) online; keeping them tracked: \(survivingOrphans)"
                )
                let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(500) ?? 500
                try await Task.sleep(for: .milliseconds(boundedDelayMs))
                try startupBudget?.checkAvailable()
            }
        }

        let requestedRate = refreshRate
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        // Use provided resolution or fall back to default
        let targetResolution = resolution ?? CGSize(width: 2880, height: 1800)
        let previousGeneration = sharedDisplay?.generation ?? 0

        // Check if this consumer already has the display
        if let existingInfo = activeConsumers[consumer], let display = sharedDisplay {
            guard allowActiveUpdate else {
                MirageLogger.host("\(consumer) already has shared display, returning existing")
                return snapshot(from: display)
            }

            activeConsumers[consumer] = ClientDisplayInfo(
                resolution: targetResolution,
                windowID: existingInfo.windowID,
                colorSpace: colorSpace,
                acquiredAt: existingInfo.acquiredAt
            )

            if display.colorSpace != colorSpace {
                MirageLogger
                    .host(
                        "Recreating shared display for color space change (\(display.colorSpace.displayName) → \(colorSpace.displayName))"
                    )
                sharedDisplay = try await recreateDisplay(
                    newResolution: targetResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    creationPolicy: creationPolicy,
                    startupBudget: startupBudget
                )
            } else {
                let needsRefresh = display.refreshRate != Double(refreshRate)
                let requiresResize = needsResize(currentResolution: display.resolution, targetResolution: targetResolution)

                if needsRefresh || requiresResize {
                    let desiredResolution = requiresResize ? targetResolution : display.resolution
                    let updated = await updateDisplayInPlace(
                        newResolution: desiredResolution,
                        refreshRate: refreshRate,
                        colorSpace: colorSpace
                    )

                    if !updated {
                        if needsRefresh {
                            MirageLogger
                                .host(
                                    "Recreating shared display for refresh rate change (\(display.refreshRate) → \(Double(refreshRate)))"
                                )
                        } else {
                            MirageLogger
                                .host(
                                    "Resizing shared display from \(Int(display.resolution.width))x\(Int(display.resolution.height)) to \(Int(targetResolution.width))x\(Int(targetResolution.height))"
                                )
                        }
                        sharedDisplay = try await recreateDisplay(
                            newResolution: targetResolution,
                            refreshRate: refreshRate,
                            colorSpace: colorSpace,
                            creationPolicy: creationPolicy,
                            startupBudget: startupBudget
                        )
                    }
                }
            }

            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)

            if sharedDisplay == nil {
                MirageLogger.host(
                    "Shared display lost during update for \(consumer); re-creating"
                )
                sharedDisplay = try await createDisplay(
                    resolution: targetResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    creationPolicy: creationPolicy,
                    startupBudget: startupBudget
                )
            }

            guard let updatedDisplay = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }
            syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
            return snapshot(from: updatedDisplay)
        }

        // Track in-flight acquisition so releaseDisplayForConsumer does not
        // destroy the display while we are across an await boundary.
        pendingAcquisitionCount += 1
        defer { pendingAcquisitionCount -= 1 }

        // Register this consumer with the target resolution
        let previousConsumerInfo = activeConsumers[consumer]
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: targetResolution,
            windowID: previousConsumerInfo?.windowID ?? 0,
            colorSpace: colorSpace,
            acquiredAt: previousConsumerInfo?.acquiredAt ?? Date()
        )

        MirageLogger
            .host(
                "\(consumer) acquiring shared display at \(Int(targetResolution.width))x\(Int(targetResolution.height))@\(refreshRate)Hz, color=\(colorSpace.displayName) (requested \(requestedRate)Hz). Consumers: \(activeConsumers.count)"
            )

        do {
            // Create display if needed, or resize if resolution differs
            if sharedDisplay == nil {
                sharedDisplay = try await createDisplay(
                    resolution: targetResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    creationPolicy: creationPolicy,
                    startupBudget: startupBudget
                )
            } else if sharedDisplay?.colorSpace != colorSpace {
                MirageLogger
                    .host(
                        "Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))"
                    )
                sharedDisplay = try await recreateDisplay(
                    newResolution: targetResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    creationPolicy: creationPolicy,
                    startupBudget: startupBudget
                )
            } else {
                guard let display = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }
                let currentResolution = display.resolution
                let needsRefresh = display.refreshRate != Double(refreshRate)
                let requiresResize = needsResize(currentResolution: currentResolution, targetResolution: targetResolution)

                if needsRefresh || requiresResize {
                    let desiredResolution = requiresResize ? targetResolution : currentResolution
                    let updated = await updateDisplayInPlace(
                        newResolution: desiredResolution,
                        refreshRate: refreshRate,
                        colorSpace: colorSpace
                    )

                    if !updated {
                        if needsRefresh {
                            MirageLogger
                                .host(
                                    "Recreating shared display for refresh rate change (\(sharedDisplay?.refreshRate ?? 0) → \(Double(refreshRate)))"
                                )
                        } else {
                            MirageLogger
                                .host(
                                    "Resizing shared display from \(Int(currentResolution.width))x\(Int(currentResolution.height)) to \(Int(targetResolution.width))x\(Int(targetResolution.height))"
                                )
                        }
                        sharedDisplay = try await recreateDisplay(
                            newResolution: targetResolution,
                            refreshRate: refreshRate,
                            colorSpace: colorSpace,
                            creationPolicy: creationPolicy,
                            startupBudget: startupBudget
                        )
                    }
                }
            }
        } catch {
            if let previousConsumerInfo {
                activeConsumers[consumer] = previousConsumerInfo
            } else {
                activeConsumers.removeValue(forKey: consumer)
            }
            throw error
        }

        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)

        // A concurrent release may have destroyed the display while we were
        // creating or resizing across an await boundary.  Re-create once
        // rather than surfacing a transient .noActiveDisplay error.
        if sharedDisplay == nil, activeConsumers[consumer] != nil {
            MirageLogger.host(
                "Shared display lost during acquisition for \(consumer); re-creating"
            )
            sharedDisplay = try await createDisplay(
                resolution: targetResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace,
                creationPolicy: creationPolicy,
                startupBudget: startupBudget
            )
        }

        guard let display = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }
        syncActiveConsumerColorSpace(consumer, to: display.colorSpace)

        return snapshot(from: display)
    }

    /// Releases a non-stream display consumer and destroys the shared display once no consumers remain.
    func releaseDisplayForConsumer(_ consumer: DisplayConsumer) async {
        guard activeConsumers.removeValue(forKey: consumer) != nil else {
            MirageLogger.host("\(consumer) was not using shared display")
            return
        }

        MirageLogger.host("\(consumer) released shared display. Remaining consumers: \(activeConsumers.count)")

        if activeConsumers.isEmpty, pendingAcquisitionCount == 0 {
            await destroyDisplay()
        } else if activeConsumers.isEmpty {
            MirageLogger.host(
                "Skipping display teardown: \(pendingAcquisitionCount) acquisition(s) still in flight"
            )
        }
    }

    /// Samples Core Graphics display timing and decides whether the shared display is using native cadence.
    func validateDisplayCadence(
        _ snapshot: DisplaySnapshot,
        targetFrameRate: Int,
        durationSeconds: Double = 0.35
    ) async -> VirtualDisplayCadenceValidation {
        let targetFPS = Double(max(1, targetFrameRate))
        guard let cadenceProbe = VirtualDisplayCadenceProbe(displayID: snapshot.displayID),
              cadenceProbe.start() else {
            MirageLogger.host(
                "Virtual display cadence validation unavailable for display \(snapshot.displayID); using explicit SCK frame interval"
            )
            return VirtualDisplayCadenceValidation(
                targetFPS: targetFPS,
                observedFPS: nil,
                usesNativeDisplayCadence: false
            )
        }

        let clampedDuration = max(0.10, min(durationSeconds, 1.0))
        cadenceProbe.beginMeasurement()
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            try await Task.sleep(for: .milliseconds(Int((clampedDuration * 1000).rounded())))
        } catch {
            cadenceProbe.stop()
            return VirtualDisplayCadenceValidation(
                targetFPS: targetFPS,
                observedFPS: nil,
                usesNativeDisplayCadence: false
            )
        }
        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startedAt)
        let observedFPS = cadenceProbe.completeMeasurement(durationSeconds: elapsed)
        cadenceProbe.stop()
        let usesNativeDisplayCadence = observedFPS.map { $0 >= targetFPS * 0.85 } ?? false
        let validation = VirtualDisplayCadenceValidation(
            targetFPS: targetFPS,
            observedFPS: observedFPS,
            usesNativeDisplayCadence: usesNativeDisplayCadence
        )
        MirageLogger.host(
            "Virtual display cadence validation for display \(snapshot.displayID): \(validation.logLabel)"
        )
        return validation
    }

}
#endif
