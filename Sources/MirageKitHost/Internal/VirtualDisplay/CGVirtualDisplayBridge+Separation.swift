//
//  CGVirtualDisplayBridge+Separation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Display separation configuration.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension CGVirtualDisplayBridge {
    // MARK: - Display Separation Configuration

    /// Known vendor IDs for third-party virtual display software
    /// These displays behave like physical displays but are virtual
    private static let knownVirtualDisplayVendors: Set<UInt32> = [
        0x1E6D, // BetterDisplay / BetterDummy
        0x0610, // Apple Silicon display (virtual mode)
        0xAC10, // Duet Display
    ]

    /// Check if a display is a virtual display (Mirage or third-party)
    static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        if isMirageDisplay(displayID) { return true }
        if CGDisplayIsBuiltin(displayID) != 0 { return false }
        let vendorID = CGDisplayVendorNumber(displayID)
        // Jump Desktop and similar remote desktop tools create displays with vendor 0
        // or use headless dummy plugs which may have various vendor IDs
        if vendorID == 0 || knownVirtualDisplayVendors.contains(vendorID) { return true }
        return false
    }

    /// Check if we're running in a headless environment (no physical displays)
    static func isHeadlessEnvironment() -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return true }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        // Check if ALL displays are virtual
        let hasPhysicalDisplay = displays.contains { displayID in
            !isVirtualDisplay(displayID) && !isMirageDisplay(displayID)
        }

        return !hasPhysicalDisplay
    }

    /// Get all displays to mirror during desktop streaming
    /// Returns all online displays except the specified virtual display
    /// - Parameter excludingDisplayID: The virtual display ID to exclude (the one we're mirroring TO)
    /// - Returns: Array of display IDs to mirror
    static func getDisplaysToMirror(excludingDisplayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        // Simply exclude the virtual display we created - mirror everything else
        let result = displays.filter { $0 != excludingDisplayID }

        MirageLogger
            .host(
                "getDisplaysToMirror: \(displays.count) online displays, \(result.count) to mirror (excluding virtual display \(excludingDisplayID))"
            )

        return result
    }

    /// Configure the virtual display to be separate from the main display
    /// Uses retry logic to handle race conditions with other display software
    static func configureDisplaySeparation(
        virtualDisplayID: CGDirectDisplayID,
        originalMainDisplayID: CGDirectDisplayID,
        requestedWidth _: Int,
        requestedHeight _: Int
    ) {
        MirageLogger.host("=== DISPLAY SEPARATION CONFIGURATION ===")

        // Get display info for logging
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        // Log detailed display info
        for display in displays {
            let bounds = CGDisplayBounds(display)
            let vendorID = CGDisplayVendorNumber(display)
            let modelID = CGDisplayModelNumber(display)
            let isMirage = isMirageDisplay(display)
            let isVirtual = isVirtualDisplay(display)
            let isMain = display == CGMainDisplayID()
            MirageLogger
                .host(
                    "  Display \(display): bounds=\(bounds), vendor=0x\(String(vendorID, radix: 16)), model=0x\(String(modelID, radix: 16)), mirage=\(isMirage), virtual=\(isVirtual), main=\(isMain)"
                )
        }

        let isHeadless = isHeadlessEnvironment()
        MirageLogger
            .host("Environment: headless=\(isHeadless), originalMain=\(originalMainDisplayID), displays=\(displays)")

        // Retry configuration up to 3 times to handle race conditions
        for attempt in 1 ... 3 {
            let success = performDisplayConfiguration(
                virtualDisplayID: virtualDisplayID,
                originalMainDisplayID: originalMainDisplayID,
                displays: displays,
                isHeadless: isHeadless
            )

            if success {
                MirageLogger.host("Display configuration succeeded on attempt \(attempt)")
                break
            } else if attempt < 3 {
                MirageLogger.host("Display configuration attempt \(attempt) failed, retrying...")
                Thread.sleep(forTimeInterval: 0.1) // Brief delay before retry
            } else {
                MirageLogger.error(.host, "Display configuration failed after \(attempt) attempts")
            }
        }

        let virtualBounds = CGDisplayBounds(virtualDisplayID)
        MirageLogger.host("Final virtual display bounds: \(virtualBounds)")
        MirageLogger.host("=== END CONFIGURATION ===")
    }

    /// Perform the actual display configuration
    /// Returns true if configuration was applied successfully
    private static func performDisplayConfiguration(
        virtualDisplayID: CGDirectDisplayID,
        originalMainDisplayID: CGDirectDisplayID,
        displays: [CGDirectDisplayID],
        isHeadless: Bool
    )
    -> Bool {
        let newMainDisplayID = CGMainDisplayID()
        let originalMainExists = displays.contains(originalMainDisplayID)

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, config != nil else {
            MirageLogger.error(.host, "Failed to begin display configuration: \(beginResult)")
            return false
        }

        var configurationChanged = false
        var pendingVirtualOrigin: CGPoint?
        var targetPosition = "unknown"

        // Step 1: Disable mirroring first (this is critical for consistency)
        for display in displays {
            let mirrorSource = CGDisplayMirrorsDisplay(display)
            if mirrorSource != kCGNullDirectDisplay {
                MirageLogger.host("Disabling mirroring for display \(display) (mirrors \(mirrorSource))")
                let result = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
                if result == .success { configurationChanged = true } else {
                    MirageLogger.error(.host, "Failed to disable mirroring for display \(display): \(result)")
                }
            }
        }

        // Step 2: Determine positioning strategy
        if isHeadless {
            // On headless Mac: position Mirage display far to the right to stay out of the way
            // This ensures it doesn't interfere with Jump Desktop or other remote tools
            let otherDisplays = displays.filter { $0 != virtualDisplayID }
            if let rightmostDisplay = otherDisplays.max(by: { CGDisplayBounds($0).maxX < CGDisplayBounds($1).maxX }) {
                let bounds = CGDisplayBounds(rightmostDisplay)
                let virtualX = Int32(bounds.maxX)
                let virtualY = Int32(bounds.origin.y)
                targetPosition = "right of display \(rightmostDisplay) at (\(virtualX), \(virtualY))"
                let result = CGConfigureDisplayOrigin(config, virtualDisplayID, virtualX, virtualY)
                if result == .success {
                    configurationChanged = true
                    pendingVirtualOrigin = CGPoint(x: CGFloat(virtualX), y: CGFloat(virtualY))
                } else {
                    MirageLogger.error(.host, "Failed to position virtual display: \(result)")
                }
            } else {
                // No other displays - we are the only display, position at origin
                targetPosition = "origin (only display)"
                let result = CGConfigureDisplayOrigin(config, virtualDisplayID, 0, 0)
                if result == .success {
                    configurationChanged = true
                    pendingVirtualOrigin = CGPoint(x: 0, y: 0)
                } else {
                    MirageLogger.error(.host, "Failed to position virtual display at origin: \(result)")
                }
            }
        } else {
            // Has physical display: restore original main if virtual became main
            if newMainDisplayID == virtualDisplayID, newMainDisplayID != originalMainDisplayID, originalMainExists {
                MirageLogger.host("Restoring original main display \(originalMainDisplayID) to origin")
                let result = CGConfigureDisplayOrigin(config, originalMainDisplayID, 0, 0)
                if result == .success { configurationChanged = true } else {
                    MirageLogger.error(.host, "Failed to restore original main display: \(result)")
                }
            }

            // Position virtual display to the right of base display
            let baseDisplayID = originalMainExists ? originalMainDisplayID : displays
                .first(where: { $0 != virtualDisplayID })
            if let baseDisplayID {
                let baseBounds = CGDisplayBounds(baseDisplayID)
                if baseBounds.width > 0, baseBounds.height > 0 {
                    let virtualX = Int32(baseBounds.origin.x + baseBounds.width)
                    let virtualY = Int32(baseBounds.origin.y)
                    targetPosition = "right of display \(baseDisplayID) at (\(virtualX), \(virtualY))"
                    let result = CGConfigureDisplayOrigin(config, virtualDisplayID, virtualX, virtualY)
                    if result == .success {
                        configurationChanged = true
                        pendingVirtualOrigin = CGPoint(x: CGFloat(virtualX), y: CGFloat(virtualY))
                    } else {
                        MirageLogger.error(.host, "Failed to position virtual display: \(result)")
                    }
                } else {
                    MirageLogger.host("Base display \(baseDisplayID) has invalid bounds: \(baseBounds)")
                }
            }
        }

        MirageLogger.host("Target position: \(targetPosition), configurationChanged=\(configurationChanged)")

        // Step 3: Apply or cancel configuration
        if configurationChanged {
            let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
            if completeResult != .success {
                MirageLogger.error(.host, "Failed to complete display configuration: \(completeResult)")
                CGCancelDisplayConfiguration(config)
                return false
            } else {
                if let pendingVirtualOrigin { configuredDisplayOrigins[virtualDisplayID] = pendingVirtualOrigin }
                return true
            }
        } else {
            MirageLogger.host("No configuration changes needed")
            CGCancelDisplayConfiguration(config)
            return true
        }
    }
}
#endif
