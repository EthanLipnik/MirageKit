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
            stunKeepalive?.stop()
            stunKeepalive = nil
            return
        }

        remoteControlListenerReady = remoteControlPort != nil

        if remoteControlListenerReady, let localPort = remoteControlPort, stunKeepalive == nil {
            let keepalive = LoomSTUNKeepalive(localPort: localPort)
            stunKeepalive = keepalive
            let initial = await keepalive.start()
            if initial.reachable {
                MirageLogger.host(
                    "STUN keepalive started on port \(localPort), mapped=\(initial.mappedAddress ?? "?"):\(initial.mappedPort ?? 0)"
                )
            } else {
                MirageLogger.host(
                    "STUN keepalive started on port \(localPort) but initial probe failed: \(initial.failureReason ?? "unknown")"
                )
            }
        }
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

        // Prefer the keepalive's latest mapping when available — avoids running
        // a fresh STUN probe on every heartbeat cycle, and the keepalive ensures
        // the NAT mapping has been recently refreshed.
        if let keepaliveResult = stunKeepalive?.latestResult,
           keepaliveResult.reachable,
           let address = keepaliveResult.mappedAddress,
           let port = keepaliveResult.mappedPort,
           loomNode.configuration.enabledDirectTransports.contains(.quic) {
            let candidate = LoomRelayCandidate(transport: .quic, address: address, port: port)
            MirageLogger.host("Remote candidate from keepalive: \(address):\(port)")
            return [candidate]
        }

        // Fallback: run a one-shot STUN probe via the collector.
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
