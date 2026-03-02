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

    /// Per-app settings keyed by bundle identifier.
    public var perAppSettings: [String: MirageAppStreamingSettings] = [:]

    public init(
        closeHostWindowOnClientWindowClose: Bool = false,
        perAppSettings: [String: MirageAppStreamingSettings] = [:]
    ) {
        self.closeHostWindowOnClientWindowClose = closeHostWindowOnClientWindowClose
        self.perAppSettings = perAppSettings
    }

    private enum CodingKeys: String, CodingKey {
        case closeHostWindowOnClientWindowClose
        case perAppSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        closeHostWindowOnClientWindowClose = try container.decodeIfPresent(
            Bool.self,
            forKey: .closeHostWindowOnClientWindowClose
        ) ?? false
        perAppSettings = try container.decodeIfPresent(
            [String: MirageAppStreamingSettings].self,
            forKey: .perAppSettings
        ) ?? [:]
    }

    /// Get settings for a specific app (with fallback to global).
    public func settings(for bundleIdentifier: String) -> MirageAppStreamingSettings {
        perAppSettings[bundleIdentifier.lowercased()] ?? MirageAppStreamingSettings()
    }

    /// Check if an app should be allowed for streaming.
    public func isAppAllowed(_ bundleIdentifier: String) -> Bool {
        let appSettings = settings(for: bundleIdentifier)
        return appSettings.allowStreaming
    }

    /// Set allow/block status for an app.
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

    /// Remove per-app settings (revert to defaults).
    /// - Parameter bundleIdentifier: Bundle identifier to reset.
    public mutating func removeAppSettings(for bundleIdentifier: String) {
        perAppSettings.removeValue(forKey: bundleIdentifier.lowercased())
    }

    /// Get list of blocked apps.
    /// - Note: Returned bundle identifiers are lowercased.
    public var blockedApps: [String] {
        perAppSettings.compactMap { key, settings in
            settings.allowStreaming ? nil : key
        }
    }

}

/// Per-app streaming settings.
public struct MirageAppStreamingSettings: Codable, Equatable {
    /// Whether this app is allowed to be streamed (default true).
    public var allowStreaming: Bool = true

    public init(allowStreaming: Bool = true) {
        self.allowStreaming = allowStreaming
    }
}

// MARK: - UserDefaults Persistence

public extension MirageStreamingSettings {
    private static let userDefaultsKey = "MirageStreamingSettings"

    /// Load settings from UserDefaults.
    /// - Returns: Stored settings or defaults if none exist.
    static func load() -> MirageStreamingSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(MirageStreamingSettings.self, from: data) else {
            return MirageStreamingSettings()
        }
        return settings
    }

    /// Save settings to UserDefaults.
    /// - Note: Persisted immediately on the main actor.
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.userDefaultsKey) }
    }
}
