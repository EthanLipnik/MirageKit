//
//  MirageApplication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Represents an application that owns windows
public struct MirageApplication: Identifiable, Hashable, Sendable, Codable {
    /// Process ID of the application
    public let id: Int32

    /// Bundle identifier (e.g., "com.apple.Safari")
    public let bundleIdentifier: String?

    /// Application name
    public let name: String

    /// Application icon as PNG data (for transmission)
    public let iconData: Data?

    public init(
        id: Int32,
        bundleIdentifier: String?,
        name: String,
        iconData: Data? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.iconData = iconData
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(bundleIdentifier)
    }

    public static func == (lhs: MirageApplication, rhs: MirageApplication) -> Bool {
        lhs.id == rhs.id && lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
