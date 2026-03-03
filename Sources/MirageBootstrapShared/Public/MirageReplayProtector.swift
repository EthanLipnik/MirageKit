//
//  MirageReplayProtector.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Timestamp and nonce replay protection for signed request validation.
//

import Foundation

public actor MirageReplayProtector {
    private var nonces: [String: Int64] = [:]
    private var nonceOrder: [String] = []
    private let allowedClockSkewMs: Int64
    private let maxEntries: Int
    private let maxNonceLength: Int

    public init(
        allowedClockSkewMs: Int64 = 60_000,
        maxEntries: Int = 4_096,
        maxNonceLength: Int = MirageControlMessageLimits.maxReplayNonceLength
    ) {
        self.allowedClockSkewMs = allowedClockSkewMs
        self.maxEntries = maxEntries
        self.maxNonceLength = max(16, maxNonceLength)
    }

    public func validate(timestampMs: Int64, nonce: String) -> Bool {
        if nonce.isEmpty || nonce.utf8.count > maxNonceLength { return false }
        let nowMs = Self.currentTimestampMs()
        let delta = nowMs - timestampMs
        if delta > allowedClockSkewMs || delta < -allowedClockSkewMs { return false }
        if nonces[nonce] != nil { return false }

        nonces[nonce] = timestampMs
        nonceOrder.append(nonce)
        enforceBoundedSize()
        prune(nowMs: nowMs)
        return true
    }

    public func reset() {
        nonces.removeAll(keepingCapacity: true)
        nonceOrder.removeAll(keepingCapacity: true)
    }

    private func prune(nowMs: Int64) {
        let cutoff = nowMs - allowedClockSkewMs * 2

        if nonces.isEmpty { return }
        var keptOrder: [String] = []
        keptOrder.reserveCapacity(nonceOrder.count)
        for nonce in nonceOrder {
            guard let timestamp = nonces[nonce], timestamp >= cutoff else {
                nonces.removeValue(forKey: nonce)
                continue
            }
            keptOrder.append(nonce)
        }
        nonceOrder = keptOrder

        enforceBoundedSize()
    }

    private func enforceBoundedSize() {
        while nonceOrder.count > maxEntries {
            let evicted = nonceOrder.removeFirst()
            nonces.removeValue(forKey: evicted)
        }
    }

    private static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
