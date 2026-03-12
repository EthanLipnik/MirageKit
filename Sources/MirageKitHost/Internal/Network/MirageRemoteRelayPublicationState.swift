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
    case publish(candidate: LoomRelayCandidate, source: MirageRemoteRelayPublicationSource)
}

struct MirageRemoteRelayPublicationState: Sendable {
    private(set) var lastPublishedCandidate: LoomRelayCandidate?

    var hasPublishedCandidate: Bool {
        lastPublishedCandidate != nil
    }

    func decision(
        listenerReady: Bool,
        freshCandidate: LoomRelayCandidate?
    ) -> MirageRemoteRelayPublicationDecision {
        if let freshCandidate {
            return .publish(candidate: freshCandidate, source: .fresh)
        }

        let reason: MirageRemoteRelayPublicationReason = listenerReady ? .stunProbeFailed : .listenerNotReady
        if let stickyCandidate = lastPublishedCandidate {
            return .publish(candidate: stickyCandidate, source: .sticky(reason: reason))
        }

        return .`defer`(reason: reason)
    }

    mutating func recordPublishedCandidate(_ candidate: LoomRelayCandidate) {
        lastPublishedCandidate = candidate
    }

    mutating func reset() {
        lastPublishedCandidate = nil
    }
}
#endif
