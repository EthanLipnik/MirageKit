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
    struct ControlSessionAttempt {
        let hostName: String
        let endpoint: NWEndpoint
        let transportKind: LoomTransportKind
        let candidateKind: ControlSessionCandidateKind
        let requiredInterfaceType: NWInterface.InterfaceType?

        var interfaceDescription: String {
            requiredInterfaceType.map(String.init(describing:)) ?? "any"
        }
    }

    enum ControlSessionCandidateKind: String {
        case local
        case overlay
        case publicIPv6
        case portMapped
        case stun
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
    }

    enum ControlSessionFailureClassification: String {
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

    static func classifyControlSessionFailure(_ error: Error) -> ControlSessionFailureClassification {
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

    static func classifyBootstrappedControlSessionFailure(
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

    static func shouldRetryCurrentBootstrappedControlSessionAttempt(
        classification: ControlSessionFailureClassification,
        controlChannelOpened: Bool,
        hasRetriedCurrentAttempt: Bool
    ) -> Bool {
        guard controlChannelOpened else { return false }
        guard classification == .transportLoss else { return false }
        return !hasRetriedCurrentAttempt
    }

    static func shouldRetryLaterControlSessionAttempt(
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
    static func classifyProtocolErrorReason(_ reason: String) -> ControlSessionFailureClassification? {
        if looksLikeAddressResolutionFailure(reason) {
            return .addressUnavailable
        }
        if looksLikeBootstrapResponseTimeout(reason) {
            return .timeout
        }
        if looksLikeBootstrapTransportFailure(reason) {
            return .transportLoss
        }
        return nil
    }

    static func looksLikeAddressResolutionFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("failed to resolve") ||
            normalized.contains("nodename nor servname provided") ||
            normalized.contains("name or service not known")
    }

    static func looksLikeBootstrapResponseTimeout(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("timed out waiting for host bootstrap response")
    }

    static func looksLikeBootstrapTransportFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("control stream closed before receiving bootstrap response") ||
            normalized.contains("authenticated loom session closed before mirage control stream opened")
    }

    static func classifyLoomConnectionFailure(
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

    static func bootstrappedControlSessionFailureReason(
        for attempt: ControlSessionAttempt,
        classification: ControlSessionFailureClassification,
        underlyingError: Error
    ) -> String {
        "Mirage bootstrap failed for \(attempt.hostName) endpoint=\(attempt.endpoint) " +
            "transport=\(attempt.transportKind.rawValue) candidate=\(attempt.candidateKind.rawValue) " +
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

    static func classifyNetworkFailure(_ error: NWError) -> ControlSessionFailureClassification {
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

    static func classifyPOSIXError(_ code: POSIXErrorCode) -> ControlSessionFailureClassification {
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
