//
//  MirageAppPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import MirageKit

/// Client-side preferences for app organization and sorting.
public struct MirageAppPreferences: Codable, Equatable {
    /// Per-host preferences keyed by host UUID string.
    public var hostPreferences: [String: MirageHostAppPreferences] = [:]

    public init(hostPreferences: [String: MirageHostAppPreferences] = [:]) {
        self.hostPreferences = hostPreferences
    }

    /// Get preferences for a specific host.
    public func preferences(for hostID: UUID) -> MirageHostAppPreferences {
        hostPreferences[hostID.uuidString] ?? MirageHostAppPreferences()
    }

    /// Update preferences for a specific host.
    public mutating func setPreferences(_ prefs: MirageHostAppPreferences, for hostID: UUID) {
        hostPreferences[hostID.uuidString] = prefs
    }

    /// Pin an app for a specific host.
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to pin.
    ///   - hostID: Host identifier that owns the preference.
    public mutating func pinApp(_ bundleIdentifier: String, for hostID: UUID) {
        var prefs = preferences(for: hostID)
        prefs.pinnedApps.insert(bundleIdentifier.lowercased())
        setPreferences(prefs, for: hostID)
    }

    /// Unpin an app for a specific host.
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to unpin.
    ///   - hostID: Host identifier that owns the preference.
    public mutating func unpinApp(_ bundleIdentifier: String, for hostID: UUID) {
        var prefs = preferences(for: hostID)
        prefs.pinnedApps.remove(bundleIdentifier.lowercased())
        setPreferences(prefs, for: hostID)
    }

    /// Check if an app is pinned for a host.
    public func isAppPinned(_ bundleIdentifier: String, for hostID: UUID) -> Bool {
        preferences(for: hostID).pinnedApps.contains(bundleIdentifier.lowercased())
    }

    /// Record that an app was used (updates recently used list).
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier to record.
    ///   - hostID: Host identifier that owns the preference.
    public mutating func recordAppUsage(_ bundleIdentifier: String, for hostID: UUID) {
        var prefs = preferences(for: hostID)
        prefs.recentApps[bundleIdentifier.lowercased()] = Date()

        if prefs.recentApps.count > 50 {
            let sortedByDate = prefs.recentApps.sorted { $0.value > $1.value }
            prefs.recentApps = Dictionary(uniqueKeysWithValues: Array(sortedByDate.prefix(50)))
        }

        setPreferences(prefs, for: hostID)
    }

    /// Get the last used date for an app.
    public func lastUsedDate(_ bundleIdentifier: String, for hostID: UUID) -> Date? {
        preferences(for: hostID).recentApps[bundleIdentifier.lowercased()]
    }
}

/// Preferences for a specific host.
public struct MirageHostAppPreferences: Codable, Equatable {
    /// Bundle identifiers of pinned apps (lowercased).
    public var pinnedApps: Set<String> = []

    /// Recently used apps: bundle identifier -> last used date.
    public var recentApps: [String: Date] = [:]

    public init(pinnedApps: Set<String> = [], recentApps: [String: Date] = [:]) {
        self.pinnedApps = pinnedApps
        self.recentApps = recentApps
    }
}

// MARK: - UserDefaults Persistence

public extension MirageAppPreferences {
    private static let userDefaultsKey = "MirageAppPreferences"

    /// Load preferences from UserDefaults.
    /// - Returns: Stored preferences or defaults if none exist.
    static func load() -> MirageAppPreferences {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let prefs = try? JSONDecoder().decode(MirageAppPreferences.self, from: data) else {
            return MirageAppPreferences()
        }
        return prefs
    }

    /// Save preferences to UserDefaults.
    /// - Note: Persisted immediately on the main actor.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

// MARK: - App Sorting

public extension MirageAppPreferences {
    /// Sort apps for display: pinned first (alphabetically), then recently used, then alphabetical.
    /// - Parameters:
    ///   - apps: Apps to sort.
    ///   - hostID: Host identifier that owns the preference.
    func sortedApps(_ apps: [MirageInstalledApp], for hostID: UUID) -> [MirageInstalledApp] {
        let prefs = preferences(for: hostID)

        return apps.sorted { app1, app2 in
            let id1 = app1.bundleIdentifier.lowercased()
            let id2 = app2.bundleIdentifier.lowercased()

            let isPinned1 = prefs.pinnedApps.contains(id1)
            let isPinned2 = prefs.pinnedApps.contains(id2)

            if isPinned1 != isPinned2 {
                return isPinned1
            }

            let recent1 = prefs.recentApps[id1]
            let recent2 = prefs.recentApps[id2]

            if let r1 = recent1, let r2 = recent2 {
                if r1 != r2 {
                    return r1 > r2
                }
            }

            if (recent1 != nil) != (recent2 != nil) {
                return recent1 != nil
            }

            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }
}
