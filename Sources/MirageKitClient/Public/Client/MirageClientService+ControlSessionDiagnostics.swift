//
//  MirageClientService+ControlSessionDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Foundation
import Loom
import Network
import MirageKit

public struct MirageClientControlSessionAttemptSummary: Sendable, Equatable {
    public let observedAt: Date
    public let connectionAttemptID: String?
    public let phase: String
    public let hostName: String
    public let transport: String
    public let endpoint: String
    public let candidateKind: String
    public let routeTier: String
    public let endpointSource: String
    public let requiredInterface: String
    public let proximity: String
    public let outcome: String

    public var supportSummaryLine: String {
        let attemptIDText = connectionAttemptID.map { "attempt=\($0) " } ?? ""
        return "\(observedAt.ISO8601Format()) \(attemptIDText)phase=\(phase) host=\(hostName) " +
            "transport=\(transport) candidate=\(candidateKind) endpoint=\(endpoint) " +
            "route=\(routeTier) source=\(endpointSource) interface=\(requiredInterface) " +
            "proximity=\(proximity) outcome=\(outcome)"
    }
}

@MainActor
extension MirageClientService {
    nonisolated private static let controlSessionAttemptSummaryLimit = 24

    func recordControlSessionAttemptPlan(
        _ attempts: [ControlSessionAttempt],
        host: LoomPeer,
        connectionAttemptID: UUID? = nil
    ) {
        guard !attempts.isEmpty else { return }
        for (index, attempt) in attempts.enumerated() {
            let fallback = attempt.transportKind == .tcp ? " compatibilityFallback=tcp" : ""
            recordControlSessionAttempt(
                attempt,
                phase: "planned",
                outcome: "order=\(index + 1)/\(attempts.count) resolved=\(host.resolvedAddresses.count) interfaces=\(host.discoveredInterfaces.map(\.name).joined(separator: ","))\(fallback)",
                connectionAttemptID: connectionAttemptID
            )
        }
    }

    func recordControlSessionAttemptStarted(
        _ attempt: ControlSessionAttempt,
        connectionAttemptID: UUID? = nil
    ) {
        let outcome = attempt.transportKind == .tcp ? "pending compatibilityFallback=tcp" : "pending"
        recordControlSessionAttempt(
            attempt,
            phase: "started",
            outcome: outcome,
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptHedgeLaunched(
        _ attempt: ControlSessionAttempt,
        delayDescription: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "hedge-launched",
            outcome: "delay=\(delayDescription)",
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptSucceeded(
        _ attempt: ControlSessionAttempt,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "succeeded",
            outcome: "connected",
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptFailed(
        _ attempt: ControlSessionAttempt,
        reason: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "failed",
            outcome: reason,
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptSuppressed(
        _ attempt: ControlSessionAttempt,
        reason: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "suppressed",
            outcome: reason,
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptCancelled(
        _ attempt: ControlSessionAttempt,
        reason: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "cancelled",
            outcome: reason,
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionAttemptWinner(
        _ attempt: ControlSessionAttempt,
        reason: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "winner",
            outcome: reason,
            connectionAttemptID: connectionAttemptID
        )
    }

    func recordControlSessionProximityValidation(
        _ attempt: ControlSessionAttempt,
        outcome: String,
        connectionAttemptID: UUID? = nil
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "proximity-validation",
            outcome: outcome,
            connectionAttemptID: connectionAttemptID
        )
    }

    private func recordControlSessionAttempt(
        _ attempt: ControlSessionAttempt,
        phase: String,
        outcome: String,
        connectionAttemptID: UUID? = nil
    ) {
        recentControlSessionAttemptSummaries.append(
            MirageClientControlSessionAttemptSummary(
                observedAt: Date(),
                connectionAttemptID: connectionAttemptID?.uuidString.lowercased(),
                phase: phase,
                hostName: attempt.hostName,
                transport: attempt.transportKind.rawValue,
                endpoint: attempt.endpoint.debugDescription,
                candidateKind: attempt.candidateKind.rawValue,
                routeTier: attempt.routeTier.rawValue,
                endpointSource: attempt.endpointSource,
                requiredInterface: attempt.interfaceDescription,
                proximity: attempt.isPeerToPeerPreferred ? attempt.proximityDescription : "none",
                outcome: outcome
            )
        )
        if recentControlSessionAttemptSummaries.count > Self.controlSessionAttemptSummaryLimit {
            recentControlSessionAttemptSummaries.removeFirst(
                recentControlSessionAttemptSummaries.count - Self.controlSessionAttemptSummaryLimit
            )
        }
    }
}
