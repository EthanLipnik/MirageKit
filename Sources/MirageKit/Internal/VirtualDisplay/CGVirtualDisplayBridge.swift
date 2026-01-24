//
//  CGVirtualDisplayBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit

// MARK: - Space ID Type

/// Space ID for window spaces (used by private CGS APIs)
typealias CGSSpaceID = UInt64

// MARK: - CGVirtualDisplay Bridge

/// Bridge to CGVirtualDisplay private APIs
/// These APIs are undocumented but used by production apps like BetterDisplay and Chromium
final class CGVirtualDisplayBridge: @unchecked Sendable {

    // MARK: - Private API Classes (loaded at runtime)

    private nonisolated(unsafe) static var cgVirtualDisplayClass: AnyClass?
    private nonisolated(unsafe) static var cgVirtualDisplayDescriptorClass: AnyClass?
    private nonisolated(unsafe) static var cgVirtualDisplaySettingsClass: AnyClass?
    private nonisolated(unsafe) static var cgVirtualDisplayModeClass: AnyClass?
    private nonisolated(unsafe) static var isLoaded = false
    private nonisolated(unsafe) static var configuredDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private static let mirageVendorID: UInt32 = 0x1234
    private static let mirageProductID: UInt32 = 0xE000

    // MARK: - Color Primaries

    /// P3-D65 color space primaries for SDR virtual display configuration
    /// These match the encoder's P3 color space settings
    struct P3D65Primaries {
        static let red = CGPoint(x: 0.680, y: 0.320)
        static let green = CGPoint(x: 0.265, y: 0.690)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290)  // D65
    }

    /// sRGB (Rec. 709) color primaries for SDR virtual display configuration
    struct SRGBPrimaries {
        static let red = CGPoint(x: 0.640, y: 0.330)
        static let green = CGPoint(x: 0.300, y: 0.600)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290)  // D65
    }

    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// BT.2020 (Rec. 2020) color primaries for HDR virtual display configuration
    // /// These match the encoder's HDR color space settings (Rec. 2020 + PQ)
    // struct BT2020Primaries {
    //     static let red = CGPoint(x: 0.708, y: 0.292)
    //     static let green = CGPoint(x: 0.170, y: 0.797)
    //     static let blue = CGPoint(x: 0.131, y: 0.046)
    //     static let whitePoint = CGPoint(x: 0.3127, y: 0.3290)  // D65
    // }

    // MARK: - Virtual Display Context

    /// Created virtual display context
    struct VirtualDisplayContext {
        let display: AnyObject  // CGVirtualDisplay instance (private type)
        let displayID: CGDirectDisplayID
        let resolution: CGSize
        let refreshRate: Double
        let colorSpace: MirageColorSpace
    }

    // MARK: - Initialization

    /// Load private API classes via runtime
    static func loadPrivateAPIs() -> Bool {
        guard !isLoaded else { return true }

        cgVirtualDisplayClass = NSClassFromString("CGVirtualDisplay")
        cgVirtualDisplayDescriptorClass = NSClassFromString("CGVirtualDisplayDescriptor")
        cgVirtualDisplaySettingsClass = NSClassFromString("CGVirtualDisplaySettings")
        cgVirtualDisplayModeClass = NSClassFromString("CGVirtualDisplayMode")

        guard cgVirtualDisplayClass != nil,
              cgVirtualDisplayDescriptorClass != nil,
              cgVirtualDisplaySettingsClass != nil,
              cgVirtualDisplayModeClass != nil else {
            MirageLogger.error(.host, "Failed to load CGVirtualDisplay private APIs")
            return false
        }

        isLoaded = true
        MirageLogger.host("CGVirtualDisplay private APIs loaded successfully")
        return true
    }

    // MARK: - Virtual Display Creation

    /// Create a virtual display with the specified resolution
    /// - Parameters:
    ///   - name: Display name (shown in System Preferences)
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    ///   - refreshRate: Refresh rate in Hz (default 60)
    ///   - hiDPI: Enable HiDPI/Retina mode (default false for exact pixel dimensions)
    ///   - ppi: Pixels per inch for physical size calculation (default 220)
    /// - Returns: Virtual display context or nil if creation failed
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    static func createVirtualDisplay(
        name: String,
        width: Int,
        height: Int,
        refreshRate: Double = 60.0,
        hiDPI: Bool = false,
        ppi: Double = 220.0,
        colorSpace: MirageColorSpace
    ) -> VirtualDisplayContext? {
        guard loadPrivateAPIs() else { return nil }

        guard let descriptorClass = cgVirtualDisplayDescriptorClass as? NSObject.Type,
              let settingsClass = cgVirtualDisplaySettingsClass as? NSObject.Type,
              let modeClass = cgVirtualDisplayModeClass as? NSObject.Type,
              let displayClass = cgVirtualDisplayClass as? NSObject.Type else {
            return nil
        }

        // Log existing displays before creation
        var existingDisplayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &existingDisplayCount)
        var existingDisplays = [CGDirectDisplayID](repeating: 0, count: Int(existingDisplayCount))
        CGGetOnlineDisplayList(existingDisplayCount, &existingDisplays, &existingDisplayCount)
        MirageLogger.host("Existing displays before creation: \(existingDisplays)")

        let originalMainDisplayID = CGMainDisplayID()
        MirageLogger.host("Original main display ID: \(originalMainDisplayID)")

        // Create descriptor
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(mirageVendorID, forKey: "vendorID")
        descriptor.setValue(mirageProductID, forKey: "productID")  // Virtual display marker
        descriptor.setValue(UInt32(arc4random()), forKey: "serialNum")
        descriptor.setValue(UInt32(width), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(height), forKey: "maxPixelsHigh")

        // Calculate physical size in millimeters
        let widthMM = 25.4 * Double(width) / ppi
        let heightMM = 25.4 * Double(height) / ppi
        descriptor.setValue(CGSize(width: widthMM, height: heightMM), forKey: "sizeInMillimeters")

        switch colorSpace {
        case .displayP3:
            // TODO: HDR support - add BT.2020 primaries branch when EDR configuration is figured out
            descriptor.setValue(P3D65Primaries.red, forKey: "redPrimary")
            descriptor.setValue(P3D65Primaries.green, forKey: "greenPrimary")
            descriptor.setValue(P3D65Primaries.blue, forKey: "bluePrimary")
            descriptor.setValue(P3D65Primaries.whitePoint, forKey: "whitePoint")
        case .sRGB:
            descriptor.setValue(SRGBPrimaries.red, forKey: "redPrimary")
            descriptor.setValue(SRGBPrimaries.green, forKey: "greenPrimary")
            descriptor.setValue(SRGBPrimaries.blue, forKey: "bluePrimary")
            descriptor.setValue(SRGBPrimaries.whitePoint, forKey: "whitePoint")
        }

        // Set dispatch queue
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // Create display mode
        // When HiDPI is enabled, mode dimensions are LOGICAL (points), not pixels
        // macOS will use 2x scaling: 1920x1200 logical → 3840x2400 framebuffer
        let modeWidth = hiDPI ? width / 2 : width
        let modeHeight = hiDPI ? height / 2 : height

        let displayMode = modeClass.init()
        displayMode.setValue(UInt32(modeWidth), forKey: "width")
        displayMode.setValue(UInt32(modeHeight), forKey: "height")
        displayMode.setValue(refreshRate, forKey: "refreshRate")

        // Create settings
        let settings = settingsClass.init()
        settings.setValue([displayMode], forKey: "modes")
        settings.setValue(hiDPI ? UInt32(1) : UInt32(0), forKey: "hiDPI")

        MirageLogger.host("Creating virtual display '\(name)' at \(width)x\(height) pixels, mode=\(modeWidth)x\(modeHeight)@\(refreshRate)Hz, hiDPI=\(hiDPI), color=\(colorSpace.displayName)")

        // Create the virtual display
        // IMPORTANT: Use takeRetainedValue() so ARC properly manages the display lifecycle
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedDisplay = (displayClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplay")
            return nil
        }

        let initSelector = NSSelectorFromString("initWithDescriptor:")
        guard (allocatedDisplay as AnyObject).responds(to: initSelector) else {
            MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to initWithDescriptor:")
            return nil
        }

        // takeRetainedValue() transfers ownership to ARC - when the reference count hits 0,
        // the display will be properly deallocated and removed from the system
        guard let display = (allocatedDisplay as AnyObject).perform(initSelector, with: descriptor)?.takeRetainedValue() else {
            MirageLogger.error(.host, "Failed to create CGVirtualDisplay")
            return nil
        }

        // Apply settings
        let applySelector = NSSelectorFromString("applySettings:")
        if (display as AnyObject).responds(to: applySelector) {
            _ = (display as AnyObject).perform(applySelector, with: settings)
        }

        // Get display ID
        guard let displayID = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID else {
            MirageLogger.error(.host, "Failed to get displayID from CGVirtualDisplay")
            return nil
        }

        MirageLogger.host("Created virtual display with ID: \(displayID)")

        // Configure display separation
        configureDisplaySeparation(
            virtualDisplayID: displayID,
            originalMainDisplayID: originalMainDisplayID,
            requestedWidth: width,
            requestedHeight: height
        )

        return VirtualDisplayContext(
            display: display as AnyObject,
            displayID: displayID,
            resolution: CGSize(width: width, height: height),
            refreshRate: refreshRate,
            colorSpace: colorSpace
        )
    }

    /// Update an existing virtual display's resolution without recreating it
    /// This avoids the display leak issue and is faster than destroy/recreate
    /// - Parameters:
    ///   - display: The existing CGVirtualDisplay object
    ///   - width: New width in pixels
    ///   - height: New height in pixels
    ///   - refreshRate: Refresh rate in Hz
    ///   - hiDPI: Whether to enable HiDPI (Retina) mode
    /// - Returns: true if the update succeeded
    static func updateDisplayResolution(
        display: AnyObject,
        width: Int,
        height: Int,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true
    ) -> Bool {
        guard loadPrivateAPIs() else { return false }

        guard let settingsClass = cgVirtualDisplaySettingsClass as? NSObject.Type,
              let modeClass = cgVirtualDisplayModeClass as? NSObject.Type else {
            return false
        }

        // Create new mode with requested resolution
        // When HiDPI is enabled, mode dimensions are LOGICAL (points), not pixels
        let modeWidth = hiDPI ? width / 2 : width
        let modeHeight = hiDPI ? height / 2 : height

        let displayMode = modeClass.init()
        displayMode.setValue(UInt32(modeWidth), forKey: "width")
        displayMode.setValue(UInt32(modeHeight), forKey: "height")
        displayMode.setValue(refreshRate, forKey: "refreshRate")

        // Create settings with the new mode
        let settings = settingsClass.init()
        settings.setValue([displayMode], forKey: "modes")
        settings.setValue(hiDPI ? UInt32(1) : UInt32(0), forKey: "hiDPI")

        // Apply new settings to existing display
        let applySelector = NSSelectorFromString("applySettings:")
        guard (display as AnyObject).responds(to: applySelector) else {
            MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to applySettings:")
            return false
        }

        // applySettings: returns BOOL
        let result = (display as AnyObject).perform(applySelector, with: settings)
        let success = result != nil

        if success {
            MirageLogger.host("Updated virtual display resolution to \(width)x\(height) (mode: \(modeWidth)x\(modeHeight)@\(refreshRate)Hz, hiDPI=\(hiDPI))")
        } else {
            MirageLogger.error(.host, "Failed to update virtual display resolution")
        }

        return success
    }

    // MARK: - Display Separation Configuration

    /// Known vendor IDs for third-party virtual display software
    /// These displays behave like physical displays but are virtual
    private static let knownVirtualDisplayVendors: Set<UInt32> = [
        0x1E6D,  // BetterDisplay / BetterDummy
        0x0610,  // Apple Silicon display (virtual mode)
        0xAC10,  // Duet Display
    ]

    /// Check if a display is a virtual display (Mirage or third-party)
    static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        if isMirageDisplay(displayID) {
            return true
        }
        let vendorID = CGDisplayVendorNumber(displayID)
        // Jump Desktop and similar remote desktop tools create displays with vendor 0
        // or use headless dummy plugs which may have various vendor IDs
        if vendorID == 0 || knownVirtualDisplayVendors.contains(vendorID) {
            return true
        }
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

        MirageLogger.host("getDisplaysToMirror: \(displays.count) online displays, \(result.count) to mirror (excluding virtual display \(excludingDisplayID))")

        return result
    }

    /// Configure the virtual display to be separate from the main display
    /// Uses retry logic to handle race conditions with other display software
    private static func configureDisplaySeparation(
        virtualDisplayID: CGDirectDisplayID,
        originalMainDisplayID: CGDirectDisplayID,
        requestedWidth: Int,
        requestedHeight: Int
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
            MirageLogger.host("  Display \(display): bounds=\(bounds), vendor=0x\(String(vendorID, radix: 16)), model=0x\(String(modelID, radix: 16)), mirage=\(isMirage), virtual=\(isVirtual), main=\(isMain)")
        }

        let isHeadless = isHeadlessEnvironment()
        MirageLogger.host("Environment: headless=\(isHeadless), originalMain=\(originalMainDisplayID), displays=\(displays)")

        // Retry configuration up to 3 times to handle race conditions
        for attempt in 1...3 {
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
                Thread.sleep(forTimeInterval: 0.1)  // Brief delay before retry
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
    ) -> Bool {
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
        var targetPosition: String = "unknown"

        // Step 1: Disable mirroring first (this is critical for consistency)
        for display in displays {
            let mirrorSource = CGDisplayMirrorsDisplay(display)
            if mirrorSource != kCGNullDirectDisplay {
                MirageLogger.host("Disabling mirroring for display \(display) (mirrors \(mirrorSource))")
                let result = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
                if result == .success {
                    configurationChanged = true
                } else {
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
            if newMainDisplayID == virtualDisplayID && newMainDisplayID != originalMainDisplayID && originalMainExists {
                MirageLogger.host("Restoring original main display \(originalMainDisplayID) to origin")
                let result = CGConfigureDisplayOrigin(config, originalMainDisplayID, 0, 0)
                if result == .success {
                    configurationChanged = true
                } else {
                    MirageLogger.error(.host, "Failed to restore original main display: \(result)")
                }
            }

            // Position virtual display to the right of base display
            let baseDisplayID = originalMainExists ? originalMainDisplayID : displays.first(where: { $0 != virtualDisplayID })
            if let baseDisplayID {
                let baseBounds = CGDisplayBounds(baseDisplayID)
                if baseBounds.width > 0 && baseBounds.height > 0 {
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
                if let pendingVirtualOrigin {
                    configuredDisplayOrigins[virtualDisplayID] = pendingVirtualOrigin
                }
                return true
            }
        } else {
            MirageLogger.host("No configuration changes needed")
            CGCancelDisplayConfiguration(config)
            return true
        }
    }

    // MARK: - Display Utilities

    /// Get the bounds of a display
    /// Note: CGDisplayBounds can return stale values for newly created virtual displays
    /// Prefer using the resolution from VirtualDisplayContext when available
    static func getDisplayBounds(_ displayID: CGDirectDisplayID) -> CGRect {
        return CGDisplayBounds(displayID)
    }

    /// Wait for a virtual display to become online with non-zero bounds.
    /// Returns the observed bounds when ready, or nil on timeout.
    static func waitForDisplayReady(
        _ displayID: CGDirectDisplayID,
        expectedResolution: CGSize,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05
    ) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastBounds = CGRect.zero

        while Date() < deadline {
            let online = isDisplayOnline(displayID)
            let bounds = CGDisplayBounds(displayID)
            lastBounds = bounds

            if online && bounds.width > 0 && bounds.height > 0 {
                return bounds
            }

            let sleepNs = UInt64(max(0.01, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }

        let online = isDisplayOnline(displayID)
        if online && expectedResolution.width > 0 && expectedResolution.height > 0 {
            let origin = configuredDisplayOrigins[displayID] ?? lastBounds.origin
            let fallbackBounds = CGRect(origin: origin, size: expectedResolution)
            MirageLogger.host("Display \(displayID) online but bounds invalid after wait; using known resolution \(fallbackBounds)")
            return fallbackBounds
        }

        MirageLogger.error(.host, "Display \(displayID) not ready after \(String(format: "%.2f", timeout))s (online: \(online), lastBounds: \(lastBounds))")
        return nil
    }

    /// Get display bounds using known values (more reliable for virtual displays)
    /// CGDisplayBounds can return stale/incorrect values immediately after display creation
    /// for BOTH origin and size
    ///
    /// For window centering purposes, the virtual display is treated as starting at (0, 0).
    /// This is the coordinate space where windows will be positioned.
    static func getDisplayBounds(_ displayID: CGDirectDisplayID, knownResolution: CGSize) -> CGRect {
        // CGDisplayBounds is unreliable for newly created virtual displays, especially size.
        // If we have non-zero bounds, trust the reported size (points) to keep windows on-screen.
        let rawBounds = CGDisplayBounds(displayID)
        let origin = configuredDisplayOrigins[displayID] ?? rawBounds.origin

        if rawBounds.width > 0 && rawBounds.height > 0 {
            let bounds = CGRect(origin: origin, size: rawBounds.size)
            if abs(rawBounds.width - knownResolution.width) > 1 || abs(rawBounds.height - knownResolution.height) > 1 {
                MirageLogger.host("getDisplayBounds(\(displayID)): raw size \(rawBounds.size) differs from knownResolution \(knownResolution) (origin \(origin))")
            }
            return bounds
        }

        // Fallback to known resolution when raw bounds are not available yet.
        let bounds = CGRect(origin: origin, size: knownResolution)
        MirageLogger.host("getDisplayBounds(\(displayID)): using origin \(origin) with knownSize=\(knownResolution) (rawBounds=\(rawBounds)) -> \(bounds)")
        return bounds
    }

    static func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return displays.contains(displayID)
    }

    /// Returns true if the display is a Mirage-created virtual display.
    static func isMirageDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == mirageVendorID &&
        CGDisplayModelNumber(displayID) == mirageProductID
    }

    /// Get the space ID for a display
    static func getSpaceForDisplay(_ displayID: CGDirectDisplayID) -> CGSSpaceID {
        return CGSWindowSpaceBridge.getCurrentSpaceForDisplay(displayID)
    }
}

// MARK: - Window Space Management Bridge

/// Bridge to private CGS window/space management APIs
final class CGSWindowSpaceBridge {

    // MARK: - Private Type Aliases

    private typealias CGSConnectionID = UInt32

    private struct CGSSpaceMask: OptionSet {
        let rawValue: UInt32
        static let all = CGSSpaceMask(rawValue: 1 << 2)
    }

    // MARK: - Private Function Declarations

    @_silgen_name("CGSMainConnectionID")
    private static func CGSMainConnectionID() -> CGSConnectionID

    @_silgen_name("CGSAddWindowsToSpaces")
    private static func CGSAddWindowsToSpaces(
        _ connection: CGSConnectionID,
        _ windows: CFArray,
        _ spaces: CFArray
    )

    @_silgen_name("CGSRemoveWindowsFromSpaces")
    private static func CGSRemoveWindowsFromSpaces(
        _ connection: CGSConnectionID,
        _ windows: CFArray,
        _ spaces: CFArray
    )

    @_silgen_name("CGSCopySpacesForWindows")
    private static func CGSCopySpacesForWindows(
        _ connection: CGSConnectionID,
        _ mask: UInt32,
        _ windows: CFArray
    ) -> CFArray?

    @_silgen_name("CGSManagedDisplayGetCurrentSpace")
    private static func CGSManagedDisplayGetCurrentSpace(
        _ connection: CGSConnectionID,
        _ displayUUID: CFString
    ) -> CGSSpaceID

    @_silgen_name("CGSManagedDisplaySetCurrentSpace")
    private static func CGSManagedDisplaySetCurrentSpace(
        _ connection: CGSConnectionID,
        _ displayUUID: CFString,
        _ spaceID: CGSSpaceID
    ) -> CGError

    @_silgen_name("CGSMoveWindow")
    private static func CGSMoveWindow(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ point: UnsafePointer<CGPoint>
    ) -> CGError

    /// Order window relative to other windows
    /// place: 1 = above, -1 = below, 0 = out (hide)
    @_silgen_name("CGSOrderWindow")
    private static func CGSOrderWindow(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ place: Int32,
        _ relativeToWindow: CGWindowID
    ) -> CGError

    /// Set window level (like always-on-top)
    @_silgen_name("CGSSetWindowLevel")
    private static func CGSSetWindowLevel(
        _ connection: CGSConnectionID,
        _ window: CGWindowID,
        _ level: Int32
    ) -> CGError

    // MARK: - Public Interface

    static func getConnectionID() -> UInt32 {
        return CGSMainConnectionID()
    }

    static func getSpacesForWindow(_ windowID: CGWindowID) -> [CGSSpaceID] {
        let connection = getConnectionID()
        let windowArray = [windowID] as CFArray

        guard let spacesArray = CGSCopySpacesForWindows(connection, CGSSpaceMask.all.rawValue, windowArray) else {
            return []
        }

        var spaces: [CGSSpaceID] = []
        for i in 0..<CFArrayGetCount(spacesArray) {
            if let spacePtr = CFArrayGetValueAtIndex(spacesArray, i) {
                let spaceID = UInt64(bitPattern: Int64(Int(bitPattern: spacePtr)))
                spaces.append(spaceID)
            }
        }

        return spaces
    }

    static func getCurrentSpaceForDisplay(_ displayID: CGDirectDisplayID) -> CGSSpaceID {
        let connection = getConnectionID()
        let uuid = getDisplayUUID(displayID)
        return CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
    }

    static func setCurrentSpaceForDisplay(_ displayID: CGDirectDisplayID, spaceID: CGSSpaceID) -> Bool {
        let connection = getConnectionID()
        let uuid = getDisplayUUID(displayID)
        let result = CGSManagedDisplaySetCurrentSpace(connection, uuid as CFString, spaceID)
        return result == .success
    }

    static func moveWindowToSpace(_ windowID: CGWindowID, spaceID: CGSSpaceID) {
        let connection = getConnectionID()
        let windowArray = [windowID] as CFArray
        let spaceArray = [spaceID] as CFArray

        // Remove from current spaces first
        let currentSpaces = getSpacesForWindow(windowID)
        if !currentSpaces.isEmpty {
            let currentSpacesArray = currentSpaces as CFArray
            CGSRemoveWindowsFromSpaces(connection, windowArray, currentSpacesArray)
        }

        CGSAddWindowsToSpaces(connection, windowArray, spaceArray)
        MirageLogger.host("Moved window \(windowID) to space \(spaceID)")
    }

    static func moveWindow(_ windowID: CGWindowID, to point: CGPoint) -> Bool {
        let connection = getConnectionID()
        var mutablePoint = point
        let result = CGSMoveWindow(connection, windowID, &mutablePoint)
        return result == .success
    }

    /// Bring a window to the front using SkyLight APIs
    /// This works even on virtual displays where AXUIElement fails
    /// - Parameter windowID: The CGWindowID to bring to front
    /// - Returns: true if successful
    static func bringWindowToFront(_ windowID: CGWindowID) -> Bool {
        let connection = getConnectionID()
        // place = 1 means "above", relativeToWindow = 0 means "above all"
        let result = CGSOrderWindow(connection, windowID, 1, 0)
        return result == .success
    }

    private static func getDisplayUUID(_ displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return String(displayID)
    }
}

#endif
