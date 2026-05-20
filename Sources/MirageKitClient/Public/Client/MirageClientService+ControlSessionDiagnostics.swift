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
    public let phase: String
    public let hostName: String
    public let transport: String
    public let endpoint: String
    public let candidateKind: String
    public let endpointSource: String
    public let requiredInterface: String
    public let proximity: String
    public let outcome: String

    public var supportSummaryLine: String {
        "\(observedAt.ISO8601Format()) phase=\(phase) host=\(hostName) " +
            "transport=\(transport) candidate=\(candidateKind) endpoint=\(endpoint) " +
            "source=\(endpointSource) interface=\(requiredInterface) " +
            "proximity=\(proximity) outcome=\(outcome)"
    }
}

@MainActor
extension MirageClientService {
    nonisolated private static let controlSessionAttemptSummaryLimit = 24

    func recordControlSessionAttemptPlan(
        _ attempts: [ControlSessionAttempt],
        host: LoomPeer
    ) {
        guard !attempts.isEmpty else { return }
        for (index, attempt) in attempts.enumerated() {
            recordControlSessionAttempt(
                attempt,
                phase: "planned",
                outcome: "order=\(index + 1)/\(attempts.count) resolved=\(host.resolvedAddresses.count) interfaces=\(host.discoveredInterfaces.map(\.name).joined(separator: ","))"
            )
        }
    }

    func recordControlSessionAttemptStarted(_ attempt: ControlSessionAttempt) {
        recordControlSessionAttempt(attempt, phase: "started", outcome: "pending")
    }

    func recordControlSessionAttemptHedgeLaunched(
        _ attempt: ControlSessionAttempt,
        delayDescription: String
    ) {
        recordControlSessionAttempt(
            attempt,
            phase: "hedge-launched",
            outcome: "delay=\(delayDescription)"
        )
    }

    func recordControlSessionAttemptSucceeded(_ attempt: ControlSessionAttempt) {
        recordControlSessionAttempt(attempt, phase: "succeeded", outcome: "connected")
    }

    func recordControlSessionAttemptFailed(
        _ attempt: ControlSessionAttempt,
        reason: String
    ) {
        recordControlSessionAttempt(attempt, phase: "failed", outcome: reason)
    }

    func recordControlSessionAttemptSuppressed(
        _ attempt: ControlSessionAttempt,
        reason: String
    ) {
        recordControlSessionAttempt(attempt, phase: "suppressed", outcome: reason)
    }

    func recordControlSessionAttemptCancelled(
        _ attempt: ControlSessionAttempt,
        reason: String
    ) {
        recordControlSessionAttempt(attempt, phase: "cancelled", outcome: reason)
    }

    func recordControlSessionAttemptWinner(
        _ attempt: ControlSessionAttempt,
        reason: String
    ) {
        recordControlSessionAttempt(attempt, phase: "winner", outcome: reason)
    }

    func recordControlSessionProximityValidation(
        _ attempt: ControlSessionAttempt,
        outcome: String
    ) {
        recordControlSessionAttempt(attempt, phase: "proximity-validation", outcome: outcome)
    }

    private func recordControlSessionAttempt(
        _ attempt: ControlSessionAttempt,
        phase: String,
        outcome: String
    ) {
        recentControlSessionAttemptSummaries.append(
            MirageClientControlSessionAttemptSummary(
                observedAt: Date(),
                phase: phase,
                hostName: attempt.hostName,
                transport: attempt.transportKind.rawValue,
                endpoint: attempt.endpoint.debugDescription,
                candidateKind: attempt.candidateKind.rawValue,
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
