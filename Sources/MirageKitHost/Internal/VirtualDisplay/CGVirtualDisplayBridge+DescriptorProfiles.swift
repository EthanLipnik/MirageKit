//
//  CGVirtualDisplayBridge+DescriptorProfiles.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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

extension CGVirtualDisplayBridge {
    struct DescriptorAttempt {
        let profile: DescriptorProfile
        let serial: UInt32
        let queue: DispatchQueue
        let label: String
    }

    enum DescriptorProfile: String, CaseIterable, Codable {
        case persistentMainQueue = "persistent-main-queue"
        case persistentGlobalQueue = "persistent-global-queue"
        case serial0GlobalQueue = "serial0-global-queue"
    }

    struct CachedValidationHint: Codable {
        let profile: DescriptorProfile
        let serial: UInt32
    }

    struct VirtualDisplayProfileCreationResult {
        let context: VirtualDisplayContext?
        let failedDisplayID: CGDirectDisplayID?
        let sawColorValidationFailure: Bool
    }

    static func isGrossRetinaModeMismatch(
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        observedLogical: CGSize,
        observedPixel: CGSize,
        hiDPISetting: UInt32
    ) -> Bool {
        guard hiDPISetting == hiDPIEnabledSetting else { return false }
        guard requestedLogical.width > 0,
              requestedLogical.height > 0,
              requestedPixel.width > 0,
              requestedPixel.height > 0,
              observedLogical.width > 0,
              observedLogical.height > 0,
              observedPixel.width > 0,
              observedPixel.height > 0 else {
            return false
        }

        let logicalWidthRatio = observedLogical.width / requestedLogical.width
        let logicalHeightRatio = observedLogical.height / requestedLogical.height
        let pixelWidthRatio = observedPixel.width / requestedPixel.width
        let pixelHeightRatio = observedPixel.height / requestedPixel.height

        return logicalWidthRatio <= grossRetinaMismatchScaleThreshold ||
            logicalHeightRatio <= grossRetinaMismatchScaleThreshold ||
            pixelWidthRatio <= grossRetinaMismatchScaleThreshold ||
            pixelHeightRatio <= grossRetinaMismatchScaleThreshold
    }

    static func shouldEvictCachedDescriptorProfile(
        failedAttempt: DescriptorAttempt,
        preferredProfile: DescriptorProfile?,
        cachedHint: CachedValidationHint?
    ) -> Bool {
        if failedAttempt.profile == preferredProfile {
            return true
        }
        if let cachedHint,
           cachedHint.profile == failedAttempt.profile,
           cachedHint.serial == failedAttempt.serial {
            return true
        }
        return false
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

        let model = String.mirageDecodedCString(buffer) ?? "unknown-model"
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
        for colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> String {
        "\(descriptorProfileDefaultsPrefix).\(colorSpace.rawValue).\(machineModeCacheSuffix(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI))"
    }

    private static func validationHintDefaultsKey(
        for colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) -> String {
        "\(validationHintDefaultsPrefix).\(colorSpace.rawValue).\(machineModeCacheSuffix(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI))"
    }

    static func preferredDescriptorProfile(
        for colorSpace: MirageMedia.MirageColorSpace,
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

    static func storePreferredDescriptorProfile(
        _ profile: DescriptorProfile,
        for colorSpace: MirageMedia.MirageColorSpace,
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

    static func clearPreferredDescriptorProfile(for colorSpace: MirageMedia.MirageColorSpace) {
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

    static func clearPreferredDescriptorProfile(
        for colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) {
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: descriptorProfileDefaultsKey(
                for: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
        )
        defaults.removeObject(
            forKey: validationHintDefaultsKey(
                for: colorSpace,
                width: width,
                height: height,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
        )
    }

    static func cachedValidationHint(
        for colorSpace: MirageMedia.MirageColorSpace,
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
        do {
            return try JSONDecoder().decode(CachedValidationHint.self, from: data)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode virtual-display validation hint: ")
            return nil
        }
    }

    static func storeValidationHint(
        _ hint: CachedValidationHint,
        for colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        hiDPI: Bool
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(hint)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to encode virtual-display validation hint: ")
            return
        }
        let key = validationHintDefaultsKey(
            for: colorSpace,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clearValidationHint(
        for colorSpace: MirageMedia.MirageColorSpace,
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

    static func descriptorAttempts(
        persistentSerial: UInt32,
        hiDPI: Bool,
        colorSpace: MirageMedia.MirageColorSpace,
        width: Int,
        height: Int,
        refreshRate: Double,
        cachedHint: CachedValidationHint?
    )
    -> [DescriptorAttempt] {
        let serialIsStale = isMirageSerialOnline(persistentSerial)
        let defaults: [DescriptorProfile]
        if serialIsStale {
            MirageLogger.host(
                "Persistent serial \(persistentSerial) maps to online orphaned display; rotating serial and using fallback profiles"
            )
            invalidatePersistentSerial(for: colorSpace)
            defaults = [.persistentGlobalQueue, .serial0GlobalQueue]
        } else {
            defaults = hiDPI
                ? [.persistentGlobalQueue, .serial0GlobalQueue, .persistentMainQueue]
                : [.persistentGlobalQueue, .serial0GlobalQueue, .persistentMainQueue]
        }
        var orderedProfiles: [DescriptorProfile] = []

        if let cachedHint, !(serialIsStale && cachedHint.serial == persistentSerial) {
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

        if let cachedHint, !(serialIsStale && cachedHint.serial == persistentSerial) {
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

    private static func serialSlotDefaultsKey(for colorSpace: MirageMedia.MirageColorSpace) -> String {
        "\(serialSlotDefaultsPrefix).\(colorSpace.rawValue)"
    }

    private static func serialNumber(for colorSpace: MirageMedia.MirageColorSpace, slot: SerialSlot) -> UInt32 {
        switch (colorSpace, slot) {
        case (.displayP3, .primary):
            0x4D50_3330
        case (.displayP3, .alternate):
            0x4D50_3331
        case (.sRGB, .primary):
            0x4D53_5230
        case (.sRGB, .alternate):
            0x4D53_5231
        }
    }

    private static func currentSerialSlot(for colorSpace: MirageMedia.MirageColorSpace) -> SerialSlot {
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

    static func persistentSerialNumber(for colorSpace: MirageMedia.MirageColorSpace) -> UInt32 {
        if let cached = cachedSerialNumbers[colorSpace] {
            return cached
        }

        let slot = currentSerialSlot(for: colorSpace)
        let serial = serialNumber(for: colorSpace, slot: slot)
        cachedSerialNumbers[colorSpace] = serial
        return serial
    }

    static func invalidatePersistentSerial(for colorSpace: MirageMedia.MirageColorSpace) {
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
        for colorSpace in MirageMedia.MirageColorSpace.allCases {
            invalidatePersistentSerial(for: colorSpace)
        }
    }

}

#endif
