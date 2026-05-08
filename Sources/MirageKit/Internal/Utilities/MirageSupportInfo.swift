//
//  MirageSupportInfo.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/14/26.
//

import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum MirageSupportInfo {
    public static func appVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static func buildNumber() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    public static func appVersionSummary() -> String? {
        let version = trimmedValue(appVersion())
        let build = trimmedValue(buildNumber())

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        default:
            return nil
        }
    }

    public static func deviceDisplayName() -> String {
#if os(visionOS)
        return "Apple Vision Pro"
#elseif os(iOS)
        let displayName = deviceDisplayName(for: hardwareModel())
        if displayName != "Unknown" {
            return displayName
        }

        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iPhone"
        case .pad:
            return "iPad"
        default:
            return trimmedValue(UIDevice.current.model) ?? "iOS Device"
        }
#elseif os(macOS)
        let displayName = deviceDisplayName(for: hardwareModel())
        return displayName == "Unknown" ? "Mac" : displayName
#else
        let hardwareIdentifier = hardwareModel()
        let displayName = deviceDisplayName(for: hardwareIdentifier)
        return displayName == "Unknown" ? displayValue(hardwareIdentifier) : displayName
#endif
    }

    public static func hardwareModel() -> String {
#if targetEnvironment(simulator)
        if let simulatorModelIdentifier = trimmedValue(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]) {
            return simulatorModelIdentifier
        }
#endif
        readSysctlString(preferredHardwareIdentifierKey())
            ?? readSysctlString(fallbackHardwareIdentifierKey())
            ?? "Unknown"
    }

    public static func deviceModelIdentifier() -> String {
        hardwareModel()
    }

    public static func chipName() -> String? {
#if os(macOS)
        return chipName(systemCPUBrand: readSysctlString("machdep.cpu.brand_string"))
#else
        return nil
#endif
    }

    public static func displayValue(_ value: String?) -> String {
        trimmedValue(value) ?? "Unknown"
    }

    public static func trimmedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func deviceDisplayName(for hardwareIdentifier: String) -> String {
        guard let normalizedIdentifier = trimmedValue(hardwareIdentifier)?.lowercased() else {
            return "Unknown"
        }
        if let displayName = iOSDeviceDisplayName(for: normalizedIdentifier) {
            return displayName
        }
        if isKnownMacStudioModelIdentifier(normalizedIdentifier) {
            return "Mac Studio"
        }
        if isKnownMacMiniModelIdentifier(normalizedIdentifier) {
            return "Mac mini"
        }

        switch normalizedIdentifier {
        case let identifier where identifier.hasPrefix("iphone"):
            return "iPhone"
        case let identifier where identifier.hasPrefix("ipad"):
            return "iPad"
        case let identifier where identifier.hasPrefix("realitydevice"),
             let identifier where identifier.hasPrefix("vision"),
             let identifier where identifier.hasPrefix("n301"):
            return "Apple Vision Pro"
        case let identifier where identifier.hasPrefix("macbookair"):
            return "MacBook Air"
        case let identifier where identifier.hasPrefix("macbookpro"):
            return "MacBook Pro"
        case let identifier where identifier.hasPrefix("macbook"):
            return "MacBook"
        case let identifier where identifier.hasPrefix("macmini"):
            return "Mac mini"
        case let identifier where identifier.hasPrefix("macstudio"):
            return "Mac Studio"
        case let identifier where identifier.hasPrefix("macpro"):
            return "Mac Pro"
        case let identifier where identifier.hasPrefix("imac"):
            return "iMac"
        case let identifier where identifier.hasPrefix("virtualmac"),
             let identifier where identifier.hasPrefix("mac"):
            return "Mac"
        default:
            return "Unknown"
        }
    }

    private static func iOSDeviceDisplayName(for identifier: String) -> String? {
        switch identifier {
        case "iphone11,2":
            return "iPhone XS"
        case "iphone11,4",
             "iphone11,6":
            return "iPhone XS Max"
        case "iphone11,8":
            return "iPhone XR"
        case "iphone12,1":
            return "iPhone 11"
        case "iphone12,3":
            return "iPhone 11 Pro"
        case "iphone12,5":
            return "iPhone 11 Pro Max"
        case "iphone12,8":
            return "iPhone SE (2nd generation)"
        case "iphone13,1":
            return "iPhone 12 mini"
        case "iphone13,2":
            return "iPhone 12"
        case "iphone13,3":
            return "iPhone 12 Pro"
        case "iphone13,4":
            return "iPhone 12 Pro Max"
        case "iphone14,2":
            return "iPhone 13 Pro"
        case "iphone14,3":
            return "iPhone 13 Pro Max"
        case "iphone14,4":
            return "iPhone 13 mini"
        case "iphone14,5":
            return "iPhone 13"
        case "iphone14,6":
            return "iPhone SE (3rd generation)"
        case "iphone14,7":
            return "iPhone 14"
        case "iphone14,8":
            return "iPhone 14 Plus"
        case "iphone15,2":
            return "iPhone 14 Pro"
        case "iphone15,3":
            return "iPhone 14 Pro Max"
        case "iphone15,4":
            return "iPhone 15"
        case "iphone15,5":
            return "iPhone 15 Plus"
        case "iphone16,1":
            return "iPhone 15 Pro"
        case "iphone16,2":
            return "iPhone 15 Pro Max"
        case "iphone17,1":
            return "iPhone 16 Pro"
        case "iphone17,2":
            return "iPhone 16 Pro Max"
        case "iphone17,3":
            return "iPhone 16"
        case "iphone17,4":
            return "iPhone 16 Plus"
        case "iphone17,5":
            return "iPhone 16e"
        case "iphone18,1":
            return "iPhone 17 Pro"
        case "iphone18,2":
            return "iPhone 17 Pro Max"
        case "iphone18,3":
            return "iPhone 17"
        case "iphone18,4":
            return "iPhone Air"
        case "iphone18,5":
            return "iPhone 17e"
        case "ipad7,1",
             "ipad7,2":
            return "iPad Pro 12.9-inch (2nd generation)"
        case "ipad7,3",
             "ipad7,4":
            return "iPad Pro 10.5-inch"
        case "ipad7,5",
             "ipad7,6":
            return "iPad (6th generation)"
        case "ipad7,11",
             "ipad7,12":
            return "iPad (7th generation)"
        case "ipad8,1",
             "ipad8,2",
             "ipad8,3",
             "ipad8,4":
            return "iPad Pro 11-inch (1st generation)"
        case "ipad8,5",
             "ipad8,6",
             "ipad8,7",
             "ipad8,8":
            return "iPad Pro 12.9-inch (3rd generation)"
        case "ipad8,9",
             "ipad8,10":
            return "iPad Pro 11-inch (2nd generation)"
        case "ipad8,11",
             "ipad8,12":
            return "iPad Pro 12.9-inch (4th generation)"
        case "ipad11,1",
             "ipad11,2":
            return "iPad mini (5th generation)"
        case "ipad11,3",
             "ipad11,4":
            return "iPad Air (3rd generation)"
        case "ipad11,6",
             "ipad11,7":
            return "iPad (8th generation)"
        case "ipad12,1",
             "ipad12,2":
            return "iPad (9th generation)"
        case "ipad13,1",
             "ipad13,2":
            return "iPad Air (4th generation)"
        case "ipad13,4",
             "ipad13,5",
             "ipad13,6",
             "ipad13,7":
            return "iPad Pro 11-inch (3rd generation)"
        case "ipad13,8",
             "ipad13,9",
             "ipad13,10",
             "ipad13,11":
            return "iPad Pro 12.9-inch (5th generation)"
        case "ipad13,16",
             "ipad13,17":
            return "iPad Air (5th generation)"
        case "ipad13,18",
             "ipad13,19":
            return "iPad (10th generation)"
        case "ipad14,1",
             "ipad14,2":
            return "iPad mini (6th generation)"
        case "ipad14,3",
             "ipad14,4":
            return "iPad Pro 11-inch (4th generation)"
        case "ipad14,5",
             "ipad14,6":
            return "iPad Pro 12.9-inch (6th generation)"
        case "ipad14,8",
             "ipad14,9":
            return "iPad Air 11-inch (M2)"
        case "ipad14,10",
             "ipad14,11":
            return "iPad Air 13-inch (M2)"
        case "ipad15,3",
             "ipad15,4":
            return "iPad Air 11-inch (M3)"
        case "ipad15,5",
             "ipad15,6":
            return "iPad Air 13-inch (M3)"
        case "ipad15,7",
             "ipad15,8":
            return "iPad (A16)"
        case "ipad16,1",
             "ipad16,2":
            return "iPad mini (A17 Pro)"
        case "ipad16,3",
             "ipad16,4":
            return "iPad Pro 11-inch (M4)"
        case "ipad16,5",
             "ipad16,6":
            return "iPad Pro 13-inch (M4)"
        case "ipad16,8",
             "ipad16,9":
            return "iPad Air 11-inch (M4)"
        case "ipad16,10",
             "ipad16,11":
            return "iPad Air 13-inch (M4)"
        case "ipad17,1",
             "ipad17,2":
            return "iPad Pro 11-inch (M5)"
        case "ipad17,3",
             "ipad17,4":
            return "iPad Pro 13-inch (M5)"
        default:
            return nil
        }
    }

    private static func isKnownMacStudioModelIdentifier(_ identifier: String) -> Bool {
        [
            "mac13,1",
            "mac13,2",
            "mac14,13",
            "mac14,14",
            "mac15,14",
            "mac16,9",
        ].contains(identifier)
    }

    private static func isKnownMacMiniModelIdentifier(_ identifier: String) -> Bool {
        [
            "mac14,3",
            "mac14,12",
            "mac16,10",
            "mac16,11",
        ].contains(identifier)
    }

    static func chipName(systemCPUBrand: String?) -> String? {
        trimmedValue(systemCPUBrand)
    }

    private static func preferredHardwareIdentifierKey() -> String {
#if os(macOS)
        "hw.model"
#else
        "hw.machine"
#endif
    }

    private static func fallbackHardwareIdentifierKey() -> String {
#if os(macOS)
        "hw.machine"
#else
        "hw.model"
#endif
    }

    private static func readSysctlString(_ key: String) -> String? {
        var size = 0
        let probeStatus = key.withCString { sysctlbyname($0, nil, &size, nil, 0) }
        guard probeStatus == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        let readStatus = key.withCString { sysctlbyname($0, &buffer, &size, nil, 0) }
        guard readStatus == 0 else {
            return nil
        }

        return trimmedValue(String.mirageDecodedCString(buffer))
    }
}

package extension String {
    static func mirageDecodedCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func mirageDecodedCString(_ pointer: UnsafePointer<CChar>) -> String {
        let bytes = UnsafeBufferPointer(start: pointer, count: strlen(pointer)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
