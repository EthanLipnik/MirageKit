//
//  CGVirtualDisplayBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import Foundation
import MirageKit

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
    private nonisolated(unsafe) static var cachedSerialSlots: [MirageColorSpace: SerialSlot] = [:]
    nonisolated(unsafe) static var configuredDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]
    static let mirageVendorID: UInt32 = 0x1234
    static let mirageProductID: UInt32 = 0xE000
    private static let legacySerialDefaultsPrefix = "MirageVirtualDisplaySerial"
    private static let serialSlotDefaultsPrefix = "MirageVirtualDisplaySerialSlot"
    private static let descriptorProfileDefaultsPrefix = "MirageVirtualDisplayDescriptorProfile"
    private static let serialSchemeVersionDefaultsKey = "MirageVirtualDisplaySerialSchemeVersion"
    private static let serialSchemeVersion = 3
    private static let hiDPIDisabledSetting: UInt32 = 0
    private static let hiDPIEnabledSetting: UInt32 = 2

    private enum SerialSlot: Int {
        case primary = 0
        case alternate = 1

        mutating func toggle() {
            self = self == .primary ? .alternate : .primary
        }
    }

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

    private static func hiDPISettingValue(enabled: Bool) -> UInt32 {
        enabled ? hiDPIEnabledSetting : hiDPIDisabledSetting
    }

    private static func createDisplayMode(
        modeClass: NSObject.Type,
        width: Int,
        height: Int,
        refreshRate: Double
    )
    -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedMode = (modeClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplayMode")
            return nil
        }

        let initSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard (allocatedMode as AnyObject).responds(to: initSelector) else {
            MirageLogger.error(.host, "CGVirtualDisplayMode doesn't respond to initWithWidth:height:refreshRate:")
            return nil
        }

        typealias InitModeIMP = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
        let initIMP = (allocatedMode as AnyObject).method(for: initSelector)
        let initialize = unsafeBitCast(initIMP, to: InitModeIMP.self)
        let initialized = initialize(
            allocatedMode as AnyObject,
            initSelector,
            UInt32(width),
            UInt32(height),
            refreshRate
        ).takeRetainedValue()
        return initialized
    }

    private static func applySettings(
        _ settings: AnyObject,
        to display: AnyObject
    )
    -> Bool {
        let applySelector = NSSelectorFromString("applySettings:")
        guard (display as AnyObject).responds(to: applySelector) else {
            MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to applySettings:")
            return false
        }

        typealias ApplySettingsIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyIMP = (display as AnyObject).method(for: applySelector)
        let apply = unsafeBitCast(applyIMP, to: ApplySettingsIMP.self)
        return apply(display as AnyObject, applySelector, settings)
    }

    private struct ModeActivationAttempt {
        let modeWidth: Int
        let modeHeight: Int
        let hiDPISetting: UInt32
        let label: String
    }

    private static func modeActivationAttempts(
        pixelWidth: Int,
        pixelHeight: Int,
        hiDPI: Bool
    )
    -> [ModeActivationAttempt] {
        guard hiDPI else {
            return [ModeActivationAttempt(
                modeWidth: pixelWidth,
                modeHeight: pixelHeight,
                hiDPISetting: hiDPIDisabledSetting,
                label: "pixel-hiDPI0"
            )]
        }

        let logicalWidth = max(1, pixelWidth / 2)
        let logicalHeight = max(1, pixelHeight / 2)
        let candidates: [ModeActivationAttempt] = [
            ModeActivationAttempt(
                modeWidth: logicalWidth,
                modeHeight: logicalHeight,
                hiDPISetting: hiDPIEnabledSetting,
                label: "logical-hiDPI\(hiDPIEnabledSetting)"
            ),
        ]

        var deduped: [ModeActivationAttempt] = []
        var seen = Set<String>()
        for candidate in candidates {
            let key = "\(candidate.modeWidth)x\(candidate.modeHeight)-\(candidate.hiDPISetting)"
            if seen.insert(key).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private struct DescriptorAttempt {
        let profile: DescriptorProfile
        let serial: UInt32
        let queue: DispatchQueue
        let label: String
    }

    private enum DescriptorProfile: String, CaseIterable {
        case persistentMainQueue = "persistent-main-queue"
        case persistentGlobalQueue = "persistent-global-queue"
        case serial0GlobalQueue = "serial0-global-queue"
    }

    private static func descriptorProfileDefaultsKey(for colorSpace: MirageColorSpace) -> String {
        "\(descriptorProfileDefaultsPrefix).\(colorSpace.rawValue)"
    }

    private static func preferredDescriptorProfile(
        for colorSpace: MirageColorSpace,
        hiDPI: Bool
    )
    -> DescriptorProfile? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: descriptorProfileDefaultsKey(for: colorSpace)),
              let profile = DescriptorProfile(rawValue: raw) else {
            return nil
        }

        if hiDPI {
            return profile == .persistentGlobalQueue || profile == .serial0GlobalQueue ? profile : nil
        }

        return profile == .persistentMainQueue ? profile : nil
    }

    private static func storePreferredDescriptorProfile(
        _ profile: DescriptorProfile,
        for colorSpace: MirageColorSpace
    ) {
        UserDefaults.standard.set(profile.rawValue, forKey: descriptorProfileDefaultsKey(for: colorSpace))
    }

    private static func descriptorAttempts(
        persistentSerial: UInt32,
        hiDPI: Bool,
        colorSpace: MirageColorSpace
    )
    -> [DescriptorAttempt] {
        let defaults: [DescriptorProfile] = hiDPI ? [.persistentGlobalQueue, .serial0GlobalQueue] : [.persistentMainQueue]
        var orderedProfiles: [DescriptorProfile] = []

        if let preferred = preferredDescriptorProfile(for: colorSpace, hiDPI: hiDPI) {
            orderedProfiles.append(preferred)
        }

        for profile in defaults where !orderedProfiles.contains(profile) {
            orderedProfiles.append(profile)
        }

        return orderedProfiles.map { profile in
            switch profile {
            case .persistentMainQueue:
                DescriptorAttempt(
                    profile: profile,
                    serial: persistentSerial,
                    queue: .main,
                    label: profile.rawValue
                )
            case .persistentGlobalQueue:
                DescriptorAttempt(
                    profile: profile,
                    serial: persistentSerial,
                    queue: .global(qos: .userInteractive),
                    label: profile.rawValue
                )
            case .serial0GlobalQueue:
                DescriptorAttempt(
                    profile: profile,
                    serial: 0,
                    queue: .global(qos: .userInteractive),
                    label: profile.rawValue
                )
            }
        }
    }

    private static func activateAndValidateMode(
        display: AnyObject,
        settingsClass: NSObject.Type,
        modeClass: NSObject.Type,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        hiDPI: Bool,
        serial: UInt32?
    )
    -> Bool {
        let requestedLogical = CGSize(
            width: hiDPI ? pixelWidth / 2 : pixelWidth,
            height: hiDPI ? pixelHeight / 2 : pixelHeight
        )
        let requestedPixel = CGSize(width: pixelWidth, height: pixelHeight)

        for attempt in modeActivationAttempts(pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI) {
            guard let displayMode = createDisplayMode(
                modeClass: modeClass,
                width: attempt.modeWidth,
                height: attempt.modeHeight,
                refreshRate: refreshRate
            ) else { continue }

            let settings = settingsClass.init()
            settings.setValue([displayMode], forKey: "modes")
            settings.setValue(attempt.hiDPISetting, forKey: "hiDPI")

            MirageLogger.host(
                "Applying virtual display mode attempt \(attempt.label): mode=\(attempt.modeWidth)x\(attempt.modeHeight)@\(refreshRate)Hz, hiDPISetting=\(attempt.hiDPISetting)"
            )

            guard applySettings(settings, to: display) else {
                MirageLogger.error(.host, "Failed to apply virtual display settings for attempt \(attempt.label)")
                continue
            }

            guard let displayID = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID, displayID != 0 else {
                MirageLogger.error(.host, "Virtual display has invalid displayID after attempt \(attempt.label)")
                continue
            }

            if validateModeActivation(
                displayID: displayID,
                requestedLogical: requestedLogical,
                requestedPixel: requestedPixel,
                hiDPISetting: attempt.hiDPISetting,
                serial: serial
            ) {
                MirageLogger.host("Virtual display Retina activation succeeded with attempt \(attempt.label)")
                return true
            }
        }

        return false
    }

    private static func teardownFailedDisplay(displayID: CGDirectDisplayID, profileLabel: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if !isDisplayOnline(displayID) {
                configuredDisplayOrigins.removeValue(forKey: displayID)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        configuredDisplayOrigins.removeValue(forKey: displayID)
        MirageLogger.error(.host, "Failed to tear down virtual display \(displayID) after profile \(profileLabel) failure")
        return false
    }

    private static func modeValidationLogLine(
        displayID: CGDirectDisplayID,
        serial: UInt32?,
        hiDPISetting: UInt32,
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        observed: DisplayModeSizes?
    )
    -> String {
        let observedLogical = observed?.logical ?? .zero
        let observedPixel = observed?.pixel ?? .zero
        let scale = observedLogical.width > 0 ? observedPixel.width / observedLogical.width : 0
        let scaleText = Double(scale).formatted(.number.precision(.fractionLength(2)))
        let serialText = serial.map(String.init) ?? "unknown"
        return "Virtual display mode validation failed: displayID=\(displayID), serial=\(serialText), hiDPISetting=\(hiDPISetting), requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observedLogical), observedPixel=\(observedPixel), observedScale=\(scaleText)x"
    }

    private static func validateModeActivation(
        displayID: CGDirectDisplayID,
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        hiDPISetting: UInt32,
        serial: UInt32?
    )
    -> Bool {
        let deadline = Date().addingTimeInterval(0.8)
        var lastObserved: DisplayModeSizes?

        while Date() < deadline {
            if let observed = currentDisplayModeSizes(displayID),
               observed.logical.width > 0,
               observed.logical.height > 0,
               observed.pixel.width > 0,
               observed.pixel.height > 0 {
                lastObserved = observed

                let logicalMatches = abs(observed.logical.width - requestedLogical.width) <= 1 &&
                    abs(observed.logical.height - requestedLogical.height) <= 1
                let pixelMatches = abs(observed.pixel.width - requestedPixel.width) <= 1 &&
                    abs(observed.pixel.height - requestedPixel.height) <= 1

                if logicalMatches, pixelMatches {
                    let scale = observed.logical.width > 0 ? observed.pixel.width / observed.logical.width : 0
                    let scaleText = Double(scale).formatted(.number.precision(.fractionLength(2)))
                    MirageLogger.host(
                        "Virtual display mode active: logical=\(observed.logical), pixel=\(observed.pixel), scale=\(scaleText)x"
                    )
                    return true
                }
            } else {
                lastObserved = nil
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        MirageLogger.error(
            .host,
            modeValidationLogLine(
                displayID: displayID,
                serial: serial,
                hiDPISetting: hiDPISetting,
                requestedLogical: requestedLogical,
                requestedPixel: requestedPixel,
                observed: lastObserved
            )
        )
        return false
    }

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

        let persistentSerial = persistentSerialNumber(for: colorSpace)
        let descriptorProfiles = descriptorAttempts(
            persistentSerial: persistentSerial,
            hiDPI: hiDPI,
            colorSpace: colorSpace
        )

        for profile in descriptorProfiles {
            var failedDisplayID: CGDirectDisplayID?
            var creationResult: VirtualDisplayContext?

            autoreleasepool {
                let descriptor = descriptorClass.init()
                descriptor.setValue(name, forKey: "name")
                descriptor.setValue(mirageVendorID, forKey: "vendorID")
                descriptor.setValue(mirageProductID, forKey: "productID")
                descriptor.setValue(profile.serial, forKey: "serialNum")
                descriptor.setValue(UInt32(width), forKey: "maxPixelsWide")
                descriptor.setValue(UInt32(height), forKey: "maxPixelsHigh")

                let widthMM = 25.4 * Double(width) / ppi
                let heightMM = 25.4 * Double(height) / ppi
                descriptor.setValue(CGSize(width: widthMM, height: heightMM), forKey: "sizeInMillimeters")

                switch colorSpace {
                case .displayP3:
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

                descriptor.setValue(profile.queue, forKey: "queue")

                MirageLogger.host(
                    "Creating virtual display '\(name)' at \(width)x\(height) pixels, hiDPI=\(hiDPI), color=\(colorSpace.displayName), profile=\(profile.label), serial=\(profile.serial)"
                )

                let allocSelector = NSSelectorFromString("alloc")
                guard let allocatedDisplay = (displayClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
                    MirageLogger.error(.host, "Failed to allocate CGVirtualDisplay")
                    return
                }

                let initSelector = NSSelectorFromString("initWithDescriptor:")
                guard (allocatedDisplay as AnyObject).responds(to: initSelector) else {
                    MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to initWithDescriptor:")
                    return
                }

                guard let display = (allocatedDisplay as AnyObject).perform(initSelector, with: descriptor)?
                    .takeRetainedValue() else {
                    MirageLogger.error(.host, "Failed to create CGVirtualDisplay for profile \(profile.label)")
                    return
                }

                let displayID = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID
                failedDisplayID = displayID

                guard activateAndValidateMode(
                    display: display as AnyObject,
                    settingsClass: settingsClass,
                    modeClass: modeClass,
                    pixelWidth: width,
                    pixelHeight: height,
                    refreshRate: refreshRate,
                    hiDPI: hiDPI,
                    serial: profile.serial
                ) else {
                    MirageLogger.error(.host, "Virtual display Retina activation failed for profile \(profile.label)")
                    let invalidateSelector = NSSelectorFromString("invalidate")
                    if (display as AnyObject).responds(to: invalidateSelector) {
                        _ = (display as AnyObject).perform(invalidateSelector)
                    }
                    return
                }

                guard let displayID else {
                    MirageLogger.error(.host, "Failed to get displayID from CGVirtualDisplay for profile \(profile.label)")
                    let invalidateSelector = NSSelectorFromString("invalidate")
                    if (display as AnyObject).responds(to: invalidateSelector) {
                        _ = (display as AnyObject).perform(invalidateSelector)
                    }
                    return
                }

                MirageLogger.host("Created virtual display with ID: \(displayID)")

                configureDisplaySeparation(
                    virtualDisplayID: displayID,
                    originalMainDisplayID: originalMainDisplayID,
                    requestedWidth: width,
                    requestedHeight: height
                )

                creationResult = VirtualDisplayContext(
                    display: display as AnyObject,
                    displayID: displayID,
                    resolution: CGSize(width: width, height: height),
                    refreshRate: refreshRate,
                    colorSpace: colorSpace
                )
            }

            if let creationResult {
                storePreferredDescriptorProfile(profile.profile, for: colorSpace)
                return creationResult
            }

            if let failedDisplayID, !teardownFailedDisplay(displayID: failedDisplayID, profileLabel: profile.label) {
                return nil
            }
        }

        MirageLogger.error(.host, "Virtual display failed Retina activation for all descriptor profiles")
        return nil
    }

    private static func legacySerialDefaultsKey(for colorSpace: MirageColorSpace) -> String {
        "\(legacySerialDefaultsPrefix).\(colorSpace.rawValue)"
    }

    private static func serialSlotDefaultsKey(for colorSpace: MirageColorSpace) -> String {
        "\(serialSlotDefaultsPrefix).\(colorSpace.rawValue)"
    }

    private static func migrateLegacySerialStateIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: serialSchemeVersionDefaultsKey) >= serialSchemeVersion {
            return
        }

        for colorSpace in MirageColorSpace.allCases {
            defaults.removeObject(forKey: legacySerialDefaultsKey(for: colorSpace))
            defaults.set(SerialSlot.primary.rawValue, forKey: serialSlotDefaultsKey(for: colorSpace))
        }

        cachedSerialNumbers.removeAll()
        cachedSerialSlots.removeAll()
        defaults.set(serialSchemeVersion, forKey: serialSchemeVersionDefaultsKey)
        MirageLogger.host("Initialized deterministic virtual display serial strategy")
    }

    private static func serialNumber(for colorSpace: MirageColorSpace, slot: SerialSlot) -> UInt32 {
        switch (colorSpace, slot) {
        case (.displayP3, .primary):
            0x4D50_3330 // "MP30"
        case (.displayP3, .alternate):
            0x4D50_3331 // "MP31"
        case (.sRGB, .primary):
            0x4D53_5230 // "MSR0"
        case (.sRGB, .alternate):
            0x4D53_5231 // "MSR1"
        }
    }

    private static func currentSerialSlot(for colorSpace: MirageColorSpace) -> SerialSlot {
        if let cached = cachedSerialSlots[colorSpace] {
            return cached
        }

        let defaults = UserDefaults.standard
        let defaultsKey = serialSlotDefaultsKey(for: colorSpace)
        let storedSlot = defaults.integer(forKey: defaultsKey)
        let slot = SerialSlot(rawValue: storedSlot) ?? .primary
        cachedSerialSlots[colorSpace] = slot
        return slot
    }

    private static func persistentSerialNumber(for colorSpace: MirageColorSpace) -> UInt32 {
        migrateLegacySerialStateIfNeeded()

        if let cached = cachedSerialNumbers[colorSpace] {
            return cached
        }

        let slot = currentSerialSlot(for: colorSpace)
        let serial = serialNumber(for: colorSpace, slot: slot)
        cachedSerialNumbers[colorSpace] = serial
        return serial
    }

    static func invalidatePersistentSerial(for colorSpace: MirageColorSpace) {
        migrateLegacySerialStateIfNeeded()

        var slot = currentSerialSlot(for: colorSpace)
        slot.toggle()

        let defaults = UserDefaults.standard
        defaults.set(slot.rawValue, forKey: serialSlotDefaultsKey(for: colorSpace))
        cachedSerialSlots[colorSpace] = slot

        let serial = serialNumber(for: colorSpace, slot: slot)
        cachedSerialNumbers[colorSpace] = serial
        MirageLogger.host(
            "Rotated virtual display serial for \(colorSpace.displayName) to slot \(slot.rawValue) (\(serial))"
        )
    }

    static func invalidateAllPersistentSerials() {
        for colorSpace in MirageColorSpace.allCases {
            invalidatePersistentSerial(for: colorSpace)
        }
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

        let success = activateAndValidateMode(
            display: display,
            settingsClass: settingsClass,
            modeClass: modeClass,
            pixelWidth: width,
            pixelHeight: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            serial: nil
        )

        if success {
            MirageLogger.host(
                "Updated virtual display resolution to \(width)x\(height) @\(refreshRate)Hz, hiDPI=\(hiDPI)"
            )
        } else {
            MirageLogger.error(.host, "Updated virtual display failed Retina activation")
        }

        return success
    }
}

#endif
