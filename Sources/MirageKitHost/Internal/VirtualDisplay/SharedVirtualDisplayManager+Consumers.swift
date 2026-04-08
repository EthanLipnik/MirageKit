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

    private func syncActiveConsumerColorSpace(
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

    /// Acquire the shared virtual display for a non-stream purpose (login display, unlock, desktop stream)
    /// Creates the display if this is the first consumer, otherwise returns existing
    /// - Parameters:
    ///   - consumer: The consumer type acquiring the display
    ///   - resolution: Optional resolution for the display (used by desktop streaming; capture/encoder enforce the 5K
    /// cap)
    ///   - refreshRate: Refresh rate in Hz (default 60, use 120 for high refresh rate clients)
    /// - Returns: The managed display context
    func acquireDisplayForConsumer(
        _ consumer: DisplayConsumer,
        resolution: CGSize? = nil,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace = .displayP3,
        allowActiveUpdate: Bool = false,
        creationPolicy: DisplayCreationPolicy = .adaptiveRetinaThenFallback1xAndColor
    )
    async throws -> DisplaySnapshot {
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
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        let requestedRate = refreshRate
        let refreshRate = consumer == .desktopStream
            ? SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
            : resolvedRefreshRate(requestedRate)
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
                    creationPolicy: creationPolicy
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
                            creationPolicy: creationPolicy
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
                    creationPolicy: creationPolicy
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
                    creationPolicy: creationPolicy
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
                    creationPolicy: creationPolicy
                )
            } else {
                let currentResolution = sharedDisplay!.resolution
                let needsRefresh = sharedDisplay?.refreshRate != Double(refreshRate)
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
                            creationPolicy: creationPolicy
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
                creationPolicy: creationPolicy
            )
        }

        guard let display = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }
        syncActiveConsumerColorSpace(consumer, to: display.colorSpace)

        return snapshot(from: display)
    }

    /// Release the display for a non-stream consumer
    /// Destroys the display if this was the last consumer
    /// - Parameter consumer: The consumer type releasing the display
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

    /// Update the display resolution for a consumer (used for desktop streaming resize)
    /// This updates the existing display's resolution in place without recreation
    /// - Parameters:
    ///   - consumer: The consumer requesting the resize
    ///   - newResolution: The new resolution to resize to
    ///   - refreshRate: Refresh rate in Hz (default 60)
    private func recreateSharedDisplayForResolutionChange(
        consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        resizeRequest: DesktopVirtualDisplayResizeRequest?
    ) async throws -> Bool {
        if consumer == .desktopStream,
           let resizeRequest,
           let cachedTarget = cachedDesktopVirtualDisplayResizeTarget(for: resizeRequest) {
            do {
                MirageLogger.host(
                    "Retrying desktop resize with cached target: " +
                        "\(cachedTarget.pixelWidth)x\(cachedTarget.pixelHeight) px, " +
                        "\(cachedTarget.refreshRate)Hz, \(cachedTarget.colorSpace.displayName)"
                )
                sharedDisplay = try await recreateDisplay(
                    newResolution: CGSize(
                        width: cachedTarget.pixelWidth,
                        height: cachedTarget.pixelHeight
                    ),
                    refreshRate: cachedTarget.refreshRate,
                    colorSpace: cachedTarget.colorSpace,
                    preferFastRecreate: false,
                    creationPolicy: .singleAttempt(hiDPI: cachedTarget.hiDPI)
                )
                if let updatedDisplay = sharedDisplay {
                    recordDesktopVirtualDisplayResizeTargetSuccess(
                        snapshot: snapshot(from: updatedDisplay),
                        for: resizeRequest
                    )
                }
                return true
            } catch {
                clearDesktopVirtualDisplayResizeTarget(for: resizeRequest)
                MirageLogger.error(
                    .host,
                    "Cached desktop resize target failed; cleared cache and falling back: \(error)"
                )
            }
        }

        if consumer == .desktopStream {
            do {
                MirageLogger.host("Desktop resize recreating shared display (guarded path)")
                sharedDisplay = try await recreateDisplay(
                    newResolution: newResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    preferFastRecreate: false
                )
            } catch {
                MirageLogger
                    .error(
                        .host,
                        "Desktop resize guarded recreate failed; retrying fast recreate path: \(error)"
                    )
                sharedDisplay = try await recreateDisplay(
                    newResolution: newResolution,
                    refreshRate: refreshRate,
                    colorSpace: colorSpace,
                    preferFastRecreate: true
                )
            }
        } else {
            sharedDisplay = try await recreateDisplay(
                newResolution: newResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace,
                preferFastRecreate: false
            )
        }

        if consumer == .desktopStream,
           let resizeRequest,
           let updatedDisplay = sharedDisplay {
            recordDesktopVirtualDisplayResizeTargetSuccess(
                snapshot: snapshot(from: updatedDisplay),
                for: resizeRequest
            )
        }
        return false
    }

    func updateDisplayResolution(
        for consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int = 60,
        resizeRequest: DesktopVirtualDisplayResizeRequest? = nil,
        allowRecreation: Bool = true
    )
    async throws -> DisplayResolutionUpdateResult {
        let requestedRate = refreshRate
        let refreshRate: Int = switch consumer {
        case .desktopStream:
            SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        default:
            resolvedRefreshRate(requestedRate)
        }
        guard let existingInfo = activeConsumers[consumer] else {
            MirageLogger.error(.host, "Cannot update resolution: consumer \(consumer) not found")
            return DisplayResolutionUpdateResult(
                outcome: .noChange,
                usedCachedResizeTarget: false,
                generationChanged: false
            )
        }

        guard let display = sharedDisplay else {
            MirageLogger.error(.host, "Cannot update resolution: no active display")
            return DisplayResolutionUpdateResult(
                outcome: .noChange,
                usedCachedResizeTarget: false,
                generationChanged: false
            )
        }
        let previousGeneration = display.generation

        let requestedColorSpace = existingInfo.colorSpace
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: newResolution,
            windowID: existingInfo.windowID,
            colorSpace: requestedColorSpace,
            acquiredAt: existingInfo.acquiredAt
        )

        // Check for color space mismatch - requires recreation
        if display.colorSpace != requestedColorSpace {
            guard allowRecreation else {
                return DisplayResolutionUpdateResult(
                    outcome: .requiresRecreation,
                    usedCachedResizeTarget: false,
                    generationChanged: false
                )
            }
            MirageLogger
                .host(
                    "Display color space mismatch (\(display.colorSpace.displayName) → \(requestedColorSpace.displayName)); recreating"
                )
            let usedCachedResizeTarget = try await recreateSharedDisplayForResolutionChange(
                consumer: consumer,
                newResolution: newResolution,
                refreshRate: refreshRate,
                colorSpace: requestedColorSpace,
                resizeRequest: resizeRequest
            )
            if let updatedDisplay = sharedDisplay {
                syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
            }
            let generationChanged = (sharedDisplay?.generation ?? previousGeneration) != previousGeneration
            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
            return DisplayResolutionUpdateResult(
                outcome: .recreated,
                usedCachedResizeTarget: usedCachedResizeTarget,
                generationChanged: generationChanged
            )
        }

        // Check if refresh rate or resolution needs updating
        let needsRefresh = display.refreshRate != Double(refreshRate)
        let requiresResize = needsResize(currentResolution: display.resolution, targetResolution: newResolution)

        guard needsRefresh || requiresResize else {
            if let updatedDisplay = sharedDisplay {
                syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
            }
            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
            return DisplayResolutionUpdateResult(
                outcome: .noChange,
                usedCachedResizeTarget: false,
                generationChanged: false
            )
        }

        MirageLogger
            .host(
                "Updating display \(display.displayID) for \(consumer) to \(Int(newResolution.width))x\(Int(newResolution.height))@\(refreshRate)Hz"
            )

        let updated = await updateDisplayInPlace(
            newResolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: requestedColorSpace
        )

        if updated {
            if consumer == .desktopStream,
               let resizeRequest,
               let updatedDisplay = sharedDisplay {
                recordDesktopVirtualDisplayResizeTargetSuccess(
                    snapshot: snapshot(from: updatedDisplay),
                    for: resizeRequest
                )
            }
            if let updatedDisplay = sharedDisplay {
                syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
            }
            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
            return DisplayResolutionUpdateResult(
                outcome: .updatedInPlace,
                usedCachedResizeTarget: false,
                generationChanged: false
            )
        }

        if needsRefresh {
            MirageLogger.host("In-place refresh rate update failed, recreating display")
        } else {
            MirageLogger.host("In-place resize failed, recreating display")
        }

        guard allowRecreation else {
            return DisplayResolutionUpdateResult(
                outcome: .requiresRecreation,
                usedCachedResizeTarget: false,
                generationChanged: false
            )
        }

        let usedCachedResizeTarget = try await recreateSharedDisplayForResolutionChange(
            consumer: consumer,
            newResolution: newResolution,
            refreshRate: refreshRate,
            colorSpace: requestedColorSpace,
            resizeRequest: resizeRequest
        )

        if let updatedDisplay = sharedDisplay {
            syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
        }
        let generationChanged = (sharedDisplay?.generation ?? previousGeneration) != previousGeneration
        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
        return DisplayResolutionUpdateResult(
            outcome: .recreated,
            usedCachedResizeTarget: usedCachedResizeTarget,
            generationChanged: generationChanged
        )
    }
}
#endif
