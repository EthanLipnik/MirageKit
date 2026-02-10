//
//  MirageReplayProtector.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Timestamp and nonce replay protection for signed request validation.
//

import Foundation

package actor MirageReplayProtector {
    private var nonces: [String: Int64] = [:]
    private let allowedClockSkewMs: Int64
    private let maxEntries: Int

    package init(
        allowedClockSkewMs: Int64 = 60_000,
        maxEntries: Int = 4_096
    ) {
        self.allowedClockSkewMs = allowedClockSkewMs
        self.maxEntries = maxEntries
    }

    package func validate(timestampMs: Int64, nonce: String) -> Bool {
        let nowMs = Self.currentTimestampMs()
        let delta = nowMs - timestampMs
        if delta > allowedClockSkewMs || delta < -allowedClockSkewMs { return false }
        if nonces[nonce] != nil { return false }

        nonces[nonce] = timestampMs
        prune(nowMs: nowMs)
        return true
    }

    package func reset() {
        nonces.removeAll(keepingCapacity: true)
    }

    private func prune(nowMs: Int64) {
        if nonces.count > maxEntries {
            let minimumAllowed = nowMs - allowedClockSkewMs
            nonces = nonces.filter { $0.value >= minimumAllowed }
        }

        let cutoff = nowMs - allowedClockSkewMs * 2
        nonces = nonces.filter { $0.value >= cutoff }
    }

    private static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
