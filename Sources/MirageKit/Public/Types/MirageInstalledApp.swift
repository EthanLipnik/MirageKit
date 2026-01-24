//
//  MirageInstalledApp.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation

/// Represents an installed application that can be selected for streaming
public struct MirageInstalledApp: Identifiable, Hashable, Sendable, Codable {
    /// Bundle identifier (e.g., "com.apple.Safari") - used as the unique identifier
    public let bundleIdentifier: String

    /// Display name of the application
    public let name: String

    /// Path to the application bundle
    public let path: String

    /// Application icon as PNG data (for transmission to clients)
    public let iconData: Data?

    /// Version string (CFBundleShortVersionString)
    public let version: String?

    /// Whether the app is currently running on the host
    public var isRunning: Bool

    /// Whether the app is currently being streamed (to any client)
    public var isBeingStreamed: Bool

    public var id: String { bundleIdentifier }

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

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    public static func == (lhs: MirageInstalledApp, rhs: MirageInstalledApp) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
