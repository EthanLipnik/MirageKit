//
//  MirageTrustProvider+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageIdentity

#if os(macOS)
package extension MirageTrustEvaluationSnapshot {
    init(loomTrustEvaluation: LoomTrustEvaluation) {
        let decision: MirageTrustDecision
        let unavailabilityReason: String?
        switch loomTrustEvaluation.decision {
        case .trusted:
            decision = .trusted
            unavailabilityReason = nil
        case .requiresApproval:
            decision = .requiresApproval
            unavailabilityReason = nil
        case .denied:
            decision = .denied
            unavailabilityReason = nil
        case let .unavailable(reason):
            decision = .unavailable
            unavailabilityReason = reason
        }

        self.init(
            decision: decision,
            shouldShowAutoTrustNotice: loomTrustEvaluation.shouldShowAutoTrustNotice,
            unavailabilityReason: unavailabilityReason
        )
    }
}

@MainActor
package final class MirageTrustProviderLoomAdapter: LoomTrustProvider {
    private let provider: any MirageTrustProvider

    package init(provider: any MirageTrustProvider) {
        self.provider = provider
    }

    package func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        let decision = await provider.evaluateTrust(
            for: MirageAuthenticatedPeerIdentity(loomPeerIdentity: peer)
        )
        return Self.loomDecision(for: decision, unavailabilityReason: nil)
    }

    package func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        let evaluation = await provider.evaluateTrustOutcome(
            for: MirageAuthenticatedPeerIdentity(loomPeerIdentity: peer)
        )
        return LoomTrustEvaluation(
            decision: Self.loomDecision(
                for: evaluation.decision,
                unavailabilityReason: evaluation.unavailabilityReason
            ),
            shouldShowAutoTrustNotice: evaluation.shouldShowAutoTrustNotice
        )
    }

    package func grantTrust(to peer: LoomPeerIdentity) async throws {
        try await provider.grantTrust(
            to: MirageAuthenticatedPeerIdentity(loomPeerIdentity: peer)
        )
    }

    package func revokeTrust(for deviceID: UUID) async throws {
        try await provider.revokeTrust(
            for: MiragePeerID(deviceID: deviceID)
        )
    }

    private static func loomDecision(
        for decision: MirageTrustDecision,
        unavailabilityReason: String?
    ) -> LoomTrustDecision {
        switch decision {
        case .trusted:
            return .trusted
        case .requiresApproval:
            return .requiresApproval
        case .denied:
            return .denied
        case .unavailable:
            return .unavailable(unavailabilityReason ?? "Trust provider unavailable")
        }
    }
}
#endif
