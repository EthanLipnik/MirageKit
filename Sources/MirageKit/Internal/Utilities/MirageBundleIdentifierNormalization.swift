//
//  MirageBundleIdentifierNormalization.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

import Foundation

/// Trims, lowercases, and ordered-deduplicates bundle identifiers.
package func mirageNormalizedBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    normalized.reserveCapacity(bundleIdentifiers.count)

    for bundleIdentifier in bundleIdentifiers {
        let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, seen.insert(value).inserted else { continue }
        normalized.append(value)
    }

    return normalized
}
