//
//  MirageLatencyOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/16/26.
//

import Foundation

package enum MirageVideoIngressMode: String, Sendable, Equatable {
    case direct
    case processor
}

package enum MirageLatencyOptions {
    package static let videoIngressModeKey = "MirageVideoIngressMode"
    package static let disablePriorityInputKey = "MirageDisablePriorityInput"
    package static let disableStreamingBackgroundRefreshKey = "MirageDisableStreamingBackgroundRefresh"
    package static let latencyDiagnosticsKey = "MirageLatencyDiagnostics"

    package static func videoIngressMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> MirageVideoIngressMode {
        guard let rawValue = optionString(
            forKey: videoIngressModeKey,
            environment: environment,
            defaults: defaults
        ) else {
            return .direct
        }
        return MirageVideoIngressMode(rawValue: rawValue.lowercased()) ?? .direct
    }

    package static func disablePriorityInput(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        optionBool(
            forKey: disablePriorityInputKey,
            defaultValue: false,
            environment: environment,
            defaults: defaults
        )
    }

    package static func disableStreamingBackgroundRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        optionBool(
            forKey: disableStreamingBackgroundRefreshKey,
            defaultValue: true,
            environment: environment,
            defaults: defaults
        )
    }

    package static func latencyDiagnosticsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if MirageLogger.fullVerboseLoggingRequested(environmentValue: environment["MIRAGE_LOG"]) {
            return true
        }
        return optionBool(
            forKey: latencyDiagnosticsKey,
            defaultValue: false,
            environment: environment,
            defaults: defaults
        )
    }

    private static func optionString(
        forKey key: String,
        environment: [String: String],
        defaults: UserDefaults
    ) -> String? {
        if let rawEnvironmentValue = environment[key] ?? environment[legacyEnvironmentKey(for: key)] {
            return MirageEnvironmentValue.normalizedToken(rawEnvironmentValue)
        }
        if let rawDefaultsValue = defaults.string(forKey: key) {
            return MirageEnvironmentValue.normalizedToken(rawDefaultsValue)
        }
        return nil
    }

    private static func optionBool(
        forKey key: String,
        defaultValue: Bool,
        environment: [String: String],
        defaults: UserDefaults
    ) -> Bool {
        if let rawEnvironmentValue = environment[key] ?? environment[legacyEnvironmentKey(for: key)],
           let parsed = MirageEnvironmentValue.boolean(rawEnvironmentValue) {
            return parsed
        }

        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        if let rawDefaultsValue = defaults.string(forKey: key),
           let parsed = MirageEnvironmentValue.boolean(rawDefaultsValue) {
            return parsed
        }
        return defaults.bool(forKey: key)
    }

    private static func legacyEnvironmentKey(for key: String) -> String {
        var output = ""
        for character in key {
            if character.isUppercase, !output.isEmpty {
                output.append("_")
            }
            output.append(character.uppercased())
        }
        return output
    }
}
