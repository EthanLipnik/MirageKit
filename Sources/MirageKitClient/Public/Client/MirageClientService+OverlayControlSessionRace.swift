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
    static let udpHedgeDelay: Duration = .seconds(3)
    static let tcpHedgeDelay: Duration = .seconds(8)
    static let groupBudget: Duration = .seconds(30)
    static let preTransportReadyTimeout: Duration = .seconds(6)
    static let preRemoteHelloIdleTimeout: Duration = .seconds(8)

    static func launchDelay(for transportKind: LoomTransportKind) -> Duration {
        switch transportKind {
        case .quic:
            .milliseconds(0)
        case .udp:
            udpHedgeDelay
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
    private var failedTransports: Set<LoomTransportKind> = []
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

    func recordFailed(_ transportKind: LoomTransportKind) {
        failedTransports.insert(transportKind)
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
            return .launch
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
            return .wait(reason: "waiting for QUIC progress deadline before UDP fallback")
        }
        if failedTransports.contains(.quic) {
            return .launch
        }
        guard let quicState = candidates[.quic] else {
            return .launch
        }
        if quicState.phase.hasReachedRemoteHelloOrLater {
            return .suppress(reason: "overlay UDP suppressed; QUIC reached remote hello or trust")
        }
        if quicState.phase.hasPreRemoteHelloProgress,
           quicState.updatedAt.duration(to: now) < OverlayControlSessionRacePolicy.preRemoteHelloIdleTimeout {
            return .wait(reason: "waiting for progressing QUIC candidate before UDP fallback")
        }
        return .launch
    }

    private func tcpLaunchDecision(
        now: ContinuousClock.Instant,
        earliestLaunch: ContinuousClock.Instant
    ) -> OverlayControlSessionLaunchDecision {
        if now < earliestLaunch {
            return .wait(reason: "waiting for QUIC/UDP progress deadline before TCP fallback")
        }
        if candidates.values.contains(where: { $0.phase.hasReachedRemoteHelloOrLater }) {
            return .suppress(reason: "overlay TCP suppressed; another candidate reached remote hello or trust")
        }
        if failedTransports.contains(.quic), failedTransports.contains(.udp) {
            return .launch
        }
        if candidates.values.contains(where: {
            $0.phase.hasPreRemoteHelloProgress &&
                $0.updatedAt.duration(to: now) < OverlayControlSessionRacePolicy.preRemoteHelloIdleTimeout
        }) {
            return .wait(reason: "waiting for progressing overlay candidate before TCP fallback")
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
