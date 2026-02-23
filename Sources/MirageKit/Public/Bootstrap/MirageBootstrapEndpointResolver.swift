//
//  MirageBootstrapEndpointResolver.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Deterministic bootstrap endpoint ordering + dedupe.
//

import Foundation

/// Deterministically orders and deduplicates bootstrap endpoints.
///
/// Use this before trying wake/unlock bootstrap connection attempts so retries follow a stable,
/// user-first order across launches.
public enum MirageBootstrapEndpointResolver {
    /// Resolve endpoint candidates in deterministic priority order.
    ///
    /// Priority:
    /// 1. `user`
    /// 2. `auto`
    /// 3. `lastSeen`
    ///
    /// Duplicate host:port pairs are removed case-insensitively.
    /// Returns an ordered endpoint list with duplicate host/port pairs removed.
    ///
    /// - Parameter endpoints: Raw endpoint candidates from metadata, user settings, and cache.
    /// - Returns: Endpoints sorted by source priority and lexical host/port tiebreakers.
    ///
    /// - SeeAlso: ``MirageBootstrapEndpoint``, ``MirageBootstrapEndpointSource``
    public static func resolve(
        _ endpoints: [MirageBootstrapEndpoint]
    ) -> [MirageBootstrapEndpoint] {
        let priority: [MirageBootstrapEndpointSource: Int] = [
            .user: 0,
            .auto: 1,
            .lastSeen: 2,
        ]

        let sorted = endpoints.sorted { lhs, rhs in
            let leftPriority = priority[lhs.source] ?? Int.max
            let rightPriority = priority[rhs.source] ?? Int.max
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftHost = lhs.host.lowercased()
            let rightHost = rhs.host.lowercased()
            if leftHost != rightHost { return leftHost < rightHost }
            return lhs.port < rhs.port
        }

        var seen = Set<String>()
        return sorted.filter { endpoint in
            let key = "\(endpoint.host.lowercased()):\(endpoint.port)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}
