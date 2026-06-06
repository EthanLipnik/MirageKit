//
//  CGVirtualDisplayBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Darwin
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
    nonisolated(unsafe) static var cachedSerialNumbers: [MirageMedia.MirageColorSpace: UInt32] = [:]
    nonisolated(unsafe) static var cachedSerialSlots: [MirageMedia.MirageColorSpace: SerialSlot] = [:]
    nonisolated(unsafe) static var cachedHardwareModel: String?
    nonisolated(unsafe) static var configuredDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]
    static let mirageVendorID: UInt32 = 0x1234
    static let mirageProductID: UInt32 = 0xE000
    static let serialSlotDefaultsPrefix = "MirageVirtualDisplaySerialSlot"
    static let descriptorProfileDefaultsPrefix = "MirageVirtualDisplayDescriptorProfile"
    static let validationHintDefaultsPrefix = "MirageVirtualDisplayValidationHint"
    static let hiDPIDisabledSetting: UInt32 = 0
    static let hiDPIEnabledSetting: UInt32 = 2
    static let colorValidationAttempts = 6
    static let colorValidationDelaySeconds: TimeInterval = 0.06
    static let retinaQuantizedRelativeTolerance: CGFloat = 0.12
    static let retinaQuantizedScaleTolerance: CGFloat = 0.12
    static let grossRetinaMismatchScaleThreshold: CGFloat = 0.6
    static let grossRetinaMismatchPollThreshold = 3
    static let grossRetinaMismatchAbortSeconds: CFAbsoluteTime = 0.25
    enum SerialSlot: Int {
        case primary = 0
        case alternate = 1

        mutating func toggle() {
            self = self == .primary ? .alternate : .primary
        }
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
}

// MARK: - Virtual Display Creation

extension CGVirtualDisplayBridge {
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
        colorSpace: MirageMedia.MirageColorSpace,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    -> VirtualDisplayCreationResult {
        guard loadPrivateAPIs() else {
            return VirtualDisplayCreationResult(context: nil, modeActivationResult: nil)
        }

        guard let descriptorClass = cgVirtualDisplayDescriptorClass as? NSObject.Type,
              let settingsClass = cgVirtualDisplaySettingsClass as? NSObject.Type,
              let modeClass = cgVirtualDisplayModeClass as? NSObject.Type,
              let displayClass = cgVirtualDisplayClass as? NSObject.Type else {
            return VirtualDisplayCreationResult(context: nil, modeActivationResult: nil)
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
            if startupBudget?.isExpired == true {
                MirageLogger.host("Virtual display creation stopped because startup budget expired")
                return VirtualDisplayCreationResult(context: nil, modeActivationResult: .failed)
            }
            let persistentSerial = persistentSerialNumber(for: colorSpace)
            var validationHint = cachedValidationHint(
                for: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
            var preferredProfile = preferredDescriptorProfile(
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
                if startupBudget?.isExpired == true {
                    MirageLogger.host("Virtual display descriptor attempts stopped because startup budget expired")
                    return VirtualDisplayCreationResult(context: nil, modeActivationResult: .failed)
                }
                let profileResult = createVirtualDisplay(
                    name: name,
                    width: width,
                    height: height,
                    refreshRate: refreshRate,
                    hiDPI: hiDPI,
                    ppi: ppi,
                    colorSpace: colorSpace,
                    profile: profile,
                    descriptorClass: descriptorClass,
                    settingsClass: settingsClass,
                    modeClass: modeClass,
                    displayClass: displayClass,
                    originalMainDisplayID: originalMainDisplayID,
                    startupBudget: startupBudget
                )
                if profileResult.sawColorValidationFailure {
                    sawColorValidationFailure = true
                }

                if let creationResult = profileResult.context {
                    if creationResult.colorSpace == colorSpace {
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
                                serial: profile.serial
                            ),
                            for: colorSpace,
                            width: width,
                            height: height,
                            refreshRate: refreshRate,
                            hiDPI: hiDPI
                        )
                    }
                    return VirtualDisplayCreationResult(
                        context: creationResult,
                        modeActivationResult: profileResult.modeActivationResult ?? .succeeded
                    )
                }

                if profileResult.modeActivationResult == .retinaCollapsedToOneX {
                    MirageLogger.host(
                        "Virtual display Retina activation collapsed to 1x; skipping descriptor profile retries"
                    )
                    return VirtualDisplayCreationResult(
                        context: nil,
                        modeActivationResult: .retinaCollapsedToOneX
                    )
                }

                if shouldEvictCachedDescriptorProfile(
                    failedAttempt: profile,
                    preferredProfile: preferredProfile,
                    cachedHint: validationHint
                ) {
                    clearPreferredDescriptorProfile(
                        for: colorSpace,
                        width: width,
                        height: height,
                        refreshRate: refreshRate,
                        hiDPI: hiDPI
                    )
                    clearValidationHint(
                        for: colorSpace,
                        width: width,
                        height: height,
                        refreshRate: refreshRate,
                        hiDPI: hiDPI
                    )
                    preferredProfile = nil
                    validationHint = nil
                    MirageLogger.host(
                        "Evicted cached descriptor profile after activation failure: profile=\(profile.label), serial=\(profile.serial)"
                    )
                }

                if let failedDisplayID = profileResult.failedDisplayID,
                   !teardownFailedDisplay(displayID: failedDisplayID, profileLabel: profile.label) {
                    return VirtualDisplayCreationResult(
                        context: nil,
                        modeActivationResult: profileResult.modeActivationResult
                    )
                }
            }

            if !serialRetryAttempted {
                serialRetryAttempted = true
                invalidatePersistentSerial(for: colorSpace)
                let retryReason = sawColorValidationFailure ? "color validation failure" : "activation failure"
                MirageLogger.host("Retrying virtual display creation with rotated serial after \(retryReason)")
                continue
            }
            break
        }

        // Clear cached descriptor profile on total failure so the next attempt
        // doesn't deterministically reuse a known-bad profile.
        clearPreferredDescriptorProfile(for: colorSpace)

        if hiDPI {
            MirageLogger.host("Virtual display failed Retina activation for all descriptor profiles")
        } else {
            MirageLogger.host("Virtual display failed 1x activation for all descriptor profiles")
        }
        return VirtualDisplayCreationResult(context: nil, modeActivationResult: .failed)
    }

    private static func createVirtualDisplay(
        name: String,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool,
        ppi: Double,
        colorSpace: MirageMedia.MirageColorSpace,
        profile: DescriptorAttempt,
        descriptorClass: NSObject.Type,
        settingsClass: NSObject.Type,
        modeClass: NSObject.Type,
        displayClass: NSObject.Type,
        originalMainDisplayID: CGDirectDisplayID,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) -> VirtualDisplayProfileCreationResult {
        var failedDisplayID: CGDirectDisplayID?
        var creationResult: VirtualDisplayContext?
        var sawColorValidationFailure = false
        var modeActivationResult: VirtualDisplayModeActivationResult?

        autoreleasepool {
            let descriptor = descriptorClass.init()
            configureDescriptor(
                descriptor,
                name: name,
                width: width,
                height: height,
                ppi: ppi,
                hiDPI: hiDPI,
                profile: profile
            )

            MirageLogger.host(
                "Creating virtual display '\(name)' at \(width)x\(height) pixels, hiDPI=\(hiDPI), color=\(colorSpace.displayName), profile=\(profile.label), serial=\(profile.serial)"
            )

            guard let display = allocateVirtualDisplay(displayClass: displayClass, descriptor: descriptor, profile: profile) else {
                return
            }

            let displayID = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID
            failedDisplayID = displayID

            let activationResult = activateAndValidateMode(
                display: display as AnyObject,
                settingsClass: settingsClass,
                modeClass: modeClass,
                pixelWidth: width,
                pixelHeight: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI,
                serial: profile.serial,
                startupBudget: startupBudget
            )
            modeActivationResult = activationResult
            guard activationResult.isUsableForCreation else {
                let modeLabel = hiDPI ? "Retina" : "1x"
                MirageLogger.host(
                    "Virtual display \(modeLabel) activation failed for profile \(profile.label)"
                )
                invalidateVirtualDisplay(display)
                return
            }
            if activationResult == .retinaCollapsedToOneX {
                MirageLogger.host(
                    "Virtual display Retina activation accepted as degraded 1x mode for profile \(profile.label)"
                )
            }

            guard let displayID else {
                MirageLogger.error(
                    .host,
                    "Failed to get displayID from CGVirtualDisplay for profile \(profile.label)"
                )
                invalidateVirtualDisplay(display)
                return
            }

            let colorValidation = validatedDisplayColorSpace(
                displayID: displayID,
                expectedColorSpace: colorSpace
            )
            let acceptsCollapsedSRGBFallback = activationResult == .retinaCollapsedToOneX &&
                colorSpace == .displayP3 &&
                colorValidation.coverageStatus == .sRGBFallback
            guard acceptValidatedVirtualDisplayColor(
                colorValidation,
                colorSpace: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI,
                profile: profile,
                allowDisplayP3SRGBFallback: acceptsCollapsedSRGBFallback
            ) else {
                sawColorValidationFailure = colorSpace == .displayP3
                invalidateVirtualDisplay(display)
                return
            }
            let effectiveColorSpace: MirageColorSpace = acceptsCollapsedSRGBFallback ? .sRGB : colorSpace

            MirageLogger.host("Created virtual display with ID: \(displayID)")
            configureDisplaySeparation(
                virtualDisplayID: displayID,
                originalMainDisplayID: originalMainDisplayID
            )
            creationResult = VirtualDisplayContext(
                display: display as AnyObject,
                displayID: displayID,
                refreshRate: refreshRate,
                colorSpace: effectiveColorSpace,
                displayP3CoverageStatus: colorValidation.coverageStatus
            )
        }

        return VirtualDisplayProfileCreationResult(
            context: creationResult,
            failedDisplayID: failedDisplayID,
            sawColorValidationFailure: sawColorValidationFailure,
            modeActivationResult: modeActivationResult
        )
    }

}

// MARK: - Resolution Updates

extension CGVirtualDisplayBridge {
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
        isFallbackProbe: Bool = false
    )
    -> Bool {
        guard loadPrivateAPIs() else { return false }

        guard let settingsClass = cgVirtualDisplaySettingsClass as? NSObject.Type,
              let modeClass = cgVirtualDisplayModeClass as? NSObject.Type else {
            return false
        }

        let activationResult = activateAndValidateMode(
            display: display,
            settingsClass: settingsClass,
            modeClass: modeClass,
            pixelWidth: width,
            pixelHeight: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            serial: nil,
            startupBudget: nil
        )

        if activationResult.succeeded {
            MirageLogger.host(
                "Updated virtual display resolution to \(width)x\(height) @\(refreshRate)Hz, hiDPI=\(hiDPI)"
            )
        } else {
            logVirtualDisplayResolutionUpdateFailure(
                hiDPI: hiDPI,
                isTerminal: !isFallbackProbe
            )
        }

        return activationResult.succeeded
    }
}

#endif
