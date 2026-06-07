//
//  MirageHostService+Remote.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Remote QUIC listener keepalive helpers.
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
import Loom

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
}
#endif
