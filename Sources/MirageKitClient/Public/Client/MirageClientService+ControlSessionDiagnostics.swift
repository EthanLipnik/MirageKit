//
//  MirageClientService+ControlSessionDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
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
import Network

@MainActor
extension MirageClientService {
    nonisolated private static let controlSessionAttemptSummaryLimit = 24

    func recordControlSessionAttemptPlan(
        _ attempts: [ControlSessionAttempt],
        resolvedAddressCount: Int,
        discoveredInterfaceNames: [String]
    ) {
        guard !attempts.isEmpty else { return }
        for (index, attempt) in attempts.enumerated() {
            recordControlSessionAttempt(
                attempt,
                phase: "planned",
                outcome: "order=\(index + 1)/\(attempts.count) resolved=\(resolvedAddressCount) interfaces=\(discoveredInterfaceNames.joined(separator: ","))"
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
            MirageDiagnostics.MirageClientControlSessionAttemptSummary(
                observedAt: Date(),
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
