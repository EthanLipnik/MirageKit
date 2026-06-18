//
//  MirageHostService+Diagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Loom
import MirageKit
#if os(macOS)
import Security
#endif

#if os(macOS)
@MainActor
public extension MirageHostService {
    var networkDiagnosticsSummaryLines: [String] {
        let advertisingDiagnostics = loomNode.advertisingDiagnostics
        let directTransports = advertisedPeerAdvertisement.directTransports
            .map { transport in
                let path = transport.pathKind?.rawValue ?? "unknown"
                return "\(transport.transportKind.rawValue):\(transport.port):\(path)"
            }
            .joined(separator: ",")
        let directListenerPorts = advertisingDiagnostics.directListenerPorts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
        let lastBonjourFailure = advertisingDiagnostics.lastBonjourFailureDescription
            .flatMap { description in
                if let date = advertisingDiagnostics.lastBonjourFailureAt {
                    return "\(description) at \(date.ISO8601Format())"
                }
                return description
            } ?? "none"

        return [
            "Host Proximity Connect Effective: \(loomNode.configuration.enablePeerToPeer)",
            "Host Bonjour Enabled: \(loomNode.configuration.enableBonjour)",
            "Host Advertising State: \(advertisingDiagnostics.state.rawValue)",
            "Host Bonjour Port: \(advertisingDiagnostics.bonjourPort.map(String.init) ?? "none")",
            "Host Overlay Probe Port: \(loomNode.configuration.overlayProbePort.map(String.init) ?? "none")",
            "Host Requested Direct Ports: tcp=\(loomNode.configuration.controlPort) udp=\(loomNode.configuration.udpPort)",
            "Host Default Direct Ports: tcp=\(MirageKit.directTCPPort) udp=\(MirageKit.directUDPPort)",
            "Host Direct Listener Ports: \(directListenerPorts.isEmpty ? "none" : directListenerPorts)",
            "Host Last Bonjour Failure: \(lastBonjourFailure)",
            "Host Bonjour Recovery Attempt: \(advertisingDiagnostics.bonjourRecoveryAttempt)",
            "Host Advertised Name: \(serviceName)",
            "Host Advertised Bonjour Host Name: \(advertisedPeerAdvertisement.hostName ?? "none")",
            "Host Direct Transports: \(directTransports.isEmpty ? "none" : directTransports)",
            "Host Remote Control Listener Ready: \(remoteControlListenerReady)",
            "Host Remote Control Port: \(remoteControlPort.map(String.init) ?? "none")",
            "Host Proximity Interfaces: \(MirageLocalNetworkMonitor.proximityInterfaceDiagnostics())",
            "Host Low-Latency Streaming Entitlement: \(Self.processEntitlementStatus(key: Self.lowLatencyStreamingEntitlementKey))",
            "Host Wi-Fi Aware Entitlement: \(Self.processEntitlementStatus(key: Self.wifiAwareEntitlementKey))",
        ]
    }

    private static var lowLatencyStreamingEntitlementKey: String {
        "com.apple.developer.low-latency-streaming"
    }

    private static var wifiAwareEntitlementKey: String {
        "com.apple.developer.wifi-aware"
    }

    private static func processEntitlementStatus(key: String) -> String {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return "unavailable"
        }

        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return "missing"
        }
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        return String(describing: value)
    }
}
#endif
