//
//  MirageClientService+ControlSessionEndpoint.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation
import Loom
import Network

private let experimentalSystemProximityRoutingEnvironmentKey = "MIRAGE_EXPERIMENTAL_SYSTEM_PROXIMITY_ROUTING"
private let experimentalSystemProximityEndpointSource = "bonjour-system-proximity-service"

@MainActor
extension MirageClientService {
    nonisolated static func experimentalSystemProximityRoutingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        MirageEnvironmentValue.isTruthy(environment[experimentalSystemProximityRoutingEnvironmentKey])
    }

    public nonisolated static let controlSessionAttemptCooldownSeconds: TimeInterval = 8

    func controlSessionAttempts(
        for host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics? = nil,
        experimentalSystemProximityRoutingEnabled: Bool? = nil
    ) -> [ControlSessionAttempt] {
        let usesExperimentalSystemProximityRouting = experimentalSystemProximityRoutingEnabled ??
            Self.experimentalSystemProximityRoutingEnabled()
        let resolvedLocalNetwork = localNetwork ?? ControlSessionNetworkDiagnostics(
            snapshot: localNetworkMonitor.snapshot
        )
        let explicitVPNRoute = isExplicitVPNConnection(host)
        var attempts: [ControlSessionAttempt] = []
        let transportOrder = controlSessionTransportOrder()

        if usesExperimentalSystemProximityRouting {
            attempts.append(contentsOf: systemPreferredControlSessionAttempts(for: host))
        }
        attempts.append(
            contentsOf: proximityPreferredControlSessionAttempts(
                for: host,
                localNetwork: resolvedLocalNetwork,
                transportOrder: transportOrder
            )
        )

        var resolvedAttempts: [ControlSessionAttempt] = []
        for transportKind in transportOrder {
            guard let endpoint = controlSessionEndpoint(
                for: host,
                transportKind: transportKind,
                localNetwork: resolvedLocalNetwork
            ) else {
                continue
            }

            let candidateKind: ControlSessionCandidateKind = explicitVPNRoute
                ? .overlay
                : controlSessionCandidateKind(for: endpoint, host: host)
            resolvedAttempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: endpoint,
                    transportKind: transportKind,
                    candidateKind: candidateKind,
                    routeTier: controlSessionRouteTier(
                        for: candidateKind,
                        host: host,
                        localNetwork: resolvedLocalNetwork
                    ),
                    requiredInterfaceType: candidateKind == .overlay ? nil : preferredNetworkType.requiredInterfaceType
                )
            )
        }
        attempts.append(contentsOf: resolvedAttempts)

        if attempts.isEmpty {
            let candidateKind: ControlSessionCandidateKind = explicitVPNRoute
                ? .overlay
                : controlSessionCandidateKind(for: host.endpoint, host: host)
            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: host.endpoint,
                    transportKind: .tcp,
                    candidateKind: candidateKind,
                    routeTier: controlSessionRouteTier(
                        for: candidateKind,
                        host: host,
                        localNetwork: resolvedLocalNetwork
                    ),
                    requiredInterfaceType: candidateKind == .overlay ? nil : preferredNetworkType.requiredInterfaceType
                )
            )
        }

        let orderedAttempts = orderedControlSessionAttempts(attempts)
        return applyDebugRouteOverrideIfNeeded(to: orderedAttempts, host: host)
    }

    func applyDebugRouteOverrideIfNeeded(
        to attempts: [ControlSessionAttempt],
        host: LoomPeer
    ) -> [ControlSessionAttempt] {
        guard let debugRouteOverride else { return attempts }
        let forcedAttempts = attempts.filter { attempt in
            debugRouteOverride.matches(attempt)
        }
        if forcedAttempts.isEmpty {
            let availableAttempts = attempts
                .map(Self.debugRouteAttemptDescription(_:))
                .joined(separator: ";")
            MirageLogger.client(
                "Debug route override \(debugRouteOverride.displayName) found no matching attempts for \(host.name) " +
                    "availableAttempts=\(availableAttempts.isEmpty ? "none" : availableAttempts) " +
                    "systemProximityInterfaces=\(MirageLocalNetworkMonitor.proximityInterfaceDiagnostics())"
            )
        } else {
            MirageLogger.client(
                "Debug route override \(debugRouteOverride.displayName) forced \(forcedAttempts.count)/\(attempts.count) attempts for \(host.name)"
            )
        }
        return forcedAttempts
    }

    private static func debugRouteAttemptDescription(_ attempt: ControlSessionAttempt) -> String {
        let endpoint = String(describing: attempt.endpoint)
        let source = attempt.endpointSource.isEmpty ? "unknown" : attempt.endpointSource
        return "\(attempt.transportKind.rawValue):\(attempt.routeTier.rawValue):" +
            "\(attempt.interfaceDescription):\(endpoint):source=\(source)"
    }

    func orderedControlSessionAttempts(_ attempts: [ControlSessionAttempt]) -> [ControlSessionAttempt] {
        let now = CFAbsoluteTimeGetCurrent()
        pruneExpiredControlSessionAttemptCooldowns(now: now)
        return attempts.enumerated()
            .sorted { lhs, rhs in
                let leftFallbackRank = controlSessionCompatibilityFallbackRank(for: lhs.element)
                let rightFallbackRank = controlSessionCompatibilityFallbackRank(for: rhs.element)
                if leftFallbackRank != rightFallbackRank { return leftFallbackRank < rightFallbackRank }
                let leftOnCooldown = controlSessionAttemptIsOnCooldown(lhs.element, now: now)
                let rightOnCooldown = controlSessionAttemptIsOnCooldown(rhs.element, now: now)
                if leftOnCooldown != rightOnCooldown {
                    return !leftOnCooldown
                }
                let leftSystemProximity = lhs.element.endpointSource == experimentalSystemProximityEndpointSource
                let rightSystemProximity = rhs.element.endpointSource == experimentalSystemProximityEndpointSource
                if leftSystemProximity != rightSystemProximity {
                    return leftSystemProximity
                }
                let leftRouteRank = controlSessionRouteRank(for: lhs.element.routeTier)
                let rightRouteRank = controlSessionRouteRank(for: rhs.element.routeTier)
                if leftRouteRank != rightRouteRank {
                    return leftRouteRank < rightRouteRank
                }
                let leftRank = controlSessionTransportRank(
                    transportKind: lhs.element.transportKind,
                    candidateKind: lhs.element.candidateKind
                )
                let rightRank = controlSessionTransportRank(
                    transportKind: rhs.element.transportKind,
                    candidateKind: rhs.element.candidateKind
                )
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func controlSessionCompatibilityFallbackRank(for attempt: ControlSessionAttempt) -> Int {
        attempt.transportKind == .tcp ? 1 : 0
    }

    func coolDownControlSessionAttempt(
        _ attempt: ControlSessionAttempt,
        duration: TimeInterval = controlSessionAttemptCooldownSeconds,
        reason: String
    ) {
        let expiry = CFAbsoluteTimeGetCurrent() + max(1, duration)
        controlSessionAttemptCooldownExpirations[attempt.cooldownKey] = expiry
        MirageLogger.client(
            "Cooling down control route for \(attempt.hostName) " +
                "transport=\(attempt.transportKind.rawValue) route=\(attempt.routeTier.rawValue) " +
                "endpoint=\(attempt.endpoint) interface=\(attempt.interfaceDescription) " +
                "duration=\(Int(duration))s reason=\(reason)"
        )
    }

    public func coolDownCurrentControlSessionRoute(
        duration: TimeInterval = controlSessionAttemptCooldownSeconds,
        reason: String
    ) {
        guard let currentControlSessionAttemptCooldownKey else { return }
        let expiry = CFAbsoluteTimeGetCurrent() + max(1, duration)
        controlSessionAttemptCooldownExpirations[currentControlSessionAttemptCooldownKey] = expiry
        MirageLogger.client(
            "Cooling down current control route duration=\(Int(duration))s reason=\(reason)"
        )
    }

    func controlSessionAttemptIsOnCooldown(
        _ attempt: ControlSessionAttempt,
        now: CFAbsoluteTime
    ) -> Bool {
        guard debugRouteOverride == nil else { return false }
        guard let expiry = controlSessionAttemptCooldownExpirations[attempt.cooldownKey] else { return false }
        return expiry > now
    }

    func pruneExpiredControlSessionAttemptCooldowns(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        for (key, expiry) in controlSessionAttemptCooldownExpirations where expiry <= now {
            controlSessionAttemptCooldownExpirations.removeValue(forKey: key)
        }
    }

    func controlSessionRouteRank(for routeTier: ControlSessionRouteTier) -> Int {
        guard preferWiFiBeforeAwdlProximity else {
            return routeTier.rank
        }

        return switch routeTier {
        case .applePrivateNCM:
            0
        case .bridge:
            1
        case .sameWiredEthernet:
            2
        case .lowLatencyWireless:
            3
        case .mixedEthernetSameLAN:
            4
        case .wifiLAN:
            5
        case .vpn:
            6
        case .other:
            7
        case .awdl:
            8
        }
    }

    func controlSessionTransportRank(
        transportKind: LoomTransportKind,
        candidateKind: ControlSessionCandidateKind
    ) -> Int {
        let transportOrder: [LoomTransportKind] = switch candidateKind {
        case .overlay:
            MirageKit.mirageAppPreferredDirectTransportOrder
        case .local, .publicIPv6, .stun, .portMapped:
            MirageKit.mirageAppPreferredDirectTransportOrder
        }
        return transportOrder.firstIndex(of: transportKind) ?? transportOrder.count
    }

    func controlSessionTransportOrder() -> [LoomTransportKind] {
        MirageKit.mirageAppPreferredDirectTransportOrder
    }

    func systemPreferredControlSessionAttempts(for host: LoomPeer) -> [ControlSessionAttempt] {
        guard networkConfig.enablePeerToPeer,
              isBonjourDiscoveredHost(host),
              !isExplicitVPNConnection(host),
              let endpoint = bonjourServiceControlEndpoint(for: host, interface: nil) else {
            return []
        }

        MirageLogger.client(
            "Adding experimental system-selected proximity control attempt to \(host.name): " +
                "endpoint=\(endpoint)"
        )
        return [
            ControlSessionAttempt(
                hostName: host.name,
                endpoint: endpoint,
                transportKind: .tcp,
                candidateKind: .local,
                routeTier: .lowLatencyWireless,
                endpointSource: experimentalSystemProximityEndpointSource,
                isPeerToPeerPreferred: true
            ),
        ]
    }

    func peerToPeerPreferredControlSessionAttempts(
        for host: LoomPeer,
        transportOrder: [LoomTransportKind]
    ) -> [ControlSessionAttempt] {
        proximityPreferredControlSessionAttempts(
            for: host,
            localNetwork: ControlSessionNetworkDiagnostics(snapshot: localNetworkMonitor.snapshot),
            transportOrder: transportOrder
        )
    }

    func proximityPreferredControlSessionAttempts(
        for host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics,
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
                "Skipping proximity-preferred control attempts for \(host.name): no Bonjour hostname"
            )
            return []
        }

        let proximityInterfaces = proximityPreferredDiscoveredInterfaces(
            for: host,
            localNetwork: localNetwork
        )
        let scopedHosts = scopedProximityResolvedHosts(for: host)
        guard !proximityInterfaces.isEmpty || !scopedHosts.isEmpty else {
            if !host.resolvedAddresses.isEmpty {
                let interfaces = host.discoveredInterfaces
                    .map(\.name)
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
                MirageLogger.client(
                    "Skipping proximity-preferred control attempts for \(host.name): " +
                        "no proximity route evidence interfaces=\(interfaces.isEmpty ? "none" : interfaces)"
                )
            }
            return []
        }

        var attempts: [ControlSessionAttempt] = []
        var attemptedInterfaceNames: Set<String> = []
        for (discoveredInterface, routeTier) in proximityInterfaces {
            let scopedHost = scopedLinkLocalResolvedHost(
                for: discoveredInterface,
                host: host
            )
            let interfaceSelectedHost = scopedHost
                ?? interfaceScopedHost(selectedHost, interface: discoveredInterface.networkInterface)

            // AWDL data paths require an awdl0-scoped link-local literal. The
            // hostname-plus-interface form is kept out of UDP attempts
            // planning, but the Bonjour TCP service endpoint is a real resolved
            // service path and lets Network.framework choose the peer-to-peer
            // data path without inventing an address.
            if routeTier == .awdl, scopedHost == nil {
                if let serviceAttempt = bonjourServiceControlSessionAttempt(
                    for: host,
                    discoveredInterface: discoveredInterface,
                    routeTier: routeTier
                ) {
                    attempts.append(serviceAttempt)
                    MirageLogger.client(
                        "Using Bonjour TCP service endpoint for AWDL control attempt " +
                            "to \(host.name): no awdl0-scoped address resolved yet"
                    )
                } else {
                    MirageLogger.client(
                        "Skipping AWDL control attempts for \(host.name): no awdl0-scoped " +
                            "address resolved yet"
                    )
                }
                continue
            }

            guard scopedHost != nil ||
                  discoveredInterface.networkInterface != nil ||
                  discoveredInterface.type != .other ||
                  routeTier != .other else {
                MirageLogger.client(
                    "Skipping proximity-preferred control attempts for \(host.name): " +
                        "\(discoveredInterface.name) has no concrete interface or scoped address"
                )
                continue
            }

            let normalizedName = discoveredInterface.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalizedName.isEmpty {
                attemptedInterfaceNames.insert(normalizedName)
            }
            attempts.append(
                contentsOf: proximityPreferredControlSessionAttempts(
                    for: host,
                    transportOrder: transportOrder,
                    selectedHost: interfaceSelectedHost,
                    discoveredInterface: discoveredInterface,
                    routeTier: routeTier,
                    endpointSource: scopedHost == nil ? "bonjour-proximity-interface" : "bonjour-proximity-scoped-address"
                )
            )
        }

        for scopedHost in scopedHosts {
            guard let interfaceName = Self.scopedLinkLocalIPv6InterfaceName(scopedHost),
                  !attemptedInterfaceNames.contains(interfaceName) else {
                continue
            }
            let matchingInterface = host.discoveredInterfaces.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == interfaceName
            }
            let routeTier = Self.proximityRouteTier(forInterfaceName: interfaceName) ?? .other
            if Self.isAwdlRadioRouteTier(routeTier),
               awdlProximityRouteIsSuppressed(for: host, interfaceName: interfaceName) {
                continue
            }
            attempts.append(
                contentsOf: proximityPreferredControlSessionAttempts(
                    for: host,
                    transportOrder: transportOrder,
                    selectedHost: scopedHost,
                    discoveredInterface: matchingInterface,
                    routeTier: routeTier,
                    proximityInterfaceNames: [interfaceName],
                    endpointSource: "bonjour-proximity-scoped-address"
                )
            )
        }

        return attempts
    }

    func bonjourServiceControlSessionAttempt(
        for host: LoomPeer,
        discoveredInterface: LoomDiscoveredInterface,
        routeTier: ControlSessionRouteTier
    ) -> ControlSessionAttempt? {
        guard let endpoint = bonjourServiceControlEndpoint(
            for: host,
            interface: discoveredInterface.networkInterface
        ) else {
            return nil
        }

        let proximityInterfaceKind = proximityInterfaceKind(
            for: discoveredInterface,
            routeTier: routeTier
        )
        return ControlSessionAttempt(
            hostName: host.name,
            endpoint: endpoint,
            transportKind: .tcp,
            candidateKind: .local,
            routeTier: routeTier,
            endpointSource: "bonjour-proximity-service",
            requiredInterface: discoveredInterface.networkInterface,
            isPeerToPeerPreferred: true,
            proximityInterfaceKind: proximityInterfaceKind,
            proximityInterfaceNames: [discoveredInterface.name]
        )
    }

    func bonjourServiceControlEndpoint(
        for host: LoomPeer,
        interface: NWInterface?
    ) -> NWEndpoint? {
        guard case let .service(name, type, domain, _) = host.endpoint else {
            return nil
        }
        let serviceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceName.isEmpty, !serviceType.isEmpty else { return nil }
        return .service(
            name: serviceName,
            type: serviceType,
            domain: domain,
            interface: interface
        )
    }

    func interfaceScopedHost(
        _ host: NWEndpoint.Host,
        interface: NWInterface?
    ) -> NWEndpoint.Host {
        guard let interface else { return host }
        switch host {
        case let .name(value, _):
            return .name(value, interface)
        default:
            return host
        }
    }

    func scopedLinkLocalResolvedHost(
        for discoveredInterface: LoomDiscoveredInterface,
        host: LoomPeer
    ) -> NWEndpoint.Host? {
        let interfaceName = discoveredInterface.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interfaceName.isEmpty else { return nil }
        return host.resolvedAddresses.first {
            Self.scopedLinkLocalIPv6InterfaceName($0) == interfaceName.lowercased()
        }
    }

    func hasPendingAwdlScopedAddressResolution(for host: LoomPeer) -> Bool {
        host.discoveredInterfaces.contains { discoveredInterface in
            discoveredInterface.kind == .awdl &&
                !awdlProximityRouteIsSuppressed(for: host, interfaceName: discoveredInterface.name) &&
                scopedLinkLocalResolvedHost(for: discoveredInterface, host: host) == nil
        }
    }

    func shouldWaitForPendingAwdlScopedAddress(
        host: LoomPeer,
        attempts: [ControlSessionAttempt]
    ) -> Bool {
        guard hasPendingAwdlScopedAddressResolution(for: host) else { return false }
        let awdlRank = controlSessionRouteRank(for: .awdl)
        return !attempts.contains { controlSessionRouteRank(for: $0.routeTier) < awdlRank }
    }

    func scopedProximityResolvedHost(for host: LoomPeer) -> NWEndpoint.Host? {
        scopedProximityResolvedHosts(for: host).first
    }

    func scopedProximityResolvedHosts(for host: LoomPeer) -> [NWEndpoint.Host] {
        host.resolvedAddresses.enumerated().compactMap { offset, resolvedHost
            -> (host: NWEndpoint.Host, interfaceName: String, priority: Int, offset: Int)? in
            guard let interfaceName = Self.scopedLinkLocalIPv6InterfaceName(resolvedHost) else {
                return nil
            }
            guard let priority = Self.proximityPriority(forInterfaceName: interfaceName) else {
                return nil
            }
            return (host: resolvedHost, interfaceName: interfaceName, priority: priority, offset: offset)
        }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.interfaceName != rhs.interfaceName {
                return lhs.interfaceName < rhs.interfaceName
            }
            return lhs.offset < rhs.offset
        }
        .map(\.host)
    }

    func proximityPreferredDiscoveredInterfaces(
        for host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> [(interface: LoomDiscoveredInterface, routeTier: ControlSessionRouteTier)] {
        host.discoveredInterfaces
            .compactMap { discoveredInterface -> (interface: LoomDiscoveredInterface, routeTier: ControlSessionRouteTier)? in
                guard let routeTier = controlSessionRouteTier(
                    for: discoveredInterface,
                    host: host,
                    localNetwork: localNetwork
                ) else {
                    return nil
                }
                if Self.isAwdlRadioRouteTier(routeTier),
                   awdlProximityRouteIsSuppressed(for: host, interfaceName: discoveredInterface.name) {
                    return nil
                }
                return (interface: discoveredInterface, routeTier: routeTier)
            }
            .sorted { lhs, rhs in
                if lhs.routeTier.rank != rhs.routeTier.rank {
                    return lhs.routeTier.rank < rhs.routeTier.rank
                }
                if lhs.interface.index != rhs.interface.index {
                    return lhs.interface.index < rhs.interface.index
                }
                return lhs.interface.name < rhs.interface.name
            }
    }

    func proximityPreferredControlSessionAttempts(
        for host: LoomPeer,
        transportOrder: [LoomTransportKind],
        selectedHost: NWEndpoint.Host,
        discoveredInterface: LoomDiscoveredInterface?,
        routeTier: ControlSessionRouteTier,
        proximityInterfaceKind: LoomDiscoveredInterfaceKind? = nil,
        proximityInterfaceNames: [String] = [],
        endpointSource: String
    ) -> [ControlSessionAttempt] {
        let requiredInterface = discoveredInterface?.networkInterface
        let requiredInterfaceType: NWInterface.InterfaceType?
        if let discoveredInterface,
           discoveredInterface.networkInterface == nil,
           discoveredInterface.type != .other {
            requiredInterfaceType = discoveredInterface.type
        } else {
            requiredInterfaceType = nil
        }
        let resolvedProximityInterfaceKind = discoveredInterface.map {
            self.proximityInterfaceKind(for: $0, routeTier: routeTier)
        } ?? proximityInterfaceKind
        let source = resolvedProximityInterfaceKind.map {
            "bonjour-proximity-\(proximityLogName(for: $0))"
        } ?? endpointSource
        let proximityTransportOrder = routeTier == .awdl
            ? transportOrder.filter { $0 != .tcp }
            : transportOrder

        return proximityTransportOrder.compactMap { transportKind in
            guard let endpoint = peerToPeerPreferredControlSessionEndpoint(
                for: host,
                transportKind: transportKind,
                selectedHost: selectedHost
            ) else {
                return nil
            }

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
                candidateKind: .local,
                routeTier: routeTier,
                endpointSource: source,
                requiredInterface: requiredInterface,
                requiredInterfaceType: requiredInterfaceType,
                isPeerToPeerPreferred: true,
                proximityInterfaceKind: resolvedProximityInterfaceKind,
                proximityInterfaceNames: discoveredInterface.map { [$0.name] } ?? proximityInterfaceNames
            )
        }
    }

    func proximityInterfaceKind(
        for discoveredInterface: LoomDiscoveredInterface,
        routeTier: ControlSessionRouteTier
    ) -> LoomDiscoveredInterfaceKind {
        Self.proximityInterfaceKind(forInterfaceName: discoveredInterface.name) ??
            Self.proximityInterfaceKind(forRouteTier: routeTier) ??
            discoveredInterface.kind
    }

    func proximityLogName(for kind: LoomDiscoveredInterfaceKind) -> String {
        switch kind {
        case .applePrivateNCM:
            "anpi"
        case .awdl:
            "awdl"
        case .lowLatencyWireless:
            "llw"
        case .wiredEthernet:
            "wired"
        case .bridge:
            "bridge"
        case .wifi:
            "wifi"
        case .cellular:
            "cellular"
        case .loopback:
            "loopback"
        case .overlay:
            "overlay"
        case .other:
            "other"
        }
    }

    func peerToPeerPreferredControlSessionEndpoint(
        for host: LoomPeer,
        transportKind: LoomTransportKind,
        selectedHost: NWEndpoint.Host
    ) -> NWEndpoint? {
        if let transport = host.advertisement.directTransports.first(where: { $0.transportKind == transportKind }),
           let port = NWEndpoint.Port(rawValue: transport.port) {
            guard transportKind != .tcp || Self.scopedAwdlTransportRestrictedInterfaceName(selectedHost) == nil else {
                return nil
            }
            return .hostPort(host: selectedHost, port: port)
        }
        guard transportKind == .tcp,
              case let .hostPort(_, port) = host.endpoint else {
            return nil
        }
        guard Self.scopedAwdlTransportRestrictedInterfaceName(selectedHost) == nil else { return nil }
        return .hostPort(host: selectedHost, port: port)
    }

    func peerToPeerPreferredBonjourControlHost(for host: LoomPeer) -> NWEndpoint.Host? {
        if let serviceHost = bonjourServiceControlHost(for: host) {
            return serviceHost
        }
        if let preferredBonjourHost = preferredBonjourControlHost(for: host) {
            return preferredBonjourHost
        }

        return nil
    }

    func bonjourServiceControlHost(for host: LoomPeer) -> NWEndpoint.Host? {
        if case let .service(name, _, _, _) = host.endpoint {
            let serviceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !serviceName.isEmpty {
                return Self.expandedBonjourHosts(for: NWEndpoint.Host(serviceName)).first
            }
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
                if controlSessionCandidateKind(for: host.endpoint, host: host) == .overlay {
                    return nil
                }
                if case let .hostPort(_, port) = host.endpoint,
                   let selectedHost = controlSessionHostSelection(
                       for: host,
                       endpointHost: endpointHost(for: host.endpoint),
                       localNetwork: localNetwork
                   ).host {
                    guard Self.scopedAwdlTransportRestrictedInterfaceName(selectedHost) == nil else { return nil }
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
                    guard Self.scopedAwdlTransportRestrictedInterfaceName(endpointHost) == nil else { return nil }
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
        guard transportKind != .tcp || Self.scopedAwdlTransportRestrictedInterfaceName(selectedHost) == nil else {
            return nil
        }
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

        if isExplicitVPNConnection(host), let endpointHost {
            return (endpointHost, "explicit-vpn-endpoint")
        }

        // Prefer Bonjour-resolved IP addresses over hostname resolution.
        // This avoids platform-specific mDNS resolution failures (iOS) and
        // ensures we don't accidentally route through VPN/overlay interfaces
        // when a local path exists.
        if !host.resolvedAddresses.isEmpty {
            let usableResolvedAddresses = host.resolvedAddresses.filter {
                !Self.isScopeLessLinkLocalIPv6Address($0) &&
                    !awdlEndpointHostIsSuppressed($0, for: host)
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
            if preferWiFiBeforeAwdlProximity,
               let preferred = localAddresses.first(where: { !Self.isAwdlRadioEndpointHost($0) }) {
                return (preferred, "resolved-local-address")
            }
            if preferWiFiBeforeAwdlProximity,
               let rememberedHost = rememberedDirectEndpointHost(for: host) {
                return (rememberedHost, "remembered-direct-host")
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

        if let endpointHost,
           shouldPreferEndpointHostForDirectConnection(endpointHost),
           !awdlEndpointHostIsSuppressed(endpointHost, for: host) {
            return (endpointHost, "endpoint-host")
        }

        if let rememberedHost = rememberedDirectEndpointHost(for: host) {
            return (rememberedHost, "remembered-direct-host")
        }

        if let preferredBonjourHost {
            return (preferredBonjourHost, "bonjour-hostname")
        }

        let peerName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerName.isEmpty else { return (nil, "none") }
        return (Self.expandedBonjourHosts(for: NWEndpoint.Host(peerName)).first, "peer-name-bonjour")
    }

    func rememberedDirectEndpointHost(for host: LoomPeer) -> NWEndpoint.Host? {
        guard let rememberedHost = rememberedDirectEndpointHostByDeviceID[host.deviceID],
              shouldPreferEndpointHostForDirectConnection(rememberedHost),
              !Self.isOverlayCandidateHost(rememberedHost),
              !awdlEndpointHostIsSuppressed(rememberedHost, for: host) else {
            return nil
        }
        return rememberedHost
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

        let hostNetwork = MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
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

    func controlSessionRouteTier(
        for candidateKind: ControlSessionCandidateKind,
        host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> ControlSessionRouteTier {
        switch candidateKind {
        case .overlay:
            .vpn
        case .local:
            localLANRouteTier(for: host, localNetwork: localNetwork)
        case .publicIPv6, .portMapped, .stun:
            .other
        }
    }

    func controlSessionRouteTier(
        for discoveredInterface: LoomDiscoveredInterface,
        host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> ControlSessionRouteTier? {
        if let nameRouteTier = Self.proximityRouteTier(forInterfaceName: discoveredInterface.name) {
            switch nameRouteTier {
            case .applePrivateNCM, .bridge, .lowLatencyWireless:
                return nameRouteTier
            case .awdl:
                return awdlProximityRouteIsSuppressed(for: host, interfaceName: discoveredInterface.name) ? nil : .awdl
            case .sameWiredEthernet, .mixedEthernetSameLAN, .wifiLAN, .vpn, .other:
                break
            }
        }

        return switch discoveredInterface.kind {
        case .applePrivateNCM:
            .applePrivateNCM
        case .bridge:
            .bridge
        case .lowLatencyWireless:
            .lowLatencyWireless
        case .wiredEthernet:
            (hasConcreteWiredProximityInterface(discoveredInterface) ||
                hasSameWiredEthernetRoute(to: host, localNetwork: localNetwork))
                ? .sameWiredEthernet
                : nil
        case .awdl:
            awdlProximityRouteIsSuppressed(for: host, interfaceName: discoveredInterface.name) ? nil : .awdl
        case .wifi, .cellular, .loopback, .overlay, .other:
            nil
        }
    }

    func localLANRouteTier(
        for host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> ControlSessionRouteTier {
        if hasSameWiredEthernetRoute(to: host, localNetwork: localNetwork) {
            return .sameWiredEthernet
        }
        if hasMixedEthernetSameLANRoute(to: host, localNetwork: localNetwork) {
            return .mixedEthernetSameLAN
        }
        return .wifiLAN
    }

    func hasSameWiredEthernetRoute(
        to host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> Bool {
        let hostNetwork = MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
            from: host.advertisement
        )
        let localWired = Set(localNetwork.wiredSubnetSignatures)
        let hostWired = Set(hostNetwork.wiredSubnetSignatures)
        guard !localWired.isEmpty, !hostWired.isEmpty else { return false }
        return !localWired.intersection(hostWired).isEmpty
    }

    func hasConcreteWiredProximityInterface(_ discoveredInterface: LoomDiscoveredInterface) -> Bool {
        if discoveredInterface.networkInterface?.type == .wiredEthernet {
            return true
        }
        return discoveredInterface.type == .wiredEthernet
    }

    func hasMixedEthernetSameLANRoute(
        to host: LoomPeer,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> Bool {
        let hostNetwork = MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
            from: host.advertisement
        )
        let localWired = Set(localNetwork.wiredSubnetSignatures)
        let hostWired = Set(hostNetwork.wiredSubnetSignatures)
        let localHasWired = !localWired.isEmpty
        let hostHasWired = !hostWired.isEmpty
        guard localHasWired != hostHasWired else { return false }

        if localHasWired {
            return !localWired.intersection(hostNetwork.allSubnetSignatures).isEmpty
        }
        return !hostWired.intersection(localNetwork.allSubnetSignatures).isEmpty
    }

    func isExplicitVPNConnection(_ host: LoomPeer) -> Bool {
        host.advertisement.metadata["mirage.connection-origin"] == "remote"
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
        if isExplicitVPNConnection(host) {
            return .overlay
        }
        guard case let .hostPort(endpointHost, _) = endpoint else {
            if !host.resolvedAddresses.isEmpty,
               host.resolvedAddresses.allSatisfy(Self.isOverlayAddress) {
                return .overlay
            }
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
        switch MirageEndpointClassifier.classify(host) {
        case .tailscaleIPv4, .tailscaleIPv6, .tailscaleMagicDNS:
            true
        case .privateLAN, .bonjour, .publicIPv6, .unknown:
            false
        }
    }

    static func isPublicIPv6Candidate(_ host: NWEndpoint.Host) -> Bool {
        MirageEndpointClassifier.classify(host) == .publicIPv6
    }

    static func isLocalControlCandidateHost(_ host: NWEndpoint.Host) -> Bool {
        switch MirageEndpointClassifier.classify(host) {
        case .privateLAN, .bonjour:
            true
        case .tailscaleIPv4, .tailscaleIPv6, .tailscaleMagicDNS, .publicIPv6, .unknown:
            false
        }
    }

    /// Returns `true` when the host is an overlay/VPN address (e.g. Tailscale CGNAT).
    static func isOverlayAddress(_ host: NWEndpoint.Host) -> Bool {
        switch MirageEndpointClassifier.classify(host) {
        case .tailscaleIPv4, .tailscaleIPv6:
            true
        case .tailscaleMagicDNS, .privateLAN, .bonjour, .publicIPv6, .unknown:
            false
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
        guard case let .ipv6(addr) = host, isLinkLocalIPv6Address(host) else { return false }
        return addr.interface == nil
    }

    static func isLinkLocalIPv6Address(_ host: NWEndpoint.Host) -> Bool {
        guard case let .ipv6(addr) = host else { return false }
        let raw = addr.rawValue
        guard raw.count >= 2 else { return false }
        return raw[raw.startIndex] == 0xFE &&
            (raw[raw.index(after: raw.startIndex)] & 0xC0) == 0x80
    }

    static func scopedLinkLocalIPv6InterfaceName(_ host: NWEndpoint.Host) -> String? {
        guard case let .ipv6(addr) = host,
              isLinkLocalIPv6Address(host),
              let interface = addr.interface else {
            return nil
        }
        let normalizedName = interface.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName.isEmpty ? nil : normalizedName
    }

    static func isProximityInterfaceName(_ name: String) -> Bool {
        proximityPriority(forInterfaceName: name) != nil
    }

    static func proximityRouteTier(forInterfaceName name: String) -> ControlSessionRouteTier? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("anpi") || normalized.hasPrefix("apni") {
            return .applePrivateNCM
        }
        if normalized.hasPrefix("bridge") {
            return .bridge
        }
        if normalized.hasPrefix("llw") {
            return .lowLatencyWireless
        }
        if normalized.hasPrefix("awdl") {
            return .awdl
        }
        return nil
    }

    static func proximityInterfaceKind(forInterfaceName name: String) -> LoomDiscoveredInterfaceKind? {
        switch proximityRouteTier(forInterfaceName: name) {
        case .applePrivateNCM:
            .applePrivateNCM
        case .bridge:
            .bridge
        case .lowLatencyWireless:
            .lowLatencyWireless
        case .awdl:
            .awdl
        case .sameWiredEthernet, .mixedEthernetSameLAN, .wifiLAN, .vpn, .other, nil:
            nil
        }
    }

    static func proximityInterfaceKind(forRouteTier routeTier: ControlSessionRouteTier) -> LoomDiscoveredInterfaceKind? {
        switch routeTier {
        case .applePrivateNCM:
            .applePrivateNCM
        case .bridge:
            .bridge
        case .lowLatencyWireless:
            .lowLatencyWireless
        case .awdl:
            .awdl
        case .sameWiredEthernet:
            .wiredEthernet
        case .mixedEthernetSameLAN, .wifiLAN, .vpn, .other:
            nil
        }
    }

    static func proximityRouteTier(forEndpointHost host: NWEndpoint.Host) -> ControlSessionRouteTier? {
        guard let interfaceName = scopedLinkLocalIPv6InterfaceName(host) else { return nil }
        return proximityRouteTier(forInterfaceName: interfaceName)
    }

    static func proximityPriority(forInterfaceName name: String) -> Int? {
        proximityRouteTier(forInterfaceName: name)?.rank
    }

    static func isAwdlRadioEndpointHost(_ host: NWEndpoint.Host) -> Bool {
        guard let routeTier = proximityRouteTier(forEndpointHost: host) else {
            return false
        }
        return isAwdlRadioRouteTier(routeTier)
    }

    static func isScopeLessLinkLocalIPv6Name(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.hasPrefix("fe80:") && !trimmed.contains("%")
    }

    /// Temporarily prevents AWDL proximity attempts for one host/interface after active media degradation.
    public func suppressAwdlProximityRoute(
        for host: LoomPeer,
        interfaceNames: [String],
        duration: TimeInterval = 15 * 60,
        reason: String
    ) {
        let normalizedNames = Self.normalizedAwdlSuppressionInterfaceNames(interfaceNames)
        let expiry = CFAbsoluteTimeGetCurrent() + max(1, duration)
        for interfaceName in normalizedNames {
            awdlProximityRouteSuppressions[
                AwdlProximityRouteSuppressionKey(
                    deviceID: host.deviceID,
                    interfaceName: interfaceName
                )
            ] = expiry
        }
        MirageLogger.client(
            "Suppressing AWDL proximity route for \(host.name) " +
                "interfaces=\(normalizedNames.joined(separator: ",")) duration=\(Int(duration))s reason=\(reason)"
        )
    }

    func awdlProximityRouteIsSuppressed(
        for host: LoomPeer,
        interfaceName: String,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        if debugRouteOverride?.interfaceKind?.isPeerToPeerRadio == true {
            return false
        }
        pruneExpiredAwdlProximityRouteSuppressions(now: now)
        let wildcardKey = AwdlProximityRouteSuppressionKey(
            deviceID: host.deviceID,
            interfaceName: Self.awdlSuppressionWildcardInterfaceName
        )
        if awdlProximityRouteSuppressions[wildcardKey] != nil {
            return true
        }

        let normalizedName = Self.normalizedAwdlInterfaceName(interfaceName)
        guard !normalizedName.isEmpty else { return false }
        let key = AwdlProximityRouteSuppressionKey(
            deviceID: host.deviceID,
            interfaceName: normalizedName
        )
        return awdlProximityRouteSuppressions[key] != nil
    }

    func awdlEndpointHostIsSuppressed(
        _ endpointHost: NWEndpoint.Host,
        for host: LoomPeer
    ) -> Bool {
        guard let interfaceName = Self.scopedAwdlRadioInterfaceName(endpointHost) else { return false }
        return awdlProximityRouteIsSuppressed(for: host, interfaceName: interfaceName)
    }

    func pruneExpiredAwdlProximityRouteSuppressions(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard !awdlProximityRouteSuppressions.isEmpty else { return }
        awdlProximityRouteSuppressions = awdlProximityRouteSuppressions.filter { _, expiry in
            expiry > now
        }
    }

    private static let awdlSuppressionWildcardInterfaceName = "*"

    private static func normalizedAwdlSuppressionInterfaceNames(_ interfaceNames: [String]) -> [String] {
        let normalizedNames = Set(interfaceNames.map(normalizedAwdlInterfaceName(_:)).filter { !$0.isEmpty })
        guard !normalizedNames.isEmpty else {
            return [awdlSuppressionWildcardInterfaceName]
        }
        return normalizedNames.sorted()
    }

    private static func normalizedAwdlInterfaceName(_ interfaceName: String) -> String {
        interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func scopedAwdlTransportRestrictedInterfaceName(_ host: NWEndpoint.Host) -> String? {
        guard let interfaceName = scopedAwdlRadioInterfaceName(host) else { return nil }
        return interfaceName.hasPrefix("awdl") ? interfaceName : nil
    }

    private static func scopedAwdlRadioInterfaceName(_ host: NWEndpoint.Host) -> String? {
        if let interfaceName = scopedLinkLocalIPv6InterfaceName(host),
           isAwdlRadioInterfaceName(interfaceName) {
            return interfaceName
        }

        guard case let .name(_, interface) = host,
              let interface else {
            return nil
        }
        let interfaceName = interface.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isAwdlRadioInterfaceName(interfaceName) ? interfaceName : nil
    }

    private static func isAwdlRadioInterfaceName(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("awdl")
    }

    private static func isAwdlRadioRouteTier(_ routeTier: ControlSessionRouteTier) -> Bool {
        routeTier == .awdl
    }
}

private extension MirageDebugRouteOverride {
    func matches(_ attempt: MirageClientService.ControlSessionAttempt) -> Bool {
        guard attempt.transportKind == transportKind else { return false }
        if let interfaceName {
            let normalized = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let names = ([attempt.requiredInterface?.name].compactMap { $0 } + attempt.proximityInterfaceNames)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if !names.isEmpty, !names.contains(normalized) { return false }
        }

        guard let interfaceKind else { return true }
        switch interfaceKind {
        case .awdl:
            return attempt.routeTier == .awdl ||
                attempt.proximityInterfaceKind == .awdl ||
                attempt.proximityInterfaceNames.contains { $0.lowercased().hasPrefix("awdl") } ||
                attempt.requiredInterface.map { $0.name.lowercased().hasPrefix("awdl") } == true
        case .llw:
            return attempt.routeTier == .lowLatencyWireless ||
                attempt.proximityInterfaceKind == .lowLatencyWireless ||
                attempt.proximityInterfaceNames.contains { $0.lowercased().hasPrefix("llw") } ||
                attempt.requiredInterface.map { $0.name.lowercased().hasPrefix("llw") } == true
        case .wifi:
            return attempt.routeTier == .wifiLAN ||
                attempt.requiredInterfaceType == .wifi
        case .wired:
            return attempt.routeTier == .sameWiredEthernet ||
                attempt.routeTier == .mixedEthernetSameLAN ||
                attempt.routeTier == .applePrivateNCM ||
                attempt.routeTier == .bridge ||
                attempt.requiredInterfaceType == .wiredEthernet
        }
    }
}

private extension MirageDebugRouteOverride.InterfaceKind {
    var isPeerToPeerRadio: Bool {
        switch self {
        case .awdl, .llw:
            true
        case .wifi, .wired:
            false
        }
    }
}
