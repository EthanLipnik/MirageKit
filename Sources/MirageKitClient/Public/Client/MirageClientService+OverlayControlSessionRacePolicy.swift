//
//  MirageClientService+OverlayControlSessionRacePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

enum OverlayControlSessionLaunchDecision: Equatable, Sendable {
    case launch
    case wait(reason: String)
    case suppress(reason: String)
}

struct OverlayControlSessionRacePolicy {
    static let udpPrimaryDelay: Duration = .milliseconds(0)
    static let quicHedgeDelay: Duration = .seconds(3)
    static let tcpHedgeDelay: Duration = .seconds(8)
    static let groupBudget: Duration = .seconds(45)
    static let preTransportReadyTimeout: Duration = .seconds(6)
    static let preRemoteHelloIdleTimeout: Duration = .seconds(12)

    static func launchDelay(for transportKind: MirageConnectivity.MirageTransportKind) -> Duration {
        switch transportKind {
        case .quic:
            quicHedgeDelay
        case .udp:
            udpPrimaryDelay
        case .tcp:
            tcpHedgeDelay
        }
    }
}

actor OverlayControlSessionRaceState {
    private struct CandidateState {
        var phase: MirageSessionBootstrapPhase
        var updatedAt: ContinuousClock.Instant
    }

    private var candidates: [MirageConnectivity.MirageTransportKind: CandidateState] = [:]
    private var failedTransports: Set<MirageConnectivity.MirageTransportKind> = []
    private var winner: MirageConnectivity.MirageTransportKind?

    func recordLaunched(
        _ transportKind: MirageConnectivity.MirageTransportKind,
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        candidates[transportKind] = CandidateState(phase: .transportStarting, updatedAt: now)
    }

    func recordProgress(
        _ phase: MirageSessionBootstrapPhase,
        transportKind: MirageConnectivity.MirageTransportKind,
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        candidates[transportKind] = CandidateState(phase: phase, updatedAt: now)
    }

    func recordFailed(_ transportKind: MirageConnectivity.MirageTransportKind) {
        failedTransports.insert(transportKind)
    }

    func shouldLaunch(_ transportKind: MirageConnectivity.MirageTransportKind) -> Bool {
        let now = ContinuousClock.now
        return launchDecision(
            for: transportKind,
            now: now,
            earliestLaunch: now
        ) == .launch
    }

    func launchDecision(
        for transportKind: MirageConnectivity.MirageTransportKind,
        now: ContinuousClock.Instant,
        earliestLaunch: ContinuousClock.Instant
    ) -> OverlayControlSessionLaunchDecision {
        guard winner == nil else {
            return .suppress(reason: "overlay hedge suppressed; another candidate won")
        }
        switch transportKind {
        case .quic:
            if now < earliestLaunch {
                return .wait(reason: "waiting for UDP primary window before QUIC hedge")
            }
            if candidates[.udp]?.phase.hasReachedRemoteHelloOrLater == true {
                return .suppress(reason: "overlay QUIC suppressed; UDP reached remote hello or trust")
            }
            return .launch
        case .udp:
            return udpLaunchDecision(now: now, earliestLaunch: earliestLaunch)
        case .tcp:
            return tcpLaunchDecision(now: now, earliestLaunch: earliestLaunch)
        }
    }

    func markWinner(_ transportKind: MirageConnectivity.MirageTransportKind) -> Bool {
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

private extension MirageSessionBootstrapPhase {
    var hasReachedRemoteHelloOrLater: Bool {
        switch self {
        case .remoteHelloReceived, .trustPendingApproval, .ready:
            true
        case .idle, .transportStarting, .transportReady, .localHelloSent:
            false
        }
    }

    var hasPreRemoteHelloProgress: Bool {
        switch self {
        case .transportReady, .localHelloSent:
            true
        case .idle, .transportStarting, .remoteHelloReceived, .trustPendingApproval, .ready:
            false
        }
    }
}
