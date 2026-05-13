//
//  MirageStreamingSettings.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import MirageKit

/// Settings for app streaming on the host.
public struct MirageStreamingSettings: Codable, Equatable {
    /// Whether closing a client app-stream window should attempt to close the host window.
    public var closeHostWindowOnClientWindowClose: Bool = false

    /// Preferred low-power policy for local host encoder sessions.
    public var encoderLowPowerModePreference: MirageCodecLowPowerModePreference = .auto

    /// Per-app settings keyed by bundle identifier.
    public var perAppSettings: [String: MirageAppStreamingSettings] = [:]

    /// Creates host app-streaming settings.
    public init(
        closeHostWindowOnClientWindowClose: Bool = false,
        encoderLowPowerModePreference: MirageCodecLowPowerModePreference = .auto,
        perAppSettings: [String: MirageAppStreamingSettings] = [:]
    ) {
        self.closeHostWindowOnClientWindowClose = closeHostWindowOnClientWindowClose
        self.encoderLowPowerModePreference = encoderLowPowerModePreference
        self.perAppSettings = perAppSettings
    }

    /// Sets whether a specific app may be streamed.
    /// - Parameters:
    ///   - allowed: Whether the app is allowed to stream.
    ///   - bundleIdentifier: Bundle identifier to update.
    public mutating func setAllowStreaming(_ allowed: Bool, for bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        if var existing = perAppSettings[key] {
            existing.allowStreaming = allowed
            perAppSettings[key] = existing
        } else {
            perAppSettings[key] = MirageAppStreamingSettings(allowStreaming: allowed)
        }
    }

    /// Removes per-app settings so the app uses default streaming policy.
    /// - Parameter bundleIdentifier: Bundle identifier to reset.
    public mutating func removeAppSettings(for bundleIdentifier: String) {
        perAppSettings.removeValue(forKey: bundleIdentifier.lowercased())
    }

    /// Bundle identifiers for apps blocked by per-app streaming settings.
    /// - Note: Returned bundle identifiers are lowercased.
    public var blockedApps: [String] {
        perAppSettings.compactMap { key, settings in
            settings.allowStreaming ? nil : key
        }
    }
}

/// Per-app streaming settings.
public struct MirageAppStreamingSettings: Codable, Equatable {
    /// Whether this app is allowed to be streamed.
    public var allowStreaming: Bool = true

    /// Creates per-app streaming settings.
    public init(allowStreaming: Bool = true) {
        self.allowStreaming = allowStreaming
    }
}

// MARK: - UserDefaults Persistence

public extension MirageStreamingSettings {
    private static let userDefaultsKey = "MirageStreamingSettings"

    /// Loads persisted streaming settings from user defaults.
    /// - Returns: Stored settings or defaults if none exist.
    static func load() -> MirageStreamingSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return MirageStreamingSettings()
        }
        do {
            return try JSONDecoder().decode(MirageStreamingSettings.self, from: data)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host streaming settings: ")
            return MirageStreamingSettings()
        }
    }

    /// Saves streaming settings to user defaults.
    /// - Note: Persisted immediately on the main actor.
    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to encode host streaming settings: ")
        }
    }
}
