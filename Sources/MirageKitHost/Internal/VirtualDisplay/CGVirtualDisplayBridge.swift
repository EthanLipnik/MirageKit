//
//  CGVirtualDisplayBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import CoreVideo
import Darwin
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
    private nonisolated(unsafe) static var cachedHardwareModel: String?
    nonisolated(unsafe) static var configuredDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]
    static let mirageVendorID: UInt32 = 0x1234
    static let mirageProductID: UInt32 = 0xE000
    private static let serialSlotDefaultsPrefix = "MirageVirtualDisplaySerialSlot"
    private static let descriptorProfileDefaultsPrefix = "MirageVirtualDisplayDescriptorProfile"
    private static let validationHintDefaultsPrefix = "MirageVirtualDisplayValidationHint"
    private static let hiDPIDisabledSetting: UInt32 = 0
    private static let hiDPIEnabledSetting: UInt32 = 2
    private static let colorValidationAttempts = 6
    private static let colorValidationDelaySeconds: TimeInterval = 0.06
    private static let retinaQuantizedRelativeTolerance: CGFloat = 0.12
    private static let retinaQuantizedScaleTolerance: CGFloat = 0.12
    private static let transferFunctionCodeSRGB = UInt32(
        CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_sRGB)
    )
    private static let transferFunctionCode709 = UInt32(
        CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_ITU_R_709_2)
    )
    private static let transferFunctionCodeUnknown: UInt32 = 2

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

    // MARK: - Virtual Display Context

    /// Created virtual display context
    struct VirtualDisplayContext {
        let display: AnyObject // CGVirtualDisplay instance (private type)
        let displayID: CGDirectDisplayID
        let resolution: CGSize
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let displayP3CoverageStatus: MirageDisplayP3CoverageStatus
        let scaleFactor: CGFloat
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
        refreshRate: Double,
        transferFunction: UInt32
    )
    -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedMode = (modeClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplayMode")
            return nil
        }

        let initWithTransferFunctionSelector = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
        let initSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let setTransferFunctionSelector = NSSelectorFromString("setTransferFunction:")

        let initialized: AnyObject
        if (allocatedMode as AnyObject).responds(to: initWithTransferFunctionSelector) {
            typealias InitModeWithTransferFunctionIMP = @convention(c)
            (AnyObject, Selector, UInt32, UInt32, Double, UInt32) -> Unmanaged<AnyObject>
            let initIMP = (allocatedMode as AnyObject).method(for: initWithTransferFunctionSelector)
            let initialize = unsafeBitCast(initIMP, to: InitModeWithTransferFunctionIMP.self)
            initialized = initialize(
                allocatedMode as AnyObject,
                initWithTransferFunctionSelector,
                UInt32(width),
                UInt32(height),
                refreshRate,
                transferFunction
            ).takeRetainedValue()
        } else {
            guard (allocatedMode as AnyObject).responds(to: initSelector) else {
                MirageLogger.error(
                    .host,
                    "CGVirtualDisplayMode doesn't respond to initWithWidth:height:refreshRate: or initWithWidth:height:refreshRate:transferFunction:"
                )
                return nil
            }
            typealias InitModeIMP = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
            let initIMP = (allocatedMode as AnyObject).method(for: initSelector)
            let initialize = unsafeBitCast(initIMP, to: InitModeIMP.self)
            initialized = initialize(
                allocatedMode as AnyObject,
                initSelector,
                UInt32(width),
                UInt32(height),
                refreshRate
            ).takeRetainedValue()
        }

        if (initialized as AnyObject).responds(to: setTransferFunctionSelector) {
            typealias SetTransferFunctionIMP = @convention(c) (AnyObject, Selector, UInt32) -> Void
            let setTransferFunctionIMP = (initialized as AnyObject).method(for: setTransferFunctionSelector)
            let setTransferFunction = unsafeBitCast(setTransferFunctionIMP, to: SetTransferFunctionIMP.self)
            setTransferFunction(initialized as AnyObject, setTransferFunctionSelector, transferFunction)
        }

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

    private struct TransferFunctionAttempt {
        let code: UInt32
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

    private static func transferFunctionAttempts(for colorSpace: MirageColorSpace) -> [TransferFunctionAttempt] {
        let preferred = TransferFunctionAttempt(
            code: transferFunctionCodeSRGB,
            label: "sRGB(\(transferFunctionCodeSRGB))"
        )
        let rec709 = TransferFunctionAttempt(
            code: transferFunctionCode709,
            label: "ITU-R-709(\(transferFunctionCode709))"
        )
        let unknown = TransferFunctionAttempt(
            code: transferFunctionCodeUnknown,
            label: "unknown(\(transferFunctionCodeUnknown))"
        )

        // Display P3 and sRGB both use SDR transfer functions; prefer explicit sRGB tagging first.
        let ordered = [preferred, rec709, unknown]
        var deduped: [TransferFunctionAttempt] = []
        var seen = Set<UInt32>()
        for candidate in ordered where seen.insert(candidate.code).inserted {
            deduped.append(candidate)
        }
        return deduped
    }

    private static func modeTransferFunction(_ mode: AnyObject) -> UInt32? {
        let selector = NSSelectorFromString("transferFunction")
        guard (mode as AnyObject).responds(to: selector) else { return nil }
        typealias GetTransferFunctionIMP = @convention(c) (AnyObject, Selector) -> UInt32
        let imp = (mode as AnyObject).method(for: selector)
        let getter = unsafeBitCast(imp, to: GetTransferFunctionIMP.self)
        return getter(mode as AnyObject, selector)
    }

    private struct DescriptorAttempt {
        let profile: DescriptorProfile
        let serial: UInt32
        let queue: DispatchQueue
        let label: String
    }

    private enum DescriptorProfile: String, CaseIterable, Codable {
        case persistentMainQueue = "persistent-main-queue"
        case persistentGlobalQueue = "persistent-global-queue"
        case serial0GlobalQueue = "serial0-global-queue"
    }

    private struct CachedValidationHint: Codable, Sendable {
        let profile: DescriptorProfile
        let serial: UInt32
        let coverageStatus: MirageDisplayP3CoverageStatus
    }

    private static func hardwareModel() -> String {
        if let cachedHardwareModel {
            return cachedHardwareModel
        }

        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            let fallback = "unknown-model"
            cachedHardwareModel = fallback
            return fallback
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            let fallback = "unknown-model"
            cachedHardwareModel = fallback
            return fallback
        }

        let model = String(cString: buffer)
        cachedHardwareModel = model
        return model
    }

    private static func machineModeCacheSuffix(
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let roundedRefresh = Int(refreshRate.rounded())
        return "model=\(hardwareModel())|os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)|mode=\(width)x\(height)@\(roundedRefresh)|hidpi=\(hiDPI ? 1 : 0)"
    }

    private static func descriptorProfileDefaultsKey(
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> String {
        "\(descriptorProfileDefaultsPrefix).\(colorSpace.rawValue).\(machineModeCacheSuffix(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI))"
    }

    private static func validationHintDefaultsKey(
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> String {
        "\(validationHintDefaultsPrefix).\(colorSpace.rawValue).\(machineModeCacheSuffix(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI))"
    }

    private static func preferredDescriptorProfile(
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    )
    -> DescriptorProfile? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(
            forKey: descriptorProfileDefaultsKey(
                for: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
        ),
              let profile = DescriptorProfile(rawValue: raw) else {
            return nil
        }
        return profile
    }

    private static func storePreferredDescriptorProfile(
        _ profile: DescriptorProfile,
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) {
        let key = descriptorProfileDefaultsKey(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
        UserDefaults.standard.set(profile.rawValue, forKey: key)
    }

    static func clearPreferredDescriptorProfile(for colorSpace: MirageColorSpace) {
        let defaults = UserDefaults.standard
        let profilePrefix = "\(descriptorProfileDefaultsPrefix).\(colorSpace.rawValue)."
        let hintPrefix = "\(validationHintDefaultsPrefix).\(colorSpace.rawValue)."
        let keysToClear = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(profilePrefix) || $0.hasPrefix(hintPrefix)
        }
        for key in keysToClear {
            defaults.removeObject(forKey: key)
        }
    }

    private static func cachedValidationHint(
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> CachedValidationHint? {
        let defaults = UserDefaults.standard
        let key = validationHintDefaultsKey(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedValidationHint.self, from: data)
    }

    private static func storeValidationHint(
        _ hint: CachedValidationHint,
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) {
        guard let data = try? JSONEncoder().encode(hint) else { return }
        let key = validationHintDefaultsKey(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func clearValidationHint(
        for colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) {
        let key = validationHintDefaultsKey(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func descriptorQueue(for profile: DescriptorProfile) -> DispatchQueue {
        switch profile {
        case .persistentMainQueue:
            .main
        case .persistentGlobalQueue, .serial0GlobalQueue:
            .global(qos: .userInteractive)
        }
    }

    private static func descriptorSerial(
        for profile: DescriptorProfile,
        persistentSerial: UInt32
    ) -> UInt32 {
        switch profile {
        case .serial0GlobalQueue:
            0
        case .persistentMainQueue, .persistentGlobalQueue:
            persistentSerial
        }
    }

    private static func descriptorAttempts(
        persistentSerial: UInt32,
        hiDPI: Bool,
        colorSpace: MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        cachedHint: CachedValidationHint?
    )
    -> [DescriptorAttempt] {
        let defaults: [DescriptorProfile] = hiDPI
            ? [.persistentGlobalQueue, .serial0GlobalQueue, .persistentMainQueue]
            : [.persistentGlobalQueue, .serial0GlobalQueue, .persistentMainQueue]
        var orderedProfiles: [DescriptorProfile] = []

        if let cachedHint {
            orderedProfiles.append(cachedHint.profile)
        }

        if let preferred = preferredDescriptorProfile(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        ) {
            orderedProfiles.append(preferred)
        }

        for profile in defaults where !orderedProfiles.contains(profile) {
            orderedProfiles.append(profile)
        }

        var attempts: [DescriptorAttempt] = []
        var seen = Set<String>()

        if let cachedHint {
            let key = "\(cachedHint.profile.rawValue)-\(cachedHint.serial)"
            if seen.insert(key).inserted {
                attempts.append(
                    DescriptorAttempt(
                        profile: cachedHint.profile,
                        serial: cachedHint.serial,
                        queue: descriptorQueue(for: cachedHint.profile),
                        label: "\(cachedHint.profile.rawValue)-cached"
                    )
                )
            }
        }

        for profile in orderedProfiles {
            let serial = descriptorSerial(for: profile, persistentSerial: persistentSerial)
            let key = "\(profile.rawValue)-\(serial)"
            guard seen.insert(key).inserted else { continue }
            attempts.append(
                DescriptorAttempt(
                    profile: profile,
                    serial: serial,
                    queue: descriptorQueue(for: profile),
                    label: profile.rawValue
                )
            )
        }

        return attempts
    }

    private static func validatedDisplayColorSpace(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageColorSpace
    ) -> DisplayColorSpaceValidationResult {
        var latest = DisplayColorSpaceValidationResult(
            coverageStatus: .unresolved,
            observedName: nil
        )
        for attempt in 0 ..< colorValidationAttempts {
            latest = displayColorSpaceValidation(
                displayID: displayID,
                expectedColorSpace: expectedColorSpace
            )
            switch expectedColorSpace {
            case .displayP3:
                if latest.isAcceptableForDisplayP3 { return latest }
            case .sRGB:
                if latest.coverageStatus == .sRGBFallback { return latest }
            }
            if attempt < colorValidationAttempts - 1 {
                Thread.sleep(forTimeInterval: colorValidationDelaySeconds)
            }
        }
        return latest
    }

    private static func activateAndValidateMode(
        display: AnyObject,
        settingsClass: NSObject.Type,
        modeClass: NSObject.Type,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        hiDPI: Bool,
        colorSpace: MirageColorSpace,
        serial: UInt32?
    )
    -> Bool {
        let requestedLogical = CGSize(
            width: hiDPI ? pixelWidth / 2 : pixelWidth,
            height: hiDPI ? pixelHeight / 2 : pixelHeight
        )
        let requestedPixel = CGSize(width: pixelWidth, height: pixelHeight)

        let transferFunctionCandidates = transferFunctionAttempts(for: colorSpace)
        for attempt in modeActivationAttempts(pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI) {
            for transferFunction in transferFunctionCandidates {
                guard let displayMode = createDisplayMode(
                    modeClass: modeClass,
                    width: attempt.modeWidth,
                    height: attempt.modeHeight,
                    refreshRate: refreshRate,
                    transferFunction: transferFunction.code
                ) else { continue }

                let settings = settingsClass.init()
                settings.setValue([displayMode], forKey: "modes")
                settings.setValue(attempt.hiDPISetting, forKey: "hiDPI")

                let appliedTransferFunction = modeTransferFunction(displayMode).map(String.init) ?? "unknown"
                MirageLogger.host(
                    "Applying virtual display mode attempt \(attempt.label): mode=\(attempt.modeWidth)x\(attempt.modeHeight)@\(refreshRate)Hz, hiDPISetting=\(attempt.hiDPISetting), transferFunction=\(transferFunction.label), modeReadback=\(appliedTransferFunction)"
                )

                guard applySettings(settings, to: display) else {
                    MirageLogger.error(
                        .host,
                        "Failed to apply virtual display settings for attempt \(attempt.label) with transferFunction=\(transferFunction.label)"
                    )
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
                    MirageLogger.host(
                        "Virtual display mode activation succeeded with attempt \(attempt.label) and transferFunction=\(transferFunction.label)"
                    )
                    return true
                }
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
        observed: DisplayModeSizes?,
        observedBounds: CGRect,
        observedPixelDimensions: CGSize,
        sawOnline: Bool
    )
    -> String {
        let observedLogical = observed?.logical ?? .zero
        let observedPixel = observed?.pixel ?? .zero
        let scale = observedLogical.width > 0 ? observedPixel.width / observedLogical.width : 0
        let scaleText = Double(scale).formatted(.number.precision(.fractionLength(2)))
        let serialText = serial.map(String.init) ?? "unknown"
        return "Virtual display mode validation failed: displayID=\(displayID), serial=\(serialText), hiDPISetting=\(hiDPISetting), requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observedLogical), observedPixel=\(observedPixel), observedScale=\(scaleText)x, observedBounds=\(observedBounds.size), observedPixelDimensions=\(observedPixelDimensions), online=\(sawOnline)"
    }

    private static func approximatelyMatches(
        _ observed: CGSize,
        expected: CGSize,
        tolerance: CGFloat = 1.0
    )
    -> Bool {
        abs(observed.width - expected.width) <= tolerance &&
            abs(observed.height - expected.height) <= tolerance
    }

    private static func relativeDelta(observed: CGFloat, expected: CGFloat) -> CGFloat {
        guard expected > 0 else { return .infinity }
        return abs(observed - expected) / expected
    }

    private static func validateModeActivation(
        displayID: CGDirectDisplayID,
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        hiDPISetting: UInt32,
        serial: UInt32?
    )
    -> Bool {
        let deadline = Date().addingTimeInterval(1.6)
        var lastObserved: DisplayModeSizes?
        var lastBounds = CGRect.zero
        var lastPixelDimensions = CGSize.zero
        var sawOnline = false

        while Date() < deadline {
            let isOnline = isDisplayOnline(displayID)
            sawOnline = sawOnline || isOnline

            let bounds = CGDisplayBounds(displayID)
            if bounds.width > 0, bounds.height > 0 {
                lastBounds = bounds
            }

            let pixelDimensions = CGSize(
                width: CGFloat(CGDisplayPixelsWide(displayID)),
                height: CGFloat(CGDisplayPixelsHigh(displayID))
            )
            if pixelDimensions.width > 0, pixelDimensions.height > 0 {
                lastPixelDimensions = pixelDimensions
            }

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

                if hiDPISetting == hiDPIEnabledSetting {
                    let observedScale = observed.logical.width > 0 ? observed.pixel.width / observed.logical.width : 0
                    let requestedScale = requestedLogical.width > 0 ? requestedPixel.width / requestedLogical.width : 0

                    let logicalWidthDelta = relativeDelta(observed: observed.logical.width, expected: requestedLogical.width)
                    let logicalHeightDelta = relativeDelta(observed: observed.logical.height, expected: requestedLogical.height)
                    let pixelWidthDelta = relativeDelta(observed: observed.pixel.width, expected: requestedPixel.width)
                    let pixelHeightDelta = relativeDelta(observed: observed.pixel.height, expected: requestedPixel.height)
                    let scaleDelta = relativeDelta(observed: observedScale, expected: requestedScale)

                    if logicalWidthDelta <= retinaQuantizedRelativeTolerance,
                       logicalHeightDelta <= retinaQuantizedRelativeTolerance,
                       pixelWidthDelta <= retinaQuantizedRelativeTolerance,
                       pixelHeightDelta <= retinaQuantizedRelativeTolerance,
                       scaleDelta <= retinaQuantizedScaleTolerance {
                        let observedScaleText = Double(observedScale).formatted(.number.precision(.fractionLength(2)))
                        MirageLogger.host(
                            "Virtual display mode accepted with quantized Retina validation: requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observed.logical), observedPixel=\(observed.pixel), observedScale=\(observedScaleText)x"
                        )
                        return true
                    }
                }
            } else {
                lastObserved = nil
            }

            // Some hosts keep CGDisplayCopyDisplayMode unset during 1x fallback bring-up.
            // If display geometry is stable and online, allow the 1x path to proceed.
            if hiDPISetting == hiDPIDisabledSetting, isOnline {
                let boundsMatch = bounds.width > 0 &&
                    bounds.height > 0 &&
                    approximatelyMatches(bounds.size, expected: requestedLogical)
                let pixelMatch = pixelDimensions.width > 0 &&
                    pixelDimensions.height > 0 &&
                    approximatelyMatches(pixelDimensions, expected: requestedPixel)

                if boundsMatch || pixelMatch {
                    MirageLogger.host(
                        "Virtual display mode accepted with lenient 1x validation: bounds=\(bounds.size), pixelDimensions=\(pixelDimensions), requested=\(requestedPixel)"
                    )
                    return true
                }
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        MirageLogger.host(
            modeValidationLogLine(
                displayID: displayID,
                serial: serial,
                hiDPISetting: hiDPISetting,
                requestedLogical: requestedLogical,
                requestedPixel: requestedPixel,
                observed: lastObserved,
                observedBounds: lastBounds,
                observedPixelDimensions: lastPixelDimensions,
                sawOnline: sawOnline
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

        var serialRetryAttempted = false
        while true {
            let persistentSerial = persistentSerialNumber(for: colorSpace)
            let validationHint = cachedValidationHint(
                for: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
            let descriptorProfiles = descriptorAttempts(
                persistentSerial: persistentSerial,
                hiDPI: hiDPI,
                colorSpace: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                cachedHint: validationHint
            )
            var sawColorValidationFailure = false

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
                    guard let allocatedDisplay = (displayClass as AnyObject).perform(allocSelector)?
                        .takeUnretainedValue() else {
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
                        colorSpace: colorSpace,
                        serial: profile.serial
                    ) else {
                        let modeLabel = hiDPI ? "Retina" : "1x"
                        MirageLogger.host(
                            "Virtual display \(modeLabel) activation failed for profile \(profile.label)"
                        )
                        let invalidateSelector = NSSelectorFromString("invalidate")
                        if (display as AnyObject).responds(to: invalidateSelector) {
                            _ = (display as AnyObject).perform(invalidateSelector)
                        }
                        return
                    }

                    guard let displayID else {
                        MirageLogger.error(
                            .host,
                            "Failed to get displayID from CGVirtualDisplay for profile \(profile.label)"
                        )
                        let invalidateSelector = NSSelectorFromString("invalidate")
                        if (display as AnyObject).responds(to: invalidateSelector) {
                            _ = (display as AnyObject).perform(invalidateSelector)
                        }
                        return
                    }

                    let colorValidation = validatedDisplayColorSpace(
                        displayID: displayID,
                        expectedColorSpace: colorSpace
                    )
                    let observedColorName = colorValidation.observedName ?? "unknown"
                    let coverageStatus = colorValidation.coverageStatus
                    switch coverageStatus {
                    case .strictCanonical:
                        MirageLogger.host(
                            "Virtual display color profile validated (color=\(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                        )
                    case .wideGamutEquivalent:
                        if colorSpace == .displayP3 {
                            MirageLogger.host(
                                "Virtual display color profile validated (color=Display P3 equivalent-wide-gamut, coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                            )
                        } else {
                            MirageLogger.host(
                                "Virtual display color profile mismatch tolerated for fallback (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                            )
                        }
                    case .sRGBFallback, .unresolved:
                        if colorSpace == .displayP3 {
                            sawColorValidationFailure = true
                            clearValidationHint(
                                for: colorSpace,
                                width: width,
                                height: height,
                                refreshRate: refreshRate,
                                hiDPI: hiDPI
                            )
                            MirageLogger.host(
                                "WARNING: Virtual display color profile mismatch (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                            )
                            let invalidateSelector = NSSelectorFromString("invalidate")
                            if (display as AnyObject).responds(to: invalidateSelector) {
                                _ = (display as AnyObject).perform(invalidateSelector)
                            }
                            return
                        } else {
                            MirageLogger.host(
                                "Virtual display color profile mismatch tolerated for fallback (expected \(colorSpace.displayName), coverage=\(coverageStatus.rawValue), observed \(observedColorName), profile \(profile.label), serial \(profile.serial))"
                            )
                        }
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
                        colorSpace: colorSpace,
                        displayP3CoverageStatus: coverageStatus,
                        scaleFactor: resolvedScaleFactor(displayID: displayID, hiDPI: hiDPI)
                    )
                }

                if let creationResult {
                    storePreferredDescriptorProfile(
                        profile.profile,
                        for: colorSpace,
                        width: width,
                        height: height,
                        refreshRate: refreshRate,
                        hiDPI: hiDPI
                    )
                    storeValidationHint(
                        CachedValidationHint(
                            profile: profile.profile,
                            serial: profile.serial,
                            coverageStatus: creationResult.displayP3CoverageStatus
                        ),
                        for: colorSpace,
                        width: width,
                        height: height,
                        refreshRate: refreshRate,
                        hiDPI: hiDPI
                    )
                    return creationResult
                }

                if let failedDisplayID,
                   !teardownFailedDisplay(displayID: failedDisplayID, profileLabel: profile.label) {
                    return nil
                }
            }

            if sawColorValidationFailure, !serialRetryAttempted {
                serialRetryAttempted = true
                invalidatePersistentSerial(for: colorSpace)
                MirageLogger.host("Retrying virtual display creation with rotated serial after color validation failure")
                continue
            }
            break
        }

        if hiDPI {
            MirageLogger.host("Virtual display failed Retina activation for all descriptor profiles")
        } else {
            MirageLogger.host("Virtual display failed 1x activation for all descriptor profiles")
        }
        return nil
    }

    private static func serialSlotDefaultsKey(for colorSpace: MirageColorSpace) -> String {
        "\(serialSlotDefaultsPrefix).\(colorSpace.rawValue)"
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
        if let cached = cachedSerialNumbers[colorSpace] {
            return cached
        }

        let slot = currentSerialSlot(for: colorSpace)
        let serial = serialNumber(for: colorSpace, slot: slot)
        cachedSerialNumbers[colorSpace] = serial
        return serial
    }

    static func invalidatePersistentSerial(for colorSpace: MirageColorSpace) {
        var slot = currentSerialSlot(for: colorSpace)
        slot.toggle()

        let defaults = UserDefaults.standard
        defaults.set(slot.rawValue, forKey: serialSlotDefaultsKey(for: colorSpace))
        cachedSerialSlots[colorSpace] = slot

        let serial = serialNumber(for: colorSpace, slot: slot)
        cachedSerialNumbers[colorSpace] = serial
        clearPreferredDescriptorProfile(for: colorSpace)
        MirageLogger.host(
            "Rotated virtual display serial for \(colorSpace.displayName) to slot \(slot.rawValue) (\(serial))"
        )
    }

    static func invalidateAllPersistentSerials() {
        for colorSpace in MirageColorSpace.allCases {
            invalidatePersistentSerial(for: colorSpace)
        }
    }

    private static func resolvedScaleFactor(displayID: CGDirectDisplayID, hiDPI: Bool) -> CGFloat {
        if let observed = currentDisplayModeSizes(displayID),
           observed.logical.width > 0,
           observed.logical.height > 0,
           observed.pixel.width > 0,
           observed.pixel.height > 0 {
            let scale = observed.pixel.width / observed.logical.width
            if scale > 0 { return scale }
        }
        return hiDPI ? 2.0 : 1.0
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
        hiDPI: Bool = true,
        colorSpace: MirageColorSpace = .displayP3
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
            colorSpace: colorSpace,
            serial: nil
        )

        if success {
            MirageLogger.host(
                "Updated virtual display resolution to \(width)x\(height) @\(refreshRate)Hz, hiDPI=\(hiDPI)"
            )
        } else {
            let modeLabel = hiDPI ? "Retina" : "1x"
            MirageLogger.error(.host, "Updated virtual display failed \(modeLabel) activation")
        }

        return success
    }
}

#endif
