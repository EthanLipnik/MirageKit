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

    public func resolveRemoteControlCandidate(
        stunHost: String = "stun.cloudflare.com",
        stunPort: UInt16 = 3478,
        timeout: Duration = .seconds(2)
    ) async -> LoomRelayCandidate? {
        await resolveFreshRemoteControlCandidate(
            stunHost: stunHost,
            stunPort: stunPort,
            timeout: timeout
        )
    }

    @_spi(HostApp)
    public func resolveRemoteRelayPublicationDecision(
        stunHost: String = "stun.cloudflare.com",
        stunPort: UInt16 = 3478,
        timeout: Duration = .seconds(2)
    ) async -> MirageRemoteRelayPublicationDecision {
        let freshCandidate = await resolveFreshRemoteControlCandidate(
            stunHost: stunHost,
            stunPort: stunPort,
            timeout: timeout
        )
        return remoteRelayPublicationState.decision(
            listenerReady: remoteControlListenerReady,
            freshCandidate: freshCandidate
        )
    }

    @_spi(HostApp)
    public func recordRemoteRelayAdvertiseSuccess(candidate: LoomRelayCandidate) {
        remoteRelayPublicationState.recordPublishedCandidate(candidate)
    }

    private func resolveFreshRemoteControlCandidate(
        stunHost: String,
        stunPort: UInt16,
        timeout: Duration
    ) async -> LoomRelayCandidate? {
        guard remoteTransportEnabled,
              remoteControlListenerReady,
              let localPort = remoteControlPort else {
            MirageLogger.host("Remote candidate skipped (transport disabled or listener port unavailable)")
            return nil
        }

        let result = await LoomSTUNProbe.run(
            host: stunHost,
            port: stunPort,
            localPort: localPort,
            timeout: timeout
        )
        MirageLogger.host(
            "Remote STUN probe result reachable=\(result.reachable) mapped=\(result.mappedAddress ?? "none"):\(result.mappedPort ?? 0)"
        )
        guard result.reachable,
              let mappedAddress = result.mappedAddress,
              let mappedPort = result.mappedPort else {
            if let failureReason = result.failureReason {
                MirageLogger.host("Remote STUN probe failed: \(failureReason)")
            }
            return nil
        }

        return LoomRelayCandidate(
            transport: .quic,
            address: mappedAddress,
            port: mappedPort
        )
    }
}
#endif
