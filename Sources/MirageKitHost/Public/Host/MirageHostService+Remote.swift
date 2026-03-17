//
//  MirageHostService+Remote.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Remote QUIC publication helpers backed by Loom direct listeners.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func updateRemoteControlListenerState() async {
        let isHosting: Bool
        if case .advertising = state {
            isHosting = true
        } else {
            isHosting = false
        }

        guard remoteTransportEnabled, isHosting else {
            remoteControlListenerReady = false
            setRemoteControlPort(nil)
            remoteRelayPublicationState.reset()
            return
        }

        remoteControlListenerReady = remoteControlPort != nil
    }

    @_spi(HostApp)
    public func resolveRemoteRelayPublicationDecision() async -> MirageRemoteRelayPublicationDecision {
        let freshCandidates = await collectFreshRemoteCandidates()
        return remoteRelayPublicationState.decision(
            listenerReady: remoteControlListenerReady,
            freshCandidates: freshCandidates
        )
    }

    @_spi(HostApp)
    public func recordRemoteRelayAdvertiseSuccess(candidates: [LoomRelayCandidate]) {
        remoteRelayPublicationState.recordPublishedCandidates(candidates)
    }

    private func collectFreshRemoteCandidates() async -> [LoomRelayCandidate] {
        guard remoteTransportEnabled,
              remoteControlListenerReady,
              let localPort = remoteControlPort else {
            MirageLogger.host("Remote candidate collection skipped (transport disabled or listener port unavailable)")
            return []
        }

        let candidates = await LoomDirectCandidateCollector.collect(
            configuration: loomNode.configuration,
            listeningPorts: [.quic: localPort]
        )
        MirageLogger.host("Remote candidate collection completed: \(candidates.count) candidate(s)")
        for candidate in candidates {
            MirageLogger.host(
                "  candidate transport=\(candidate.transport) address=\(candidate.address) port=\(candidate.port)"
            )
        }
        return candidates
    }
}
#endif
