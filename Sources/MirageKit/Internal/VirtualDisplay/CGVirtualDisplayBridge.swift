//
//  CGVirtualDisplayBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import Foundation

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
    private nonisolated(unsafe) static var cachedSerialNumbers: [MirageColorSpace: UInt32] = [:]
    nonisolated(unsafe) static var configuredDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]
    static let mirageVendorID: UInt32 = 0x1234
    static let mirageProductID: UInt32 = 0xE000
    private static let serialDefaultsPrefix = "MirageVirtualDisplaySerial"

    // MARK: - Color Primaries

    /// P3-D65 color space primaries for SDR virtual display configuration
    /// These match the encoder's P3 color space settings
    enum P3D65Primaries {
        static let red = CGPoint(x: 0.680, y: 0.320)
        static let green = CGPoint(x: 0.265, y: 0.690)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290) // D65
    }

    /// sRGB (Rec. 709) color primaries for SDR virtual display configuration
    enum SRGBPrimaries {
        static let red = CGPoint(x: 0.640, y: 0.330)
        static let green = CGPoint(x: 0.300, y: 0.600)
        static let blue = CGPoint(x: 0.150, y: 0.060)
        static let whitePoint = CGPoint(x: 0.3127, y: 0.3290) // D65
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
        let display: AnyObject // CGVirtualDisplay instance (private type)
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
    )
    -> VirtualDisplayContext? {
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
        descriptor.setValue(mirageProductID, forKey: "productID") // Virtual display marker
        descriptor.setValue(persistentSerialNumber(for: colorSpace), forKey: "serialNum")
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

        MirageLogger
            .host(
                "Creating virtual display '\(name)' at \(width)x\(height) pixels, mode=\(modeWidth)x\(modeHeight)@\(refreshRate)Hz, hiDPI=\(hiDPI), color=\(colorSpace.displayName)"
            )

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
        guard let display = (allocatedDisplay as AnyObject).perform(initSelector, with: descriptor)?
            .takeRetainedValue() else {
            MirageLogger.error(.host, "Failed to create CGVirtualDisplay")
            return nil
        }

        // Apply settings
        let applySelector = NSSelectorFromString("applySettings:")
        if (display as AnyObject).responds(to: applySelector) { _ = (display as AnyObject).perform(applySelector, with: settings) }

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

    private static func persistentSerialNumber(for colorSpace: MirageColorSpace) -> UInt32 {
        if let cached = cachedSerialNumbers[colorSpace] {
            return cached
        }

        let defaultsKey = "\(serialDefaultsPrefix).\(colorSpace.rawValue)"
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        if stored > 0, stored <= Int(UInt32.max) {
            let serial = UInt32(stored)
            cachedSerialNumbers[colorSpace] = serial
            return serial
        }

        var serial: UInt32 = 0
        repeat {
            serial = UInt32.random(in: 1 ... UInt32.max)
        } while serial == 0

        UserDefaults.standard.set(Int(serial), forKey: defaultsKey)
        cachedSerialNumbers[colorSpace] = serial
        return serial
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
    )
    -> Bool {
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
            MirageLogger
                .host(
                    "Updated virtual display resolution to \(width)x\(height) (mode: \(modeWidth)x\(modeHeight)@\(refreshRate)Hz, hiDPI=\(hiDPI))"
                )
        } else {
            MirageLogger.error(.host, "Failed to update virtual display resolution")
        }

        return success
    }
}

#endif
