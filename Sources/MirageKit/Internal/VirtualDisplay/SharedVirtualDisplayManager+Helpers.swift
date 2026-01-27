//
//  SharedVirtualDisplayManager+Helpers.swift
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
    // MARK: - Private Helpers

    /// Fixed 3K resolution for virtual display
    /// 2880×1800 (16:10) - balanced between 4K (text too small) and 1080p (text too big)
    /// With HiDPI this gives 1440×900 logical points
    func calculateOptimalResolution() -> CGSize {
        return CGSize(width: 2880, height: 1800)
    }

    /// Check if display needs to be resized
    func needsResize(currentResolution: CGSize, targetResolution: CGSize) -> Bool {
        let widthDiff = abs(currentResolution.width - targetResolution.width)
        let heightDiff = abs(currentResolution.height - targetResolution.height)
        // Allow small tolerance (2 pixels) for rounding differences
        return widthDiff > 2 || heightDiff > 2
    }

    /// Create the shared virtual display
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func createDisplay(resolution: CGSize, refreshRate: Int, colorSpace: MirageColorSpace) async throws -> ManagedDisplayContext {
        displayCounter += 1
        let displayName = "Mirage Shared Display (#\(displayCounter))"

        guard let displayContext = CGVirtualDisplayBridge.createVirtualDisplay(
            name: displayName,
            width: Int(resolution.width),
            height: Int(resolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true,  // Enable HiDPI for Retina-quality rendering
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

        guard spaceID != 0 else {
            throw SharedDisplayError.spaceNotFound(displayContext.displayID)
        }

        let managedContext = ManagedDisplayContext(
            displayID: displayContext.displayID,
            spaceID: spaceID,
            resolution: resolution,
            refreshRate: displayContext.refreshRate,
            colorSpace: displayContext.colorSpace,
            createdAt: Date(),
            displayRef: UncheckedSendableBox(displayContext.display)
        )

        MirageLogger.host("Created shared virtual display: \(Int(resolution.width))x\(Int(resolution.height))@\(refreshRate)Hz, color=\(displayContext.colorSpace.displayName), displayID=\(displayContext.displayID), spaceID=\(spaceID), bounds=\(readyBounds)")

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
    func recreateDisplay(newResolution: CGSize, refreshRate: Int, colorSpace: MirageColorSpace) async throws -> ManagedDisplayContext {
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

        // Small delay to let the system process the display removal
        try? await Task.sleep(for: .milliseconds(50))

        // Verify the display was actually removed
        let stillExists = CGVirtualDisplayBridge.isDisplayOnline(displayID)
        if stillExists {
            MirageLogger.error(.host, "WARNING: Virtual display \(displayID) still exists after destruction!")
        } else {
            MirageLogger.host("Virtual display \(displayID) successfully destroyed")
        }
    }

}
#endif
