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
            remoteRelayPublicationState.reset()
            stunKeepalive?.stop()
            stunKeepalive = nil
            natPortMapping?.stop()
            natPortMapping = nil
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

            // Request a NAT-PMP / PCP port mapping for a stable external port.
            // This is preferred over STUN for aggressive or symmetric NATs.
            if natPortMapping == nil {
                let mapping = LoomNATPortMapping()
                natPortMapping = mapping
                if let result = await mapping.start(localPort: localPort) {
                    MirageLogger.host(
                        "NAT-PMP mapping active: external=\(result.externalAddress):\(result.externalPort) → local=\(localPort) ttl=\(result.ttlSeconds)s"
                    )
                } else {
                    MirageLogger.host(
                        "NAT-PMP not supported by router — using STUN candidates only"
                    )
                }
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
    public func recordRemoteRelayAdvertiseSuccess(candidates: [LoomRemoteCandidate]) {
        remoteRelayPublicationState.recordPublishedCandidates(candidates)
    }

    private func collectFreshRemoteCandidates() async -> [LoomRemoteCandidate] {
        guard remoteTransportEnabled,
              remoteControlListenerReady,
              let localPort = remoteControlPort else {
            MirageLogger.host("Remote candidate collection skipped (transport disabled or listener port unavailable)")
            return []
        }

        guard loomNode.configuration.enabledDirectTransports.contains(.quic) else {
            return []
        }

        var candidates: [LoomRemoteCandidate] = []

        // Prefer NAT-PMP / PCP mapping — provides a stable external port that
        // doesn't change between keepalive probes, reliable through symmetric NATs.
        if let mapping = natPortMapping?.latestMapping {
            let candidate = LoomRemoteCandidate(
                transport: .quic,
                address: mapping.externalAddress,
                port: mapping.externalPort
            )
            candidates.append(candidate)
            MirageLogger.host("Remote candidate from NAT-PMP: \(mapping.externalAddress):\(mapping.externalPort)")
        }

        // Also include the STUN keepalive candidate for redundancy — some
        // routers don't support NAT-PMP but the STUN mapping may still work.
        if let keepaliveResult = stunKeepalive?.latestResult,
           keepaliveResult.reachable,
           let address = keepaliveResult.mappedAddress,
           let port = keepaliveResult.mappedPort {
            let stunCandidate = LoomRemoteCandidate(transport: .quic, address: address, port: port)
            // Only add if it differs from the NAT-PMP candidate.
            if !candidates.contains(stunCandidate) {
                candidates.append(stunCandidate)
                MirageLogger.host("Remote candidate from STUN keepalive: \(address):\(port)")
            } else {
                MirageLogger.host("Remote candidate from keepalive: \(address):\(port) (same as NAT-PMP)")
            }
        }

        if !candidates.isEmpty {
            return candidates
        }

        // Fallback: run a one-shot STUN probe via the collector.
        let collectedCandidates = await LoomDirectCandidateCollector.collect(
            configuration: loomNode.configuration,
            listeningPorts: [.quic: localPort]
        )
        MirageLogger.host("Remote candidate collection completed: \(collectedCandidates.count) candidate(s)")
        for candidate in collectedCandidates {
            MirageLogger.host(
                "  candidate transport=\(candidate.transport) address=\(candidate.address) port=\(candidate.port)"
            )
        }
        return collectedCandidates
    }
}
#endif
