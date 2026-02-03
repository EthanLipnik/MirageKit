//
//  SharedVirtualDisplayManager+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    // MARK: - Private Helpers

    func notifyGenerationChangeIfNeeded(previousGeneration: UInt64) {
        guard previousGeneration > 0 else { return }
        guard let display = sharedDisplay else { return }
        guard display.generation != previousGeneration else { return }
        MirageLogger.host("Shared display generation advanced: \(previousGeneration) -> \(display.generation)")
        generationChangeHandler?(snapshot(from: display), previousGeneration)
    }

    /// Fixed 3K resolution for virtual display
    /// 2880×1800 (16:10) - balanced between 4K (text too small) and 1080p (text too big)
    /// With HiDPI this gives 1440×900 logical points
    func calculateOptimalResolution() -> CGSize {
        CGSize(width: 2880, height: 1800)
    }

    /// Check if display needs to be resized
    func needsResize(currentResolution: CGSize, targetResolution: CGSize) -> Bool {
        let widthDiff = abs(currentResolution.width - targetResolution.width)
        let heightDiff = abs(currentResolution.height - targetResolution.height)
        // Allow small tolerance (2 pixels) for rounding differences
        return widthDiff > 2 || heightDiff > 2
    }

    func updateDisplayInPlace(
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async -> Bool {
        guard let display = sharedDisplay else { return false }
        guard display.colorSpace == colorSpace else { return false }

        let success = CGVirtualDisplayBridge.updateDisplayResolution(
            display: display.displayRef.value,
            width: Int(newResolution.width),
            height: Int(newResolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true
        )

        if success {
            sharedDisplay = ManagedDisplayContext(
                displayID: display.displayID,
                spaceID: display.spaceID,
                resolution: newResolution,
                refreshRate: Double(refreshRate),
                colorSpace: display.colorSpace,
                generation: display.generation,
                createdAt: display.createdAt,
                displayRef: display.displayRef
            )

            await MainActor.run {
                VirtualDisplayKeepaliveController.shared.update(displayID: display.displayID)
            }
        }

        return success
    }

    /// Create the shared virtual display
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func createDisplay(
        resolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async throws -> ManagedDisplayContext {
        if displayCounter == 0 {
            displayCounter = 1
        }
        displayGeneration &+= 1
        let generation = displayGeneration
        let displayName = "Mirage Shared Display (#\(displayCounter))"

        guard let displayContext = CGVirtualDisplayBridge.createVirtualDisplay(
            name: displayName,
            width: Int(resolution.width),
            height: Int(resolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true, // Enable HiDPI for Retina-quality rendering
            colorSpace: colorSpace
        ) else {
            throw SharedDisplayError.creationFailed("CGVirtualDisplay creation returned nil")
        }

        guard let readyBounds = await CGVirtualDisplayBridge.waitForDisplayReady(
            displayContext.displayID,
            expectedResolution: resolution
        ) else {
            throw SharedDisplayError.creationFailed("Display \(displayContext.displayID) did not become ready")
        }

        // Get the space ID for the display
        let spaceID = CGVirtualDisplayBridge.getSpaceForDisplay(displayContext.displayID)

        guard spaceID != 0 else { throw SharedDisplayError.spaceNotFound(displayContext.displayID) }

        let managedContext = ManagedDisplayContext(
            displayID: displayContext.displayID,
            spaceID: spaceID,
            resolution: resolution,
            refreshRate: displayContext.refreshRate,
            colorSpace: displayContext.colorSpace,
            generation: generation,
            createdAt: Date(),
            displayRef: UncheckedSendableBox(displayContext.display)
        )

        MirageLogger
            .host(
                "Created shared virtual display: \(Int(resolution.width))x\(Int(resolution.height))@\(refreshRate)Hz, color=\(displayContext.colorSpace.displayName), displayID=\(displayContext.displayID), spaceID=\(spaceID), generation=\(generation), bounds=\(readyBounds)"
            )

        await MainActor.run {
            VirtualDisplayKeepaliveController.shared.start(
                displayID: displayContext.displayID,
                spaceID: spaceID,
                refreshRate: displayContext.refreshRate
            )
        }

        return managedContext
    }

    /// Recreate the display at a new resolution
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func recreateDisplay(
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async throws -> ManagedDisplayContext {
        // Destroy current display
        await destroyDisplay()

        // Small delay for cleanup
        try await Task.sleep(for: .milliseconds(50))

        // Create new display
        return try await createDisplay(resolution: newResolution, refreshRate: refreshRate, colorSpace: colorSpace)
    }

    /// Destroy the shared display
    func destroyDisplay() async {
        guard let display = sharedDisplay else { return }

        let displayID = display.displayID
        MirageLogger.host("Destroying shared virtual display, displayID=\(displayID)")

        await MainActor.run {
            VirtualDisplayKeepaliveController.shared.stop(displayID: displayID)
        }

        // Clear the reference - ARC will deallocate the CGVirtualDisplay
        // which removes it from the system display list
        sharedDisplay = nil
        CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayID)

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) {
                MirageLogger.host("Virtual display \(displayID) successfully destroyed")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        MirageLogger.error(.host, "WARNING: Virtual display \(displayID) still exists after destruction!")
    }
}
#endif
