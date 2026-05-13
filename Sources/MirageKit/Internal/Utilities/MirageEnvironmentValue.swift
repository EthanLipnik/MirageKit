//
//  MirageEnvironmentValue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation

/// Normalizes environment and command-output values that use human-readable boolean tokens.
package enum MirageEnvironmentValue {
    /// Returns the first lowercased token after trimming whitespace and splitting on whitespace or semicolons.
    package static func normalizedToken(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return normalized
            .split(whereSeparator: { $0.isWhitespace || $0 == ";" })
            .first
            .map(String.init) ?? normalized
    }

    /// Parses common truthy values: `1`, `true`, `yes`, and `on`.
    package static func isTruthy(_ rawValue: String?) -> Bool {
        switch normalizedToken(rawValue) {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    /// Parses common truthy and falsey values, returning nil for unknown tokens.
    package static func boolean(_ rawValue: String?) -> Bool? {
        switch normalizedToken(rawValue) {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
