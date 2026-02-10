//
//  SharedVirtualDisplayManager+Helpers.swift
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
    // MARK: - Private Helpers

    static func logicalResolution(for pixelResolution: CGSize, scaleFactor: CGFloat = 2.0) -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else { return pixelResolution }
        let scale = max(1.0, scaleFactor)
        return CGSize(
            width: pixelResolution.width / scale,
            height: pixelResolution.height / scale
        )
    }

    static func fallbackResolution(for retinaResolution: CGSize) -> CGSize {
        let width = CGFloat(StreamContext.alignedEvenPixel(max(2.0, retinaResolution.width / 2.0)))
        let height = CGFloat(StreamContext.alignedEvenPixel(max(2.0, retinaResolution.height / 2.0)))
        return CGSize(width: width, height: height)
    }

    private func resolvedScaleFactor(displayID: CGDirectDisplayID, fallback: CGFloat) -> CGFloat {
        if let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID),
           modeSizes.logical.width > 0,
           modeSizes.logical.height > 0,
           modeSizes.pixel.width > 0,
           modeSizes.pixel.height > 0 {
            let scale = modeSizes.pixel.width / modeSizes.logical.width
            if scale > 0 { return scale }
        }
        return fallback
    }

    private func resetFallbackStreak(for colorSpace: MirageColorSpace) {
        fallbackStreakByColorSpace[colorSpace] = 0
    }

    private func registerFallbackEvent(for colorSpace: MirageColorSpace) {
        let streak = (fallbackStreakByColorSpace[colorSpace] ?? 0) + 1
        fallbackStreakByColorSpace[colorSpace] = streak
        CGVirtualDisplayBridge.clearPreferredDescriptorProfile(for: colorSpace)
        MirageLogger.host("Virtual display non-Retina fallback streak for \(colorSpace.displayName): \(streak)")

        let rotationThreshold = 3
        if streak >= rotationThreshold {
            CGVirtualDisplayBridge.invalidatePersistentSerial(for: colorSpace)
            fallbackStreakByColorSpace[colorSpace] = 0
            MirageLogger.host("Virtual display fallback streak reached threshold; serial slot rotated")
        }
    }

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

    func validateDisplayMode(
        displayID: CGDirectDisplayID,
        expectedLogicalResolution: CGSize,
        expectedPixelResolution: CGSize
    )
    async -> Bool {
        guard expectedLogicalResolution.width > 0,
              expectedLogicalResolution.height > 0,
              expectedPixelResolution.width > 0,
              expectedPixelResolution.height > 0 else { return true }

        let maxAttempts = 6
        var delayMs = 80

        for attempt in 1 ... maxAttempts {
            let bounds = CGDisplayBounds(displayID)
            let boundsReady = bounds.width > 0 && bounds.height > 0
            let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID)

            do {
                let scDisplay = try await findSCDisplay(displayID: displayID, maxAttempts: 1)
                let scSize = CGSize(width: CGFloat(scDisplay.display.width), height: CGFloat(scDisplay.display.height))
                let modeLogicalSize = modeSizes?.logical ?? .zero
                let modePixelSize = modeSizes?.pixel ?? .zero

                let scMatchesLogical = abs(scSize.width - expectedLogicalResolution.width) <= 1 &&
                    abs(scSize.height - expectedLogicalResolution.height) <= 1
                let scMatchesPixel = abs(scSize.width - expectedPixelResolution.width) <= 1 &&
                    abs(scSize.height - expectedPixelResolution.height) <= 1

                let boundsMatchesLogical = abs(bounds.width - expectedLogicalResolution.width) <= 1 &&
                    abs(bounds.height - expectedLogicalResolution.height) <= 1
                let boundsMatchesPixel = abs(bounds.width - expectedPixelResolution.width) <= 1 &&
                    abs(bounds.height - expectedPixelResolution.height) <= 1

                let modeMatchesLogical = abs(modeLogicalSize.width - expectedLogicalResolution.width) <= 1 &&
                    abs(modeLogicalSize.height - expectedLogicalResolution.height) <= 1
                let modeMatchesPixel = abs(modePixelSize.width - expectedPixelResolution.width) <= 1 &&
                    abs(modePixelSize.height - expectedPixelResolution.height) <= 1

                let sizeMatches = scMatchesLogical || scMatchesPixel || boundsMatchesLogical || boundsMatchesPixel
                let modeMatches = modeMatchesLogical && modeMatchesPixel
                let expectsOneX = abs(expectedLogicalResolution.width - expectedPixelResolution.width) <= 1 &&
                    abs(expectedLogicalResolution.height - expectedPixelResolution.height) <= 1

                if boundsReady, sizeMatches, modeMatches {
                    return true
                }

                if expectsOneX, boundsReady, sizeMatches {
                    MirageLogger
                        .host(
                            "Virtual display \(displayID) accepted using lenient 1x validation: " +
                                "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                                "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), " +
                                "expected=\(expectedPixelResolution)"
                        )
                    return true
                }

                MirageLogger
                    .host(
                        "Virtual display \(displayID) size mismatch (attempt \(attempt)/\(maxAttempts)): " +
                            "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                            "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), " +
                            "expectedLogical=\(expectedLogicalResolution), expectedPixel=\(expectedPixelResolution)"
                    )
            } catch {
                MirageLogger
                    .host(
                        "Virtual display \(displayID) size validation failed (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(delayMs))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        return false
    }

    func waitForDisplayRemoval(displayID: CGDirectDisplayID) async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if !CGVirtualDisplayBridge.isDisplayOnline(displayID) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func updateDisplayInPlace(
        newResolution: CGSize,
        refreshRate: Int,
        colorSpace: MirageColorSpace
    )
    async -> Bool {
        guard let display = sharedDisplay else { return false }
        guard display.colorSpace == colorSpace else { return false }

        let useHiDPI = display.scaleFactor > 1.5
        let success = CGVirtualDisplayBridge.updateDisplayResolution(
            display: display.displayRef.value,
            width: Int(newResolution.width),
            height: Int(newResolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: useHiDPI
        )

        if success {
            let updatedScaleFactor = resolvedScaleFactor(displayID: display.displayID, fallback: display.scaleFactor)
            sharedDisplay = ManagedDisplayContext(
                displayID: display.displayID,
                spaceID: display.spaceID,
                resolution: newResolution,
                scaleFactor: updatedScaleFactor,
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

        let attempts: [(resolution: CGSize, hiDPI: Bool)] = [
            (resolution, true),
            (SharedVirtualDisplayManager.fallbackResolution(for: resolution), false),
        ]

        for attempt in attempts {
            let requestedResolution = attempt.resolution
            let expectedLogical = SharedVirtualDisplayManager.logicalResolution(
                for: requestedResolution,
                scaleFactor: attempt.hiDPI ? 2.0 : 1.0
            )
            let expectedPixel = requestedResolution

            guard let displayContext = CGVirtualDisplayBridge.createVirtualDisplay(
                name: displayName,
                width: Int(requestedResolution.width),
                height: Int(requestedResolution.height),
                refreshRate: Double(refreshRate),
                hiDPI: attempt.hiDPI,
                colorSpace: colorSpace
            ) else {
                continue
            }

            let invalidateSelector = NSSelectorFromString("invalidate")
            func invalidateAttemptDisplay() {
                if (displayContext.display as AnyObject).responds(to: invalidateSelector) {
                    _ = (displayContext.display as AnyObject).perform(invalidateSelector)
                }
                CGVirtualDisplayBridge.configuredDisplayOrigins.removeValue(forKey: displayContext.displayID)
            }

            guard await CGVirtualDisplayBridge.waitForDisplayReady(
                displayContext.displayID,
                expectedResolution: expectedLogical,
                alternateExpectedResolution: expectedPixel
            ) != nil else {
                invalidateAttemptDisplay()
                continue
            }

            let enforced = CGVirtualDisplayBridge.updateDisplayResolution(
                display: displayContext.display,
                width: Int(requestedResolution.width),
                height: Int(requestedResolution.height),
                refreshRate: Double(refreshRate),
                hiDPI: attempt.hiDPI
            )
            guard enforced else {
                invalidateAttemptDisplay()
                continue
            }

            let spaceID = CGVirtualDisplayBridge.getSpaceForDisplay(displayContext.displayID)
            guard spaceID != 0 else {
                invalidateAttemptDisplay()
                throw SharedDisplayError.spaceNotFound(displayContext.displayID)
            }

            let isValid = await validateDisplayMode(
                displayID: displayContext.displayID,
                expectedLogicalResolution: expectedLogical,
                expectedPixelResolution: expectedPixel
            )
            guard isValid else {
                invalidateAttemptDisplay()
                continue
            }

            let displayScaleFactor = resolvedScaleFactor(
                displayID: displayContext.displayID,
                fallback: attempt.hiDPI ? 2.0 : 1.0
            )
            let managedContext = ManagedDisplayContext(
                displayID: displayContext.displayID,
                spaceID: spaceID,
                resolution: requestedResolution,
                scaleFactor: displayScaleFactor,
                refreshRate: displayContext.refreshRate,
                colorSpace: displayContext.colorSpace,
                generation: generation,
                createdAt: Date(),
                displayRef: UncheckedSendableBox(displayContext.display)
            )

            if !attempt.hiDPI {
                MirageLogger.host(
                    "Created shared virtual display using non-Retina fallback at \(Int(requestedResolution.width))x\(Int(requestedResolution.height)) px"
                )
                registerFallbackEvent(for: colorSpace)
            } else {
                resetFallbackStreak(for: colorSpace)
            }

            await MainActor.run {
                VirtualDisplayKeepaliveController.shared.start(
                    displayID: displayContext.displayID,
                    spaceID: spaceID,
                    refreshRate: displayContext.refreshRate
                )
            }

            return managedContext
        }

        throw SharedDisplayError.creationFailed("Virtual display failed activation (Retina + 1x fallback)")
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
