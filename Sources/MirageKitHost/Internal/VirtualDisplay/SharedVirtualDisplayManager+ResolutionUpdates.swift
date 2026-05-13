//
//  SharedVirtualDisplayManager+ResolutionUpdates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    /// Recreates the shared display when a live consumer requests a different size, cadence, or color space.
    private func recreateSharedDisplayForResolutionChange(
        consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        resizeRequest: DesktopVirtualDisplayResizeRequest?
    ) async throws {
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
                return
            } catch {
                clearDesktopVirtualDisplayResizeTarget(for: resizeRequest)
                MirageLogger.host("Cached desktop resize target failed; cleared cache and falling back: \(error)")
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
                    .host(
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
    }

    /// Updates the shared display resolution for an active consumer while preserving the consumer lease.
    ///
    /// The manager first attempts an in-place mode update. If that fails and recreation is allowed, it recreates the
    /// shared display while preserving the consumer's requested color space and resize-target cache behavior.
    func updateDisplayResolution(
        for consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int = 60,
        resizeRequest: DesktopVirtualDisplayResizeRequest? = nil,
        allowRecreation: Bool = true
    )
    async throws -> DisplayResolutionUpdateResult {
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: refreshRate)
        guard let existingInfo = activeConsumers[consumer] else {
            MirageLogger.error(.host, "Cannot update resolution: consumer \(consumer) not found")
            return DisplayResolutionUpdateResult(
                outcome: .noChange,
                generationChanged: false
            )
        }

        let requestedColorSpace = existingInfo.colorSpace
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: newResolution,
            windowID: existingInfo.windowID,
            colorSpace: requestedColorSpace,
            acquiredAt: existingInfo.acquiredAt
        )

        guard let display = sharedDisplay else {
            if !allowRecreation {
                MirageLogger.host(
                    "Shared display missing during resolution update for \(consumer); recreation required"
                )
                return DisplayResolutionUpdateResult(
                    outcome: .requiresRecreation,
                    generationChanged: false
                )
            }

            MirageLogger.host(
                "Shared display missing during resolution update for \(consumer); recreating from requested state"
            )
            try await recreateSharedDisplayForResolutionChange(
                consumer: consumer,
                newResolution: newResolution,
                refreshRate: refreshRate,
                colorSpace: requestedColorSpace,
                resizeRequest: resizeRequest
            )
            if let updatedDisplay = sharedDisplay {
                syncActiveConsumerColorSpace(consumer, to: updatedDisplay.colorSpace)
            }
            return DisplayResolutionUpdateResult(
                outcome: .recreated,
                generationChanged: true
            )
        }
        let previousGeneration = display.generation

        // Check for color space mismatch - requires recreation
        if display.colorSpace != requestedColorSpace {
            guard allowRecreation else {
                return DisplayResolutionUpdateResult(
                    outcome: .requiresRecreation,
                    generationChanged: false
                )
            }
            MirageLogger
                .host(
                    "Display color space mismatch (\(display.colorSpace.displayName) → \(requestedColorSpace.displayName)); recreating"
                )
            try await recreateSharedDisplayForResolutionChange(
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
                generationChanged: false
            )
        }

        try await recreateSharedDisplayForResolutionChange(
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
            generationChanged: generationChanged
        )
    }
}
#endif
