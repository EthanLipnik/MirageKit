//
//  RecoveryCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Episode-based client recovery pacing.
//

import Foundation
import MirageKit

struct RecoveryCoordinator: Equatable {
    enum Decision: Equatable {
        case dispatch(episodeID: UInt64, attempt: Int)
        case wait(deadline: CFAbsoluteTime)
    }

    private(set) var episodeID: UInt64 = 0
    private(set) var activeReason: String?
    private(set) var attemptCount: Int = 0
    private(set) var retryDeadline: CFAbsoluteTime = 0
    private(set) var episodeDeadline: CFAbsoluteTime = 0

    mutating func requestAction(
        now: CFAbsoluteTime,
        reason: String,
        targetFPS: Int,
        forceNewEpisode: Bool = false
    ) -> Decision {
        if forceNewEpisode || activeReason == nil || now >= episodeDeadline {
            beginEpisode(now: now, reason: reason, targetFPS: targetFPS)
        }

        if retryDeadline > 0, now < retryDeadline {
            return .wait(deadline: retryDeadline)
        }

        attemptCount += 1
        retryDeadline = now + Self.defaultRetryDelay(targetFPS: targetFPS, attempt: attemptCount)
        return .dispatch(episodeID: episodeID, attempt: attemptCount)
    }

    mutating func recordHostAck(_ ack: KeyframeRecoveryAckMessage, now: CFAbsoluteTime) {
        guard activeReason != nil else { return }
        let ackDelay = CFAbsoluteTime(ack.deadlineMilliseconds) / 1000.0
        switch ack.state {
        case .accepted:
            retryDeadline = max(retryDeadline, now + ackDelay)
        case .inFlight, .cooldown:
            attemptCount = max(0, attemptCount - 1)
            retryDeadline = max(retryDeadline, now + ackDelay)
        case .noStream:
            recordProgress()
        }
    }

    mutating func recordDispatchNotSent() {
        guard activeReason != nil else { return }
        attemptCount = max(0, attemptCount - 1)
        retryDeadline = 0
    }

    mutating func recordProgress() {
        activeReason = nil
        attemptCount = 0
        retryDeadline = 0
        episodeDeadline = 0
    }

    mutating func reset() {
        episodeID = 0
        recordProgress()
    }

    private mutating func beginEpisode(
        now: CFAbsoluteTime,
        reason: String,
        targetFPS: Int
    ) {
        episodeID &+= 1
        activeReason = reason
        attemptCount = 0
        retryDeadline = 0
        episodeDeadline = now + Self.episodeDuration(targetFPS: targetFPS)
    }

    /// Maximum duration for one keyframe recovery episode at the current stream cadence.
    static func episodeDuration(targetFPS: Int) -> CFAbsoluteTime {
        let frameInterval = 1.0 / Double(max(1, targetFPS))
        return min(4.0, max(1.5, frameInterval * 120.0))
    }

    /// Retry delay for a one-based recovery request attempt.
    static func defaultRetryDelay(targetFPS: Int, attempt: Int) -> CFAbsoluteTime {
        let frameInterval = 1.0 / Double(max(1, targetFPS))
        switch attempt {
        case 0, 1:
            return min(1.0, max(0.25, frameInterval * 18.0))
        case 2:
            return min(1.5, max(0.50, frameInterval * 36.0))
        default:
            return min(2.0, max(1.00, frameInterval * 60.0))
        }
    }
}
