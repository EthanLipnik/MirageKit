//
//  MirageDiagnosticsContext.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Mirage-owned scalar value used in point-in-time diagnostics context snapshots.
public enum MirageDiagnosticsValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([MirageDiagnosticsValue])
    case dictionary([String: MirageDiagnosticsValue])
    case null

    /// Foundation representation suitable for JSON-like diagnostics sinks.
    public var foundationValue: Any {
        switch self {
        case let .string(value):
            value
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .array(values):
            values.map(\.foundationValue)
        case let .dictionary(values):
            values.mapValues(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

/// Point-in-time Mirage diagnostics context keyed by stable low-cardinality names.
public typealias MirageDiagnosticsContext = [String: MirageDiagnosticsValue]
