//
//  MirageClientService+ControlSessionEndpoint.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import Network
import MirageKit

@MainActor
extension MirageClientService {
    func controlSessionAttempts(
        for host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics? = nil
    ) -> [ControlSessionAttempt] {
        let resolvedLocalNetwork = localNetwork ?? ControlSessionNetworkDiagnostics(
            snapshot: localNetworkMonitor.snapshot
        )
        var attempts: [ControlSessionAttempt] = []
        let transportOrder: [LoomTransportKind] = [.udp, .quic, .tcp]

        attempts.append(
            contentsOf: peerToPeerPreferredControlSessionAttempts(
                for: host,
                transportOrder: transportOrder
            )
        )

        for transportKind in transportOrder {
            guard let endpoint = controlSessionEndpoint(
                for: host,
                transportKind: transportKind,
                localNetwork: resolvedLocalNetwork
            ) else {
                continue
            }

            let candidateKind = controlSessionCandidateKind(for: endpoint, host: host)
            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: endpoint,
                    transportKind: transportKind,
                    candidateKind: candidateKind,
                    requiredInterfaceType: candidateKind == .overlay ? nil : preferredNetworkType.requiredInterfaceType
                )
            )
        }

        if attempts.isEmpty {
            let candidateKind = controlSessionCandidateKind(for: host.endpoint, host: host)
            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: host.endpoint,
                    transportKind: .tcp,
                    candidateKind: candidateKind,
                    requiredInterfaceType: candidateKind == .overlay ? nil : preferredNetworkType.requiredInterfaceType
                )
            )
        }

        return attempts
    }

    func peerToPeerPreferredControlSessionAttempts(
        for host: LoomPeer,
        transportOrder: [LoomTransportKind]
    ) -> [ControlSessionAttempt] {
        guard networkConfig.enablePeerToPeer else {
            return []
        }
        guard isBonjourDiscoveredHost(host) else {
            return []
        }
        guard let selectedHost = peerToPeerPreferredBonjourControlHost(for: host) else {
            MirageLogger.client(
                "Skipping AWDL-preferred control attempts for \(host.name): no Bonjour hostname"
            )
            return []
        }

        let discoveredInterface = host.discoveredInterfaces.first(where: \.isPeerToPeer)
        guard discoveredInterface != nil || !host.resolvedAddresses.isEmpty else {
            return []
        }

        let requiredInterface: NWInterface?
        let requiredInterfaceType: NWInterface.InterfaceType?
        let source: String
        if let discoveredInterface {
            requiredInterface = discoveredInterface.networkInterface
            requiredInterfaceType = discoveredInterface.networkInterface == nil ? discoveredInterface.type : nil
            source = "bonjour-awdl"
        } else {
            requiredInterface = nil
            requiredInterfaceType = .other
            source = "bonjour-peer-to-peer"

            let interfaces = host.discoveredInterfaces
                .map(\.name)
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            MirageLogger.client(
                "Trying optimistic peer-to-peer control attempts for \(host.name): no AWDL Bonjour interface " +
                    "interfaces=\(interfaces.isEmpty ? "none" : interfaces)"
            )
        }

        return transportOrder.compactMap { transportKind in
            guard let endpoint = peerToPeerPreferredControlSessionEndpoint(
                for: host,
                transportKind: transportKind,
                selectedHost: selectedHost
            ) else {
                return nil
            }

            let candidateKind = controlSessionCandidateKind(for: endpoint, host: host)
            guard candidateKind != .overlay else { return nil }
            logControlSessionEndpointSelection(
                transportKind: transportKind,
                hostName: host.name,
                selectedHost: selectedHost,
                port: endpointPort(for: endpoint),
                source: source
            )
            return ControlSessionAttempt(
                hostName: host.name,
                endpoint: endpoint,
                transportKind: transportKind,
                candidateKind: candidateKind,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                isPeerToPeerPreferred: true
            )
        }
    }

    func peerToPeerPreferredControlSessionEndpoint(
        for host: LoomPeer,
        transportKind: LoomTransportKind,
        selectedHost: NWEndpoint.Host
    ) -> NWEndpoint? {
        if let transport = host.advertisement.directTransports.first(where: { $0.transportKind == transportKind }),
           let port = NWEndpoint.Port(rawValue: transport.port) {
            return .hostPort(host: selectedHost, port: port)
        }
        guard transportKind == .tcp,
              case let .hostPort(_, port) = host.endpoint else {
            return nil
        }
        return .hostPort(host: selectedHost, port: port)
    }

    func peerToPeerPreferredBonjourControlHost(for host: LoomPeer) -> NWEndpoint.Host? {
        if let preferredBonjourHost = preferredBonjourControlHost(for: host) {
            return preferredBonjourHost
        }

        let peerName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerName.isEmpty else { return nil }
        return Self.expandedBonjourHosts(for: NWEndpoint.Host(peerName)).first
    }

    func controlSessionEndpoint(
        for host: LoomPeer,
        transportKind: LoomTransportKind,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> NWEndpoint? {
        guard let transport = host.advertisement.directTransports.first(where: { $0.transportKind == transportKind }),
              let port = NWEndpoint.Port(rawValue: transport.port) else {
            if transportKind == .tcp {
                if case let .hostPort(_, port) = host.endpoint,
                   let selectedHost = controlSessionHostSelection(
                       for: host,
                       endpointHost: endpointHost(for: host.endpoint),
                       localNetwork: localNetwork
                   ).host {
                    logControlSessionEndpointSelection(
                        transportKind: transportKind,
                        hostName: host.name,
                        selectedHost: selectedHost,
                        port: port,
                        source: "udp-host-fallback"
                    )
                    return .hostPort(host: selectedHost, port: port)
                }
                if case let .hostPort(endpointHost, port) = host.endpoint {
                    logControlSessionEndpointSelection(
                        transportKind: transportKind,
                        hostName: host.name,
                        selectedHost: endpointHost,
                        port: port,
                        source: "advertised-endpoint"
                    )
                }
                return host.endpoint
            }
            return nil
        }

        let endpointHost = endpointHost(for: host.endpoint)
        let selection = controlSessionHostSelection(
            for: host,
            endpointHost: endpointHost,
            localNetwork: localNetwork
        )

        guard let selectedHost = selection.host else { return nil }
        logControlSessionEndpointSelection(
            transportKind: transportKind,
            hostName: host.name,
            selectedHost: selectedHost,
            port: port,
            source: selection.source
        )
        return .hostPort(host: selectedHost, port: port)
    }

    /// Selects the host name or address used for every direct control transport.
    func controlSessionHostSelection(
        for host: LoomPeer,
        endpointHost: NWEndpoint.Host?,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> (host: NWEndpoint.Host?, source: String) {
        let preferredBonjourHost = preferredBonjourControlHost(for: host)

        // Prefer Bonjour-resolved IP addresses over hostname resolution.
        // This avoids platform-specific mDNS resolution failures (iOS) and
        // ensures we don't accidentally route through VPN/overlay interfaces
        // when a local path exists.
        if !host.resolvedAddresses.isEmpty {
            let usableResolvedAddresses = host.resolvedAddresses.filter {
                !Self.isScopeLessLinkLocalIPv6Address($0)
            }
            let localAddresses = usableResolvedAddresses.filter { !Self.isOverlayAddress($0) }
            if shouldPreferBonjourHostForPeerToPeer(
                host: host,
                localNetwork: localNetwork,
                preferredBonjourHost: preferredBonjourHost,
                resolvedAddresses: usableResolvedAddresses
            ), let preferredBonjourHost {
                return (preferredBonjourHost, "bonjour-proximity-connect")
            }
            if let preferred = localAddresses.first {
                return (preferred, "resolved-local-address")
            }
            // All resolved addresses are overlay — use the first one anyway
            // since it's still better than an unresolvable hostname.
            if let fallback = usableResolvedAddresses.first {
                return (fallback, "resolved-fallback-address")
            }
        }

        if let endpointHost, shouldPreferEndpointHostForDirectConnection(endpointHost) {
            return (endpointHost, "endpoint-host")
        }

        if let rememberedHost = rememberedDirectEndpointHostByDeviceID[host.deviceID],
           shouldPreferEndpointHostForDirectConnection(rememberedHost),
           !Self.isOverlayCandidateHost(rememberedHost) {
            return (rememberedHost, "remembered-direct-host")
        }

        if let preferredBonjourHost {
            return (preferredBonjourHost, "bonjour-hostname")
        }

        let peerName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerName.isEmpty else { return (nil, "none") }
        return (Self.expandedBonjourHosts(for: NWEndpoint.Host(peerName)).first, "peer-name-bonjour")
    }

    func endpointPort(for endpoint: NWEndpoint) -> NWEndpoint.Port {
        guard case let .hostPort(_, port) = endpoint else { return .any }
        return port
    }

    func preferredBonjourControlHost(for host: LoomPeer) -> NWEndpoint.Host? {
        let advertisedHostName = host.advertisement.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let advertisedHostName, !advertisedHostName.isEmpty {
            let expandedHosts = Self.expandedBonjourHosts(for: NWEndpoint.Host(advertisedHostName))
            if let preferredHost = expandedHosts.first {
                return preferredHost
            }
        }
        return nil
    }

    func shouldPreferBonjourHostForPeerToPeer(
        host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics,
        preferredBonjourHost: NWEndpoint.Host?,
        resolvedAddresses: [NWEndpoint.Host]
    ) -> Bool {
        guard networkConfig.enablePeerToPeer,
              preferredBonjourHost != nil,
              !resolvedAddresses.isEmpty,
              isBonjourDiscoveredHost(host) else {
            return false
        }

        let hostNetwork = MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
            from: host.advertisement
        )
        guard !localNetwork.allSubnetSignatures.isEmpty,
              !hostNetwork.allSubnetSignatures.isEmpty else {
            return false
        }

        return localNetwork.allSubnetSignatures
            .intersection(hostNetwork.allSubnetSignatures)
            .isEmpty
    }

    func isBonjourDiscoveredHost(_ host: LoomPeer) -> Bool {
        if case .service = host.endpoint {
            return true
        }
        guard let endpointHost = endpointHost(for: host.endpoint) else { return false }
        switch endpointHost {
        case let .name(value, _):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.hasSuffix(".local") || !normalized.contains(".")
        default:
            return false
        }
    }

    func logControlSessionEndpointSelection(
        transportKind: LoomTransportKind,
        hostName: String,
        selectedHost: NWEndpoint.Host,
        port: NWEndpoint.Port,
        source: String
    ) {
        MirageLogger.client(
            "Selected \(transportKind.rawValue) control endpoint for \(hostName): " +
                "\(selectedHost):\(port.rawValue) source=\(source)"
        )
    }

    func controlSessionCandidateKind(
        for endpoint: NWEndpoint,
        host: LoomPeer
    ) -> ControlSessionCandidateKind {
        guard case let .hostPort(endpointHost, _) = endpoint else {
            return .local
        }
        if Self.isOverlayCandidateHost(endpointHost) {
            return .overlay
        }
        if Self.isRemoteAccessAmbiguousLocalCandidate(endpointHost, host: host) {
            return .overlay
        }
        if Self.isLocalControlCandidateHost(endpointHost) {
            return .local
        }
        if host.advertisement.mirageVPNAccessEnabled {
            return .overlay
        }
        if Self.isPublicIPv6Candidate(endpointHost) {
            return .publicIPv6
        }
        if shouldPreferEndpointHostForDirectConnection(endpointHost) {
            return .local
        }
        return .stun
    }

    static func isRemoteAccessAmbiguousLocalCandidate(
        _ endpointHost: NWEndpoint.Host,
        host: LoomPeer
    ) -> Bool {
        guard host.advertisement.mirageVPNAccessEnabled else { return false }
        if isLocalResolvedControlCandidate(endpointHost, host: host) {
            return false
        }

        switch endpointHost {
        case let .name(value, _):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            return !normalized.contains(".")
        case let .ipv6(addr):
            let raw = addr.rawValue
            guard raw.count >= 1 else { return false }
            let first = raw[raw.startIndex]
            return first == 0xFC || first == 0xFD
        default:
            return false
        }
    }

    static func isLocalResolvedControlCandidate(
        _ endpointHost: NWEndpoint.Host,
        host: LoomPeer
    ) -> Bool {
        host.resolvedAddresses.contains { resolvedAddress in
            !isOverlayAddress(resolvedAddress) && resolvedAddress.debugDescription == endpointHost.debugDescription
        }
    }

    static func isOverlayCandidateHost(_ host: NWEndpoint.Host) -> Bool {
        if isOverlayAddress(host) {
            return true
        }
        guard case let .name(value, _) = host else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(".ts.net") || normalized.contains(".ts.")
    }

    static func isPublicIPv6Candidate(_ host: NWEndpoint.Host) -> Bool {
        guard case .ipv6 = host else { return false }
        return !isScopeLessLinkLocalIPv6Address(host) && !isOverlayAddress(host)
    }

    static func isLocalControlCandidateHost(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case let .ipv4(addr):
            let raw = addr.rawValue
            guard raw.count >= 4 else { return false }
            let first = raw[raw.startIndex]
            let second = raw[raw.startIndex.advanced(by: 1)]
            if first == 10 { return true }
            if first == 192, second == 168 { return true }
            if first == 172, (16 ... 31).contains(second) { return true }
            if first == 169, second == 254 { return true }
            return false
        case let .ipv6(addr):
            let raw = addr.rawValue
            guard raw.count >= 1 else { return false }
            let first = raw[raw.startIndex]
            return first == 0xFC || first == 0xFD || isScopeLessLinkLocalIPv6Address(host)
        case let .name(value, _):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            return normalized.hasSuffix(".local") || !normalized.contains(".")
        default:
            return false
        }
    }

    /// Returns `true` when the host is an overlay/VPN address (e.g. Tailscale CGNAT).
    static func isOverlayAddress(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case let .ipv4(addr):
            // Tailscale uses 100.64.0.0/10 (CGNAT range).
            let raw = addr.rawValue
            guard raw.count >= 4 else { return false }
            return raw[raw.startIndex] == 100 && (raw[raw.startIndex.advanced(by: 1)] & 0xC0) == 64
        case let .ipv6(addr):
            // Tailscale IPv6: fd7a:115c:a1e0::/48
            let raw = addr.rawValue
            guard raw.count >= 6 else { return false }
            return raw[raw.startIndex] == 0xFD
                && raw[raw.startIndex.advanced(by: 1)] == 0x7A
                && raw[raw.startIndex.advanced(by: 2)] == 0x11
                && raw[raw.startIndex.advanced(by: 3)] == 0x5C
                && raw[raw.startIndex.advanced(by: 4)] == 0xA1
                && raw[raw.startIndex.advanced(by: 5)] == 0xE0
        default:
            return false
        }
    }

    func endpointHost(for endpoint: NWEndpoint) -> NWEndpoint.Host? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return host
    }

    func shouldPreferEndpointHostForDirectConnection(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4:
            return true
        case .ipv6:
            return !Self.isScopeLessLinkLocalIPv6Address(host)
        case let .name(value, _):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            guard !Self.isScopeLessLinkLocalIPv6Name(normalized) else { return false }
            return normalized.hasSuffix(".local") == false
        @unknown default:
            return false
        }
    }

    static func isScopeLessLinkLocalIPv6Address(_ host: NWEndpoint.Host) -> Bool {
        guard case let .ipv6(addr) = host else { return false }
        let raw = addr.rawValue
        guard raw.count >= 2 else { return false }
        return raw[raw.startIndex] == 0xFE &&
            (raw[raw.index(after: raw.startIndex)] & 0xC0) == 0x80
    }

    static func isScopeLessLinkLocalIPv6Name(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.hasPrefix("fe80:") && !trimmed.contains("%")
    }
}
