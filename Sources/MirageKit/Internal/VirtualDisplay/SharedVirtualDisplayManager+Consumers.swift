//
//  SharedVirtualDisplayManager+Consumers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

#if os(macOS)
import Foundation
import CoreGraphics

extension SharedVirtualDisplayManager {
    // MARK: - Consumer-Based Acquisition (for non-stream consumers)

    /// Acquire the shared virtual display for a non-stream purpose (login display, unlock, desktop stream)
    /// Creates the display if this is the first consumer, otherwise returns existing
    /// - Parameters:
    ///   - consumer: The consumer type acquiring the display
    ///   - resolution: Optional resolution for the display (used by desktop streaming; capture/encoder enforce the 5K cap)
    ///   - refreshRate: Refresh rate in Hz (default 60, use 120 for high refresh rate clients)
    /// - Returns: The managed display context
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func acquireDisplayForConsumer(
        _ consumer: DisplayConsumer,
        resolution: CGSize? = nil,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace = .displayP3
    ) async throws -> ManagedDisplayContext {
        let requestedRate = refreshRate
        let refreshRate = resolvedRefreshRate(requestedRate)
        // Use provided resolution or fall back to default
        let targetResolution = resolution ?? CGSize(width: 2880, height: 1800)

        // Check if this consumer already has the display
        if activeConsumers[consumer] != nil, let display = sharedDisplay {
            MirageLogger.host("\(consumer) already has shared display, returning existing")
            return display
        }

        // Register this consumer with the target resolution
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: targetResolution,
            windowID: 0,
            colorSpace: colorSpace,
            acquiredAt: Date()
        )

        MirageLogger.host("\(consumer) acquiring shared display at \(Int(targetResolution.width))x\(Int(targetResolution.height))@\(refreshRate)Hz, color=\(colorSpace.displayName) (requested \(requestedRate)Hz). Consumers: \(activeConsumers.count)")

        // Create display if needed, or resize if resolution differs
        if sharedDisplay == nil {
            sharedDisplay = try await createDisplay(resolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if sharedDisplay?.refreshRate != Double(refreshRate) {
            MirageLogger.host("Recreating shared display for refresh rate change (\(sharedDisplay?.refreshRate ?? 0) → \(Double(refreshRate)))")
            sharedDisplay = try await recreateDisplay(newResolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if sharedDisplay?.colorSpace != colorSpace {
            MirageLogger.host("Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))")
            sharedDisplay = try await recreateDisplay(newResolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if needsResize(currentResolution: sharedDisplay!.resolution, targetResolution: targetResolution) {
            MirageLogger.host("Resizing shared display from \(Int(sharedDisplay!.resolution.width))x\(Int(sharedDisplay!.resolution.height)) to \(Int(targetResolution.width))x\(Int(targetResolution.height))")
            sharedDisplay = try await recreateDisplay(newResolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        }

        guard let display = sharedDisplay else {
            throw SharedDisplayError.noActiveDisplay
        }

        return display
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

        if activeConsumers.isEmpty {
            await destroyDisplay()
        }
    }

    /// Update the resolution for a stream (when client moves to different display)
    /// - Parameters:
    ///   - streamID: The stream to update
    ///   - newResolution: The new client resolution
    func updateClientResolution(
        for streamID: StreamID,
        newResolution: CGSize,
        refreshRate: Int = 60
    ) async throws {
        let requestedRate = refreshRate
        let refreshRate = resolvedRefreshRate(requestedRate)
        let consumer = DisplayConsumer.stream(streamID)
        guard var clientInfo = activeConsumers[consumer] else {
            throw SharedDisplayError.clientNotFound(streamID)
        }

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
            if current.refreshRate != Double(refreshRate) {
                MirageLogger.host("Client resolution change requires refresh update to \(refreshRate)Hz (requested \(requestedRate)Hz)")
                sharedDisplay = try await recreateDisplay(newResolution: optimalResolution, refreshRate: refreshRate, colorSpace: clientInfo.colorSpace)
                return
            }
            if needsResize(currentResolution: current.resolution, targetResolution: optimalResolution) {
                MirageLogger.host("Client resolution change requires display resize to \(Int(optimalResolution.width))x\(Int(optimalResolution.height))")
                sharedDisplay = try await recreateDisplay(newResolution: optimalResolution, refreshRate: refreshRate, colorSpace: clientInfo.colorSpace)
            }
        }
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
    ) async throws {
        let requestedRate = refreshRate
        let refreshRate = resolvedRefreshRate(requestedRate)
        guard activeConsumers[consumer] != nil else {
            MirageLogger.error(.host, "Cannot update resolution: consumer \(consumer) not found")
            return
        }

        guard let display = sharedDisplay else {
            MirageLogger.error(.host, "Cannot update resolution: no active display")
            return
        }

        let requestedColorSpace = activeConsumers[consumer]?.colorSpace ?? .displayP3
        // Update stored resolution for this consumer
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: newResolution,
            windowID: 0,
            colorSpace: requestedColorSpace,
            acquiredAt: Date()
        )
        if display.colorSpace != requestedColorSpace {
            MirageLogger.host("Display color space mismatch (\(display.colorSpace.displayName) → \(requestedColorSpace.displayName)); recreating")
            sharedDisplay = try await recreateDisplay(newResolution: newResolution, refreshRate: refreshRate, colorSpace: requestedColorSpace)
            return
        }
        if display.refreshRate != Double(refreshRate) {
            MirageLogger.host("Display refresh rate mismatch (\(display.refreshRate) → \(Double(refreshRate)))")
            sharedDisplay = try await recreateDisplay(newResolution: newResolution, refreshRate: refreshRate, colorSpace: requestedColorSpace)
            return
        }

        MirageLogger.host("Updating display \(display.displayID) for \(consumer) to \(Int(newResolution.width))x\(Int(newResolution.height))")

        // Try to update the existing display's resolution in place
        // This avoids display leak issues and is faster than destroy/recreate
        let success = CGVirtualDisplayBridge.updateDisplayResolution(
            display: display.displayRef.value,
            width: Int(newResolution.width),
            height: Int(newResolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true
        )

        if success {
            // Update our stored resolution
            sharedDisplay = ManagedDisplayContext(
                displayID: display.displayID,
                spaceID: display.spaceID,
                resolution: newResolution,
                refreshRate: Double(refreshRate),
                colorSpace: display.colorSpace,
                createdAt: display.createdAt,
                displayRef: display.displayRef  // Keep same reference
            )
            MirageLogger.host("Display resolution updated in place to \(Int(newResolution.width))x\(Int(newResolution.height))")

            await MainActor.run {
                VirtualDisplayKeepaliveController.shared.update(displayID: display.displayID)
            }
        } else {
            // Fallback to recreate if in-place update fails
            MirageLogger.host("In-place update failed, falling back to recreate")
            sharedDisplay = try await recreateDisplay(newResolution: newResolution, refreshRate: refreshRate, colorSpace: requestedColorSpace)
        }
    }

}
#endif
