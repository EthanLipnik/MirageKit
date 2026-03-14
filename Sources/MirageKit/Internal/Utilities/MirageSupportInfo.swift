//
//  MirageSupportInfo.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/14/26.
//

import Darwin
import Foundation

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

    public static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 || sysctlbyname("hw.machine", nil, &size, nil, 0) == 0,
              size > 0 else {
            return "Unknown"
        }

        var machine = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &machine, &size, nil, 0) == 0 ||
            sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 {
            return String(cString: machine)
        }

        return "Unknown"
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
}
