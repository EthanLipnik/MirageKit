//
//  MirageLabTypes.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Category used to group Labs in registries and reports.
@_spi(Labs)
public enum MirageLabCategory: String, Codable, CaseIterable, Sendable {
    case capture
    case encode
    case decode
    case presentation
    case transport
    case input
    case endToEnd
    case diagnostics
}

/// Runtime availability for a Lab on the current device or process.
@_spi(Labs)
public struct MirageLabAvailability: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case available
        case unavailable
        case experimental
    }

    public let status: Status
    public let reason: String?

    public init(status: Status, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }

    public static let available = MirageLabAvailability(status: .available)

    public static func unavailable(_ reason: String) -> MirageLabAvailability {
        MirageLabAvailability(status: .unavailable, reason: reason)
    }

    public static func experimental(_ reason: String? = nil) -> MirageLabAvailability {
        MirageLabAvailability(status: .experimental, reason: reason)
    }

    public var canRun: Bool {
        status != .unavailable
    }
}

/// Typed value used by Lab configurations.
@_spi(Labs)
public enum MirageLabConfigurationValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case stringArray([String])

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case string
        case bool
        case int
        case double
        case stringArray
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .bool(value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .int(value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .stringArray(value):
            try container.encode(Kind.stringArray, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Stable configuration passed into a Lab runner.
@_spi(Labs)
public struct MirageLabConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public var parameters: [String: MirageLabConfigurationValue]

    public init(
        version: Int = 1,
        parameters: [String: MirageLabConfigurationValue] = [:]
    ) {
        self.version = version
        self.parameters = parameters
    }

    public static let empty = MirageLabConfiguration()
}

/// Registry metadata for a repeatable measurement or diagnostic Lab.
@_spi(Labs)
public struct MirageLabDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let category: MirageLabCategory
    public let availability: MirageLabAvailability
    public let defaultConfiguration: MirageLabConfiguration

    public init(
        id: String,
        title: String,
        summary: String,
        category: MirageLabCategory,
        availability: MirageLabAvailability = .available,
        defaultConfiguration: MirageLabConfiguration = .empty
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.availability = availability
        self.defaultConfiguration = defaultConfiguration
    }
}

/// Progress emitted by a Lab runner.
@_spi(Labs)
public struct MirageLabProgress: Codable, Equatable, Sendable {
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let message: String

    public init(
        completedUnitCount: Int,
        totalUnitCount: Int,
        message: String
    ) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.message = message
    }
}

@_spi(Labs)
public typealias MirageLabProgressHandler = @Sendable (MirageLabProgress) async -> Void
