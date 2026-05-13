//
//  MirageApplication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Host application that owns one or more capturable windows.
public struct MirageApplication: Identifiable, Hashable, Sendable, Codable {
    /// Process identifier of the application.
    public let id: Int32

    /// Bundle identifier, when available.
    public let bundleIdentifier: String?

    /// Display name of the application.
    public let name: String

    /// Application icon payload data for transmission to clients.
    public let iconData: Data?

    /// Creates host application metadata for window and app-stream discovery.
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
