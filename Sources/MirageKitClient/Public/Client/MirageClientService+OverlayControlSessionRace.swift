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

struct OverlayControlSessionRacePolicy {
    static let udpHedgeDelay: Duration = .milliseconds(400)
    static let tcpHedgeDelay: Duration = .milliseconds(1500)
    static let groupBudget: Duration = .seconds(10)
    static let preTransportReadyTimeout: Duration = .seconds(2)
    static let preRemoteHelloIdleTimeout: Duration = .seconds(3)

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
    private var phases: [LoomTransportKind: LoomAuthenticatedSessionBootstrapPhase] = [:]
    private var winner: LoomTransportKind?

    func recordLaunched(_ transportKind: LoomTransportKind) {
        phases[transportKind] = .transportStarting
    }

    func recordProgress(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        transportKind: LoomTransportKind
    ) {
        phases[transportKind] = progress.phase
    }

    func shouldLaunch(_ transportKind: LoomTransportKind) -> Bool {
        guard winner == nil else { return false }
        switch transportKind {
        case .quic:
            return true
        case .udp:
            return phases[.quic]?.hasReachedRemoteHelloOrLater != true
        case .tcp:
            return !phases.values.contains(where: \.hasReachedRemoteHelloOrLater)
        }
    }

    func markWinner(_ transportKind: LoomTransportKind) -> Bool {
        guard winner == nil else { return false }
        winner = transportKind
        return true
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
}
