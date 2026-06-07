//
//  MirageClientService+ControlSessionTypes.swift
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

@MainActor
extension MirageClientService {
    struct ControlSessionAttempt: @unchecked Sendable {
        let hostName: String
        let endpoint: NWEndpoint
        let transportKind: LoomTransportKind
        let candidateKind: ControlSessionCandidateKind
        let routeTier: ControlSessionRouteTier
        let endpointSource: String
        let requiredInterface: NWInterface?
        let requiredInterfaceType: NWInterface.InterfaceType?
        let isPeerToPeerPreferred: Bool
        let proximityInterfaceKind: LoomDiscoveredInterfaceKind?
        let proximityInterfaceNames: [String]

        var interfaceDescription: String {
            if let requiredInterface {
                return requiredInterface.name
            }
            if isPeerToPeerPreferred {
                return proximityDescription
            }
            return requiredInterfaceType.map(String.init(describing:)) ?? "any"
        }

        var requiresProximityPathValidation: Bool {
            isPeerToPeerPreferred
        }

        var proximityDescription: String {
            let names = proximityInterfaceNames
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            if let proximityInterfaceKind {
                if names.isEmpty {
                    return "proximity-\(proximityInterfaceKind.rawValue)"
                }
                return "\(names)(\(proximityInterfaceKind.rawValue))"
            }
            return names.isEmpty ? "proximity" : names
        }

        init(
            hostName: String,
            endpoint: NWEndpoint,
            transportKind: LoomTransportKind,
            candidateKind: ControlSessionCandidateKind,
            routeTier: ControlSessionRouteTier? = nil,
            endpointSource: String = "automatic",
            requiredInterface: NWInterface? = nil,
            requiredInterfaceType: NWInterface.InterfaceType? = nil,
            isPeerToPeerPreferred: Bool = false,
            proximityInterfaceKind: LoomDiscoveredInterfaceKind? = nil,
            proximityInterfaceNames: [String] = []
        ) {
            self.hostName = hostName
            self.endpoint = endpoint
            self.transportKind = transportKind
            self.candidateKind = candidateKind
            self.routeTier = routeTier ?? Self.defaultRouteTier(candidateKind: candidateKind)
            self.endpointSource = endpointSource
            self.requiredInterface = requiredInterface
            self.requiredInterfaceType = requiredInterfaceType
            self.isPeerToPeerPreferred = isPeerToPeerPreferred
            self.proximityInterfaceKind = proximityInterfaceKind
            self.proximityInterfaceNames = proximityInterfaceNames
        }

        private static func defaultRouteTier(
            candidateKind: ControlSessionCandidateKind
        ) -> ControlSessionRouteTier {
            switch candidateKind {
            case .overlay:
                .vpn
            case .local:
                .wifiLAN
            case .publicIPv6, .portMapped, .stun:
                .other
            }
        }

        func acceptsProximityPath(_ snapshot: MirageConnectivity.MirageNetworkPathSnapshot) -> Bool {
            guard requiresProximityPathValidation else { return true }

            let normalizedNames = Set(snapshot.interfaceNames.map(Self.normalizedInterfaceName(_:)))
            let expectedNames = proximityInterfaceNames
                .map(Self.normalizedInterfaceName(_:))
                .filter { !$0.isEmpty }
            if !expectedNames.isEmpty {
                guard expectedNames.contains(where: { normalizedNames.contains($0) }) else {
                    return false
                }
                if let proximityInterfaceKind {
                    return Self.path(snapshot, matches: proximityInterfaceKind)
                }
                return true
            }

            if let proximityInterfaceKind {
                return Self.path(snapshot, matches: proximityInterfaceKind)
            }

            return Self.pathUsesAnyPreferredProximityInterface(snapshot)
        }

        private static func path(
            _ snapshot: MirageConnectivity.MirageNetworkPathSnapshot,
            matches kind: LoomDiscoveredInterfaceKind
        ) -> Bool {
            let names = snapshot.interfaceNames.map(normalizedInterfaceName(_:))
            switch kind {
            case .applePrivateNCM:
                return names.contains { $0.hasPrefix("anpi") || $0.hasPrefix("apni") }
            case .awdl:
                return names.contains { $0.hasPrefix("awdl") }
            case .lowLatencyWireless:
                return names.contains { $0.hasPrefix("llw") }
            case .wiredEthernet:
                return snapshot.usesWired
            case .bridge:
                return names.contains { $0.hasPrefix("bridge") }
            case .wifi, .cellular, .loopback, .overlay, .other:
                return false
            }
        }

        private static func pathUsesAnyPreferredProximityInterface(
            _ snapshot: MirageConnectivity.MirageNetworkPathSnapshot
        ) -> Bool {
            let names = snapshot.interfaceNames.map(normalizedInterfaceName(_:))
            if names.contains(where: { name in
                name.hasPrefix("anpi") ||
                    name.hasPrefix("apni") ||
                    name.hasPrefix("awdl") ||
                    name.hasPrefix("llw") ||
                    name.hasPrefix("bridge")
            }) {
                return true
            }

            return snapshot.usesWired && !snapshot.usesWiFi && !snapshot.usesCellular
        }

        private static func normalizedInterfaceName(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    enum ControlSessionCandidateKind: String {
        case local
        case overlay
        case publicIPv6
        case portMapped
        case stun
    }

    enum ControlSessionRouteTier: String, Sendable {
        case applePrivateNCM = "anpi"
        case bridge
        case lowLatencyWireless = "llw"
        case sameWiredEthernet = "same-wired-ethernet"
        case awdl
        case mixedEthernetSameLAN = "mixed-ethernet-same-lan"
        case wifiLAN = "wifi-lan"
        case vpn
        case other

        var rank: Int {
            switch self {
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
    }

    struct ControlSessionNetworkDiagnostics: Equatable {
        let currentPathKind: MirageCore.MirageNetworkPathKind
        let wifiSubnetSignatures: [String]
        let wiredSubnetSignatures: [String]

        init(
            currentPathKind: MirageCore.MirageNetworkPathKind,
            wifiSubnetSignatures: [String],
            wiredSubnetSignatures: [String]
        ) {
            self.currentPathKind = currentPathKind
            self.wifiSubnetSignatures = wifiSubnetSignatures
            self.wiredSubnetSignatures = wiredSubnetSignatures
        }

        init(snapshot: MirageConnectivity.MirageLocalNetworkSnapshot) {
            self.init(
                currentPathKind: snapshot.currentPathKind,
                wifiSubnetSignatures: snapshot.wifiSubnetSignatures,
                wiredSubnetSignatures: snapshot.wiredSubnetSignatures
            )
        }

        var allSubnetSignatures: Set<String> {
            MirageConnectivity.MirageLocalNetworkSnapshot.subnetSignatureSet(
                wifiSubnetSignatures: wifiSubnetSignatures,
                wiredSubnetSignatures: wiredSubnetSignatures
            )
        }

        var hasWiFiEvidence: Bool {
            !wifiSubnetSignatures.isEmpty
        }

        var hasWiredEvidence: Bool {
            !wiredSubnetSignatures.isEmpty
        }
    }

    struct AwdlProximityRouteSuppressionKey: Hashable {
        let deviceID: UUID
        let interfaceName: String
    }

    enum ControlSessionFailureClassification: String, Sendable {
        case timeout
        case transportLoss
        case connectionRefused
        case addressUnavailable
        case cancelled
        case other

        var shouldRetryLaterDirectAttempt: Bool {
            switch self {
            case .timeout, .transportLoss, .connectionRefused, .addressUnavailable:
                true
            case .cancelled, .other:
                false
            }
        }
    }

    nonisolated static func classifyControlSessionFailure(_ error: Error) -> ControlSessionFailureClassification {
        ControlSessionFailureClassification(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(error)
        )
    }

    nonisolated static func classifyBootstrappedControlSessionFailure(
        _ error: Error,
        isCurrentAttempt: Bool,
        taskIsCancelled: Bool
    ) -> ControlSessionFailureClassification? {
        guard isCurrentAttempt, !taskIsCancelled else {
            return nil
        }

        let classification = classifyControlSessionFailure(error)
        if classification == .cancelled {
            return .transportLoss
        }
        return classification
    }

    nonisolated static func shouldRetryCurrentBootstrappedControlSessionAttempt(
        classification: ControlSessionFailureClassification,
        controlChannelOpened: Bool,
        hasRetriedCurrentAttempt: Bool
    ) -> Bool {
        guard controlChannelOpened else { return false }
        guard classification == .transportLoss else { return false }
        return !hasRetriedCurrentAttempt
    }

    nonisolated static func shouldRetryLaterControlSessionAttempt(
        classification: ControlSessionFailureClassification,
        attempts: [ControlSessionAttempt],
        currentAttemptIndex: Int
    ) -> Bool {
        guard classification.shouldRetryLaterDirectAttempt else {
            return false
        }
        return attempts.indices.contains(currentAttemptIndex + 1)
    }

    nonisolated static func bootstrappedControlSessionFailureReason(
        for attempt: ControlSessionAttempt,
        classification: ControlSessionFailureClassification,
        underlyingError: Error
    ) -> String {
        "Mirage bootstrap failed for \(attempt.hostName) endpoint=\(attempt.endpoint) " +
            "transport=\(attempt.transportKind.rawValue) candidate=\(attempt.candidateKind.rawValue) " +
            "route=\(attempt.routeTier.rawValue) source=\(attempt.endpointSource) " +
            "interface=\(attempt.interfaceDescription) " +
            "classification=\(classification.rawValue) error=\(underlyingError.localizedDescription)"
    }

    static func localNetworkMismatchReason(
        for host: LoomPeer,
        classification: ControlSessionFailureClassification,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> String? {
        switch classification {
        case .timeout, .transportLoss, .addressUnavailable:
            break
        case .connectionRefused, .cancelled, .other:
            return nil
        }

        let hostNetwork = MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
            from: host.advertisement
        )
        guard localNetwork.currentPathKind != .awdl,
              !localNetwork.allSubnetSignatures.isEmpty,
              !hostNetwork.allSubnetSignatures.isEmpty else {
            return nil
        }

        let localWiFi = Set(localNetwork.wifiSubnetSignatures)
        let localWired = Set(localNetwork.wiredSubnetSignatures)
        let hostWiFi = Set(hostNetwork.wifiSubnetSignatures)
        let anyOverlap = !localNetwork.allSubnetSignatures.intersection(hostNetwork.allSubnetSignatures).isEmpty

        switch localNetwork.currentPathKind {
        case .wifi:
            if !localWiFi.isEmpty,
               !hostWiFi.isEmpty,
               localWiFi.intersection(hostWiFi).isEmpty {
                return "The host and client appear to be on different Wi-Fi networks. Use the same Wi-Fi network, VPN Access, or turn on Proximity Connect in Network settings."
            }
            if !anyOverlap {
                return "The host and client appear to be on different local networks. Use the same LAN, VPN Access, or turn on Proximity Connect in Network settings."
            }
        case .wired:
            if !localWired.isEmpty,
               localWired.intersection(hostNetwork.allSubnetSignatures).isEmpty {
                return "The host and client do not appear to be on the same wired network. Check that both devices are on the same subnet or VLAN."
            }
        case .cellular, .vpn, .loopback, .other, .unknown, .awdl:
            break
        }

        return nil
    }
}

private extension MirageClientService.ControlSessionFailureClassification {
    init(_ classification: MirageControlSessionFailureClassification) {
        switch classification {
        case .timeout:
            self = .timeout
        case .transportLoss:
            self = .transportLoss
        case .connectionRefused:
            self = .connectionRefused
        case .addressUnavailable:
            self = .addressUnavailable
        case .cancelled:
            self = .cancelled
        case .other:
            self = .other
        }
    }
}
