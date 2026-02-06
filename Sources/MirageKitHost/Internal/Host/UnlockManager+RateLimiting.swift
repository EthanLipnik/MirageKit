import MirageKit
#if os(macOS)

//
//  UnlockManager+RateLimiting.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Rate Limiting

    func checkRateLimit(clientID: UUID) -> (isLimited: Bool, remaining: Int?, retryAfter: Int?) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []

        if recentAttempts.count >= maxAttempts {
            if let oldest = recentAttempts.min() {
                let retryAfter = Int(oldest.addingTimeInterval(rateLimitWindow).timeIntervalSince(now)) + 1
                return (true, 0, retryAfter)
            }
            return (true, 0, Int(rateLimitWindow))
        }

        return (false, maxAttempts - recentAttempts.count, nil)
    }

    func recordAttempt(clientID: UUID) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        var attempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        attempts.append(now)
        attemptsByClient[clientID] = attempts
    }

    func getRemainingAttempts(clientID: UUID) -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(-rateLimitWindow)
        let recentAttempts = attemptsByClient[clientID]?.filter { $0 > windowStart } ?? []
        return max(0, maxAttempts - recentAttempts.count)
    }
}

#endif
