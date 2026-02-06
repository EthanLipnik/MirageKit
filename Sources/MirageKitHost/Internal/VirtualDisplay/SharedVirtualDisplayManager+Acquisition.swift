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
    // MARK: - Display Acquisition

    /// Acquire the shared virtual display for a stream
    /// Creates the display if this is the first client, otherwise returns existing
    /// - Parameters:
    ///   - streamID: The stream acquiring the display
    ///   - clientResolution: The client's display resolution
    ///   - windowID: The window being streamed
    ///   - refreshRate: Refresh rate in Hz (default 60)
    /// - Returns: The managed display context
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func acquireDisplay(
        for streamID: StreamID,
        clientResolution: CGSize,
        windowID: WindowID,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace
    )
    async throws -> DisplaySnapshot {
        let requestedRate = refreshRate
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        let consumer = DisplayConsumer.stream(streamID)

        // Check if this consumer already has the display
        if activeConsumers[consumer] != nil, let display = sharedDisplay {
            MirageLogger.host("Stream \(streamID) already has shared display, returning existing")
            return snapshot(from: display)
        }

        // Register this consumer
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: clientResolution,
            windowID: windowID,
            colorSpace: colorSpace,
            acquiredAt: Date()
        )

        // Calculate optimal resolution (fixed 3K)
        let optimalResolution = calculateOptimalResolution()
        let previousGeneration = sharedDisplay?.generation ?? 0

        MirageLogger
            .host(
                "Stream \(streamID) acquiring shared display. Consumers: \(activeConsumers.count), client res: \(Int(clientResolution.width))x\(Int(clientResolution.height)) → virtual display: \(Int(optimalResolution.width))x\(Int(optimalResolution.height)), color=\(colorSpace.displayName), refresh=\(refreshRate)Hz (requested \(requestedRate)Hz)"
            )

        // Create or resize display as needed
        if sharedDisplay == nil {
            // First consumer - create the display
            sharedDisplay = try await createDisplay(
                resolution: optimalResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace
            )
        } else if sharedDisplay?.colorSpace != colorSpace {
            MirageLogger
                .host(
                    "Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))"
                )
            sharedDisplay = try await recreateDisplay(
                newResolution: optimalResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace
            )
        } else {
            let currentResolution = sharedDisplay!.resolution
            let needsRefresh = sharedDisplay?.refreshRate != Double(refreshRate)
            let requiresResize = needsResize(currentResolution: currentResolution, targetResolution: optimalResolution)

            if needsRefresh || requiresResize {
                let targetResolution = requiresResize ? optimalResolution : currentResolution
                let updated = await updateDisplayInPlace(
                    newResolution: targetResolution,
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
                                "Resizing shared display from \(Int(currentResolution.width))x\(Int(currentResolution.height)) to \(Int(optimalResolution.width))x\(Int(optimalResolution.height))"
                            )
                    }
                    sharedDisplay = try await recreateDisplay(
                        newResolution: optimalResolution,
                        refreshRate: refreshRate,
                        colorSpace: colorSpace
                    )
                }
            }
        }

        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)

        guard let display = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }

        return snapshot(from: display)
    }

    /// Release the shared display for a stream
    /// Destroys the display if this was the last consumer
    /// - Parameter streamID: The stream releasing the display
    func releaseDisplay(for streamID: StreamID) async {
        let consumer = DisplayConsumer.stream(streamID)
        guard activeConsumers.removeValue(forKey: consumer) != nil else {
            MirageLogger.host("Stream \(streamID) was not using shared display")
            return
        }

        MirageLogger.host("Stream \(streamID) released shared display. Remaining consumers: \(activeConsumers.count)")

        if activeConsumers.isEmpty {
            // Last consumer - destroy the display
            await destroyDisplay()
        }
        // Note: We don't downsize when consumers leave to avoid disruption
        // The display will be destroyed when all consumers leave
    }
}
#endif
