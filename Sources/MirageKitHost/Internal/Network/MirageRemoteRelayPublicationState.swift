//
//  MirageRemoteRelayPublicationState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//
//  Remote relay candidate publication policy for sticky QUIC host candidates.
//

#if os(macOS)
import Foundation
import MirageKit

@_spi(HostApp)
public enum MirageRemoteRelayPublicationReason: String, Sendable, Equatable {
    case listenerNotReady = "listener_not_ready"
    case stunProbeFailed = "stun_probe_failed"
}

@_spi(HostApp)
public enum MirageRemoteRelayPublicationSource: Sendable, Equatable {
    case fresh
    case sticky(reason: MirageRemoteRelayPublicationReason)
}

@_spi(HostApp)
public enum MirageRemoteRelayPublicationDecision: Sendable, Equatable {
    case `defer`(reason: MirageRemoteRelayPublicationReason)
    case publish(candidates: [LoomRelayCandidate], source: MirageRemoteRelayPublicationSource)
}

struct MirageRemoteRelayPublicationState: Sendable {
    private(set) var lastPublishedCandidates: [LoomRelayCandidate]?

    var hasPublishedCandidates: Bool {
        lastPublishedCandidates != nil
    }

    func decision(
        listenerReady: Bool,
        freshCandidates: [LoomRelayCandidate]
    ) -> MirageRemoteRelayPublicationDecision {
        if !freshCandidates.isEmpty {
            return .publish(candidates: freshCandidates, source: .fresh)
        }

        let reason: MirageRemoteRelayPublicationReason = listenerReady ? .stunProbeFailed : .listenerNotReady
        if let stickyCandidates = lastPublishedCandidates {
            return .publish(candidates: stickyCandidates, source: .sticky(reason: reason))
        }

        return .`defer`(reason: reason)
    }

    mutating func recordPublishedCandidates(_ candidates: [LoomRelayCandidate]) {
        lastPublishedCandidates = candidates
    }

    mutating func reset() {
        lastPublishedCandidates = nil
    }
}
#endif
