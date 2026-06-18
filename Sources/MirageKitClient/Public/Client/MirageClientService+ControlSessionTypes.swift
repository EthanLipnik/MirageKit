//
//  MirageClientService+ControlSessionTypes.swift
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

        func acceptsProximityPath(_ snapshot: MirageNetworkPathSnapshot) -> Bool {
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
            _ snapshot: MirageNetworkPathSnapshot,
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
            _ snapshot: MirageNetworkPathSnapshot
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
            case .awdl:
                6
            case .vpn:
                7
            case .other:
                8
            }
        }
    }

    struct ControlSessionNetworkDiagnostics: Equatable {
        let currentPathKind: MirageNetworkPathKind
        let wifiSubnetSignatures: [String]
        let wiredSubnetSignatures: [String]

        init(
            currentPathKind: MirageNetworkPathKind,
            wifiSubnetSignatures: [String],
            wiredSubnetSignatures: [String]
        ) {
            self.currentPathKind = currentPathKind
            self.wifiSubnetSignatures = wifiSubnetSignatures
            self.wiredSubnetSignatures = wiredSubnetSignatures
        }

        init(snapshot: MirageLocalNetworkSnapshot) {
            self.init(
                currentPathKind: snapshot.currentPathKind,
                wifiSubnetSignatures: snapshot.wifiSubnetSignatures,
                wiredSubnetSignatures: snapshot.wiredSubnetSignatures
            )
        }

        var allSubnetSignatures: Set<String> {
            MirageLocalNetworkSnapshot.subnetSignatureSet(
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
        case hostIdentityMismatch
        case cancelled
        case other

        var shouldRetryLaterDirectAttempt: Bool {
            switch self {
            case .timeout, .transportLoss, .connectionRefused, .addressUnavailable:
                true
            case .hostIdentityMismatch, .cancelled, .other:
                false
            }
        }
    }

    nonisolated static func classifyControlSessionFailure(_ error: Error) -> ControlSessionFailureClassification {
        if error is CancellationError {
            return .cancelled
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case .timeout:
                return .timeout
            case let .protocolError(reason):
                return classifyProtocolErrorReason(reason) ?? .other
            case let .connectionFailed(underlyingError):
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case .timeout:
                return .timeout
            case let .protocolError(reason):
                return classifyProtocolErrorReason(reason) ?? .other
            case let .connectionFailed(underlyingError):
                if let failure = underlyingError as? LoomConnectionFailure {
                    return classifyLoomConnectionFailure(failure)
                }
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let nwError = error as? NWError {
            return classifyNetworkFailure(nwError)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classifyPOSIXError(code)
        }

        return .other
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

    /// Classifies human-readable protocol errors produced before typed failure details are available.
    nonisolated static func classifyProtocolErrorReason(_ reason: String) -> ControlSessionFailureClassification? {
        if looksLikeProximityPathValidationFailure(reason) {
            return .transportLoss
        }
        if looksLikeAddressResolutionFailure(reason) {
            return .addressUnavailable
        }
        if looksLikeBootstrapResponseTimeout(reason) {
            return .timeout
        }
        if looksLikeBootstrapTransportFailure(reason) {
            return .transportLoss
        }
        if looksLikeHostIdentityMismatch(reason) {
            return .hostIdentityMismatch
        }
        return nil
    }

    nonisolated static func looksLikeProximityPathValidationFailure(_ reason: String) -> Bool {
        reason.lowercased().contains("proximity path validation failed")
    }

    nonisolated static func looksLikeAddressResolutionFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("failed to resolve") ||
            normalized.contains("nodename nor servname provided") ||
            normalized.contains("name or service not known")
    }

    nonisolated static func looksLikeBootstrapResponseTimeout(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("timed out waiting for host bootstrap response")
    }

    nonisolated static func looksLikeBootstrapTransportFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("control stream closed before receiving bootstrap response") ||
            normalized.contains("authenticated loom session closed before mirage control stream opened")
    }

    nonisolated static func looksLikeHostIdentityMismatch(_ reason: String) -> Bool {
        reason.lowercased().contains("host identity mismatch")
    }

    nonisolated static func classifyLoomConnectionFailure(
        _ failure: LoomConnectionFailure
    ) -> ControlSessionFailureClassification {
        switch failure.reason {
        case .timedOut:
            .timeout
        case .transportLoss, .closed:
            .transportLoss
        case .connectionRefused:
            .connectionRefused
        case .addressUnavailable:
            .addressUnavailable
        case .cancelled:
            .cancelled
        case .other:
            .other
        }
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
        case .connectionRefused, .hostIdentityMismatch, .cancelled, .other:
            return nil
        }

        let hostNetwork = MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
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

    nonisolated static func classifyNetworkFailure(_ error: NWError) -> ControlSessionFailureClassification {
        switch error {
        case let .posix(code):
            return classifyPOSIXError(code)
        case .dns:
            return .addressUnavailable
        case .tls:
            return .other
        case .wifiAware:
            return .other
        @unknown default:
            return .other
        }
    }

    nonisolated static func classifyPOSIXError(_ code: POSIXErrorCode) -> ControlSessionFailureClassification {
        switch code {
        case .ETIMEDOUT:
            .timeout
        case .ECONNREFUSED:
            .connectionRefused
        case .EADDRNOTAVAIL:
            .addressUnavailable
        case .ENETDOWN,
             .ENETUNREACH,
             .EHOSTDOWN,
             .EHOSTUNREACH,
             .ENETRESET,
             .ECONNABORTED,
             .ECONNRESET,
             .ENOTCONN,
             .EPIPE:
            .transportLoss
        case .ECANCELED:
            .cancelled
        default:
            .other
        }
    }
}
