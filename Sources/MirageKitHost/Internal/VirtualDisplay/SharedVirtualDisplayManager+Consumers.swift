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

    /// Acquire the shared virtual display for a non-stream purpose (login display, unlock, desktop stream)
    /// Creates the display if this is the first consumer, otherwise returns existing
    /// - Parameters:
    ///   - consumer: The consumer type acquiring the display
    ///   - resolution: Optional resolution for the display (used by desktop streaming; capture/encoder enforce the 5K
    /// cap)
    ///   - refreshRate: Refresh rate in Hz (default 60, use 120 for high refresh rate clients)
    /// - Returns: The managed display context
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func acquireDisplayForConsumer(
        _ consumer: DisplayConsumer,
        resolution: CGSize? = nil,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace = .displayP3,
        allowActiveUpdate: Bool = false
    )
    async throws -> DisplaySnapshot {
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
                    colorSpace: colorSpace
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
                            colorSpace: colorSpace
                        )
                    }
                }
            }

            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
            guard let updatedDisplay = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }
            return snapshot(from: updatedDisplay)
        }

        // Register this consumer with the target resolution
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: targetResolution,
            windowID: 0,
            colorSpace: colorSpace,
            acquiredAt: Date()
        )

        MirageLogger
            .host(
                "\(consumer) acquiring shared display at \(Int(targetResolution.width))x\(Int(targetResolution.height))@\(refreshRate)Hz, color=\(colorSpace.displayName) (requested \(requestedRate)Hz). Consumers: \(activeConsumers.count)"
            )

        // Create display if needed, or resize if resolution differs
        if sharedDisplay == nil {
            sharedDisplay = try await createDisplay(
                resolution: targetResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace
            )
        } else if sharedDisplay?.colorSpace != colorSpace {
            MirageLogger
                .host(
                    "Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))"
                )
            sharedDisplay = try await recreateDisplay(
                newResolution: targetResolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace
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
                        colorSpace: colorSpace
                    )
                }
            }
        }

        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)

        guard let display = sharedDisplay else { throw SharedDisplayError.noActiveDisplay }

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

        if activeConsumers.isEmpty { await destroyDisplay() }
    }

    /// Update the resolution for a stream (when client moves to different display)
    /// - Parameters:
    ///   - streamID: The stream to update
    ///   - newResolution: The new client resolution
    func updateClientResolution(
        for streamID: StreamID,
        newResolution: CGSize,
        refreshRate: Int = 60
    )
    async throws {
        let requestedRate = refreshRate
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        let consumer = DisplayConsumer.stream(streamID)
        let previousGeneration = sharedDisplay?.generation ?? 0
        guard var clientInfo = activeConsumers[consumer] else { throw SharedDisplayError.clientNotFound(streamID) }

        // Update stored resolution
        clientInfo = ClientDisplayInfo(
            resolution: newResolution,
            windowID: clientInfo.windowID,
            colorSpace: clientInfo.colorSpace,
            acquiredAt: clientInfo.acquiredAt
        )
        activeConsumers[consumer] = clientInfo

        // Check if we need to resize
        let optimalResolution = calculateOptimalResolution()

        if let current = sharedDisplay {
            let needsRefresh = current.refreshRate != Double(refreshRate)
            let requiresResize = needsResize(currentResolution: current.resolution, targetResolution: optimalResolution)

            if needsRefresh || requiresResize {
                let updated = await updateDisplayInPlace(
                    newResolution: optimalResolution,
                    refreshRate: refreshRate,
                    colorSpace: clientInfo.colorSpace
                )

                if !updated {
                    if needsRefresh {
                        MirageLogger
                            .host(
                                "Client resolution change requires refresh update to \(refreshRate)Hz (requested \(requestedRate)Hz)"
                            )
                    } else {
                        MirageLogger
                            .host(
                                "Client resolution change requires display resize to \(Int(optimalResolution.width))x\(Int(optimalResolution.height))"
                            )
                    }
                    sharedDisplay = try await recreateDisplay(
                        newResolution: optimalResolution,
                        refreshRate: refreshRate,
                        colorSpace: clientInfo.colorSpace
                    )
                }
            }
        }

        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
    }

    /// Update the display resolution for a consumer (used for desktop streaming resize)
    /// This updates the existing display's resolution in place without recreation
    /// - Parameters:
    ///   - consumer: The consumer requesting the resize
    ///   - newResolution: The new resolution to resize to
    ///   - refreshRate: Refresh rate in Hz (default 60)
    func updateDisplayResolution(
        for consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int = 60
    )
    async throws {
        let requestedRate = refreshRate
        let refreshRate: Int = switch consumer {
        case .desktopStream,
             .stream:
            SharedVirtualDisplayManager.streamRefreshRate(for: requestedRate)
        default:
            resolvedRefreshRate(requestedRate)
        }
        guard let existingInfo = activeConsumers[consumer] else {
            MirageLogger.error(.host, "Cannot update resolution: consumer \(consumer) not found")
            return
        }

        guard let display = sharedDisplay else {
            MirageLogger.error(.host, "Cannot update resolution: no active display")
            return
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
            MirageLogger
                .host(
                    "Display color space mismatch (\(display.colorSpace.displayName) → \(requestedColorSpace.displayName)); recreating"
                )
            sharedDisplay = try await recreateDisplay(
                newResolution: newResolution,
                refreshRate: refreshRate,
                colorSpace: requestedColorSpace
            )
            notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
            return
        }

        // Check if refresh rate or resolution needs updating
        let needsRefresh = display.refreshRate != Double(refreshRate)
        let requiresResize = needsResize(currentResolution: display.resolution, targetResolution: newResolution)

        if needsRefresh || requiresResize {
            MirageLogger
                .host(
                    "Updating display \(display.displayID) for \(consumer) to \(Int(newResolution.width))x\(Int(newResolution.height))@\(refreshRate)Hz"
                )

            let updated = await updateDisplayInPlace(
                newResolution: newResolution,
                refreshRate: refreshRate,
                colorSpace: requestedColorSpace
            )

            if !updated {
                if needsRefresh { MirageLogger.host("In-place refresh rate update failed, recreating display") } else {
                    MirageLogger.host("In-place resize failed, recreating display")
                }
                sharedDisplay = try await recreateDisplay(
                    newResolution: newResolution,
                    refreshRate: refreshRate,
                    colorSpace: requestedColorSpace
                )
            }
        }

        notifyGenerationChangeIfNeeded(previousGeneration: previousGeneration)
    }
}
#endif
