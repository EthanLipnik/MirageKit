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
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iPhone"
        case .pad:
            return "iPad"
        default:
            let hardwareIdentifier = hardwareModel()
            let displayName = deviceDisplayName(for: hardwareIdentifier)
            if displayName != "Unknown" {
                return displayName
            }

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
        readSysctlString(preferredHardwareIdentifierKey())
            ?? readSysctlString(fallbackHardwareIdentifierKey())
            ?? "Unknown"
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
