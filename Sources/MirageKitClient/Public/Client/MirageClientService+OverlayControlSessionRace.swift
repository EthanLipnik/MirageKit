//
//  MirageClientService+OverlayControlSessionRace.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Foundation
import Loom

struct OverlayControlSessionRaceResult: Sendable {
    let attempt: MirageClientService.ControlSessionAttempt
    let session: LoomAuthenticatedSession
}

enum OverlayControlSessionCandidateOutcome: Sendable {
    case connected(index: Int, attempt: MirageClientService.ControlSessionAttempt, session: LoomAuthenticatedSession)
    case failed(
        index: Int,
        attempt: MirageClientService.ControlSessionAttempt,
        classification: MirageClientService.ControlSessionFailureClassification,
        reason: String
    )
    case suppressed(index: Int, attempt: MirageClientService.ControlSessionAttempt, reason: String)
    case cancelled(index: Int, attempt: MirageClientService.ControlSessionAttempt)
}

enum OverlayControlSessionLaunchDecision: Equatable, Sendable {
    case launch
    case wait(reason: String)
    case suppress(reason: String)
}

struct OverlayControlSessionRacePolicy {
    static let udpPrimaryDelay: Duration = .milliseconds(0)
    static let tcpHedgeDelay: Duration = .seconds(3)
    static let groupBudget: Duration = .seconds(45)
    static let preTransportReadyTimeout: Duration = .seconds(6)
    static let preRemoteHelloIdleTimeout: Duration = .seconds(12)

    static func launchDelay(for transportKind: LoomTransportKind) -> Duration {
        switch transportKind {
        case .quic:
            tcpHedgeDelay
        case .udp:
            udpPrimaryDelay
        case .tcp:
            tcpHedgeDelay
        }
    }
}

actor OverlayControlSessionRaceState {
    private struct CandidateState {
        var phase: LoomAuthenticatedSessionBootstrapPhase
        var updatedAt: ContinuousClock.Instant
    }

    private var candidates: [LoomTransportKind: CandidateState] = [:]
    private var winner: LoomTransportKind?

    func recordLaunched(
        _ transportKind: LoomTransportKind,
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        candidates[transportKind] = CandidateState(phase: .transportStarting, updatedAt: now)
    }

    func recordProgress(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        transportKind: LoomTransportKind,
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        candidates[transportKind] = CandidateState(phase: progress.phase, updatedAt: now)
    }

    func shouldLaunch(_ transportKind: LoomTransportKind) -> Bool {
        let now = ContinuousClock.now
        return launchDecision(
            for: transportKind,
            now: now,
            earliestLaunch: now
        ) == .launch
    }

    func launchDecision(
        for transportKind: LoomTransportKind,
        now: ContinuousClock.Instant,
        earliestLaunch: ContinuousClock.Instant
    ) -> OverlayControlSessionLaunchDecision {
        guard winner == nil else {
            return .suppress(reason: "overlay hedge suppressed; another candidate won")
        }
        switch transportKind {
        case .quic:
            return .suppress(reason: "overlay QUIC suppressed; transport disabled")
        case .udp:
            return udpLaunchDecision(now: now, earliestLaunch: earliestLaunch)
        case .tcp:
            return tcpLaunchDecision(now: now, earliestLaunch: earliestLaunch)
        }
    }

    func markWinner(_ transportKind: LoomTransportKind) -> Bool {
        guard winner == nil else { return false }
        winner = transportKind
        return true
    }

    private func udpLaunchDecision(
        now: ContinuousClock.Instant,
        earliestLaunch: ContinuousClock.Instant
    ) -> OverlayControlSessionLaunchDecision {
        if now < earliestLaunch {
            return .wait(reason: "waiting for UDP primary window")
        }
        return .launch
    }

    private func tcpLaunchDecision(
        now: ContinuousClock.Instant,
        earliestLaunch: ContinuousClock.Instant
    ) -> OverlayControlSessionLaunchDecision {
        if now < earliestLaunch {
            return .wait(reason: "waiting for UDP primary window before TCP fallback")
        }
        if candidates.values.contains(where: { $0.phase.hasReachedRemoteHelloOrLater }) {
            return .suppress(reason: "overlay TCP suppressed; another candidate reached remote hello or trust")
        }
        return .launch
    }
}

extension LoomAuthenticatedSessionBootstrapPhase {
    fileprivate var hasReachedRemoteHelloOrLater: Bool {
        switch self {
        case .remoteHelloReceived, .trustPendingApproval, .ready:
            true
        case .idle, .transportStarting, .transportReady, .localHelloSent:
            false
        }
    }

    fileprivate var hasPreRemoteHelloProgress: Bool {
        switch self {
        case .transportReady, .localHelloSent:
            true
        case .idle, .transportStarting, .remoteHelloReceived, .trustPendingApproval, .ready:
            false
        }
    }
}
