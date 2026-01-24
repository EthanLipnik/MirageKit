//
//  MirageStreamingSettings.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation

/// Settings for app streaming on the host.
public struct MirageStreamingSettings: Codable, Equatable {
    /// Global setting: quit apps when their last window closes during streaming.
    public var globalQuitOnLastWindowClose: Bool = false

    /// Per-app settings keyed by bundle identifier.
    public var perAppSettings: [String: MirageAppStreamingSettings] = [:]

    public init(globalQuitOnLastWindowClose: Bool = false, perAppSettings: [String: MirageAppStreamingSettings] = [:]) {
        self.globalQuitOnLastWindowClose = globalQuitOnLastWindowClose
        self.perAppSettings = perAppSettings
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

    /// Check if an app should quit when its last window closes.
    public func shouldQuitOnLastWindowClose(_ bundleIdentifier: String) -> Bool {
        let appSettings = settings(for: bundleIdentifier)
        return appSettings.quitOnLastWindowClose ?? globalQuitOnLastWindowClose
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

    /// Set quit-on-close behavior for an app.
    /// - Parameters:
    ///   - quit: Optional override for quit-on-close behavior.
    ///   - bundleIdentifier: Bundle identifier to update.
    public mutating func setQuitOnLastWindowClose(_ quit: Bool?, for bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        if var existing = perAppSettings[key] {
            existing.quitOnLastWindowClose = quit
            perAppSettings[key] = existing
        } else {
            perAppSettings[key] = MirageAppStreamingSettings(quitOnLastWindowClose: quit)
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

    /// Get list of apps with custom quit-on-close settings.
    public var appsWithCustomQuitBehavior: [(bundleIdentifier: String, quitOnClose: Bool)] {
        perAppSettings.compactMap { key, settings in
            guard let quit = settings.quitOnLastWindowClose else { return nil }
            return (key, quit)
        }
    }
}

/// Per-app streaming settings.
public struct MirageAppStreamingSettings: Codable, Equatable {
    /// Whether this app is allowed to be streamed (default true).
    public var allowStreaming: Bool = true

    /// Whether to quit this app when its last window closes.
    /// nil = use global setting.
    public var quitOnLastWindowClose: Bool? = nil

    public init(allowStreaming: Bool = true, quitOnLastWindowClose: Bool? = nil) {
        self.allowStreaming = allowStreaming
        self.quitOnLastWindowClose = quitOnLastWindowClose
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
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
