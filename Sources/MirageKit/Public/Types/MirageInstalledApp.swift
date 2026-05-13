//
//  MirageInstalledApp.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation

/// Installed host application that can be selected for app streaming.
public struct MirageInstalledApp: Identifiable, Hashable, Sendable, Codable {
    /// Bundle identifier used as the unique app identity.
    public let bundleIdentifier: String

    /// Display name of the application.
    public let name: String

    /// Path to the application bundle.
    public let path: String

    /// Application icon payload data for transmission to clients.
    public let iconData: Data?

    /// Version string from `CFBundleShortVersionString`.
    public let version: String?

    /// Whether the app is currently running on the host.
    public var isRunning: Bool

    /// Whether the app is currently being streamed to any client.
    public var isBeingStreamed: Bool

    /// Stable identity for SwiftUI and collection diffing.
    public var id: String { bundleIdentifier }

    /// Creates installed application metadata for app-stream selection.
    public init(
        bundleIdentifier: String,
        name: String,
        path: String,
        iconData: Data? = nil,
        version: String? = nil,
        isRunning: Bool = false,
        isBeingStreamed: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.iconData = iconData
        self.version = version
        self.isRunning = isRunning
        self.isBeingStreamed = isBeingStreamed
    }

    /// Hashes installed apps by bundle identifier so icon/status refreshes update the same logical app.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    /// Compares installed apps by bundle identifier, ignoring transient icon and running state.
    public static func == (lhs: MirageInstalledApp, rhs: MirageInstalledApp) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
