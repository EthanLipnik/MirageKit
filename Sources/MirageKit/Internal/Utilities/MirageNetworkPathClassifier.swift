//
//  MirageNetworkPathClassifier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Path classification helpers used for AWDL transport stabilization.
//

import Foundation
import Loom
import Network

public enum MirageNetworkPathKind: String, Codable, Sendable, Equatable {
    case awdl
    case wifi
    case wired
    case cellular
    case vpn
    case loopback
    case other
    case unknown
}

package struct MirageNetworkPathSnapshot: Sendable, Equatable {
    package let kind: MirageNetworkPathKind
    package let mediaProfile: MirageMediaPathProfile
    package let status: String
    package let signature: String
    package let interfaceNames: [String]
    package let isExpensive: Bool
    package let isConstrained: Bool
    package let supportsIPv4: Bool
    package let supportsIPv6: Bool
    package let usesWiFi: Bool
    package let usesWired: Bool
    package let usesCellular: Bool
    package let usesLoopback: Bool
    package let usesOther: Bool
    package let localEndpointDescription: String?
    package let remoteEndpointDescription: String?
}

package enum MirageNetworkPathClassifier {
    package static func classify(_ snapshot: LoomSessionNetworkPathSnapshot) -> MirageNetworkPathSnapshot {
        classify(
            interfaceNames: snapshot.interfaceNames,
            usesWiFi: snapshot.usesWiFi,
            usesWired: snapshot.usesWiredEthernet,
            usesCellular: snapshot.usesCellular,
            usesLoopback: snapshot.usesLoopback,
            usesOther: snapshot.usesOther,
            status: snapshot.status.rawValue,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained,
            supportsIPv4: snapshot.supportsIPv4,
            supportsIPv6: snapshot.supportsIPv6,
            localEndpointDescription: endpointDescription(snapshot.localEndpoint),
            remoteEndpointDescription: endpointDescription(snapshot.remoteEndpoint)
        )
    }

    package static func classifyLocalDefaultRouteKind(
        interfaceNames: [String],
        usesWiFi: Bool,
        usesWired: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool
    ) -> MirageNetworkPathKind {
        let interfaces = InterfaceSummary(interfaceNames)

        if usesWiFi && (interfaces.hasNonProximityRouteInterface || !interfaces.hasProximity) {
            return .wifi
        }
        if usesWired {
            return .wired
        }
        if interfaces.hasApplePrivateNCM || interfaces.hasLowLatencyWireless || interfaces.hasBridge {
            return .wired
        }
        if interfaces.hasAWDL {
            return .awdl
        }
        if usesCellular {
            return .cellular
        }
        if usesLoopback {
            return .loopback
        }
        if interfaces.hasOverlay {
            return .vpn
        }
        if usesOther {
            return .other
        }
        return .unknown
    }

    package static func classify(
        interfaceNames: [String],
        usesWiFi: Bool,
        usesWired: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool,
        status: String,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        localEndpointDescription: String? = nil,
        remoteEndpointDescription: String? = nil
    ) -> MirageNetworkPathSnapshot {
        let interfaces = InterfaceSummary(interfaceNames)
        let kind: MirageNetworkPathKind
        if interfaces.hasOverlay {
            kind = .vpn
        } else if usesWiFi && (interfaces.hasNonProximityRouteInterface || !interfaces.hasProximity) {
            kind = .wifi
        } else if usesWired {
            kind = .wired
        } else if interfaces.hasProximity {
            kind = .awdl
        } else if usesCellular {
            kind = .cellular
        } else if usesLoopback {
            kind = .loopback
        } else if interfaces.hasBridge {
            kind = .wired
        } else if usesOther {
            kind = .other
        } else {
            kind = .unknown
        }
        let mediaProfile = MirageMediaPathProfile.classify(
            pathKind: kind,
            interfaceNames: interfaces.names,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther
        )

        let signature =
            "status=\(status)" +
            "|kind=\(kind.rawValue)" +
            "|media=\(mediaProfile.rawValue)" +
            "|if=\(interfaces.names.joined(separator: ","))" +
            "|exp=\(isExpensive)" +
            "|con=\(isConstrained)" +
            "|v4=\(supportsIPv4)" +
            "|v6=\(supportsIPv6)" +
            "|local=\(localEndpointDescription ?? "-")" +
            "|remote=\(remoteEndpointDescription ?? "-")"

        return MirageNetworkPathSnapshot(
            kind: kind,
            mediaProfile: mediaProfile,
            status: status,
            signature: signature,
            interfaceNames: interfaces.names,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            localEndpointDescription: localEndpointDescription,
            remoteEndpointDescription: remoteEndpointDescription
        )
    }

    /// Normalizes Network.framework interface names before path-specific classification.
    private struct InterfaceSummary {
        let names: [String]
        let hasApplePrivateNCM: Bool
        let hasAWDL: Bool
        let hasLowLatencyWireless: Bool
        let hasBridge: Bool
        let hasOverlay: Bool
        let hasProximity: Bool
        let hasNonProximityRouteInterface: Bool

        init(_ interfaceNames: [String]) {
            names = interfaceNames
                .map { $0.lowercased() }
                .sorted()
            hasApplePrivateNCM = names.contains {
                $0.hasPrefix("anpi") || $0.hasPrefix("apni")
            }
            hasAWDL = names.contains { $0.hasPrefix("awdl") }
            hasLowLatencyWireless = names.contains { $0.hasPrefix("llw") }
            hasBridge = names.contains { $0.hasPrefix("bridge") }
            hasOverlay = names.contains { $0.hasPrefix("utun") }
            hasProximity = hasApplePrivateNCM || hasAWDL || hasLowLatencyWireless
            hasNonProximityRouteInterface = names.contains {
                !$0.hasPrefix("anpi") &&
                    !$0.hasPrefix("apni") &&
                    !$0.hasPrefix("awdl") &&
                    !$0.hasPrefix("llw") &&
                    !$0.hasPrefix("utun") &&
                    !$0.hasPrefix("bridge")
            }
        }
    }

    private static func endpointDescription(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }

        switch endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        case let .service(name, type, domain, interface):
            let base = [name, type, domain]
                .filter { !$0.isEmpty }
                .joined(separator: ".")
            guard let interface else {
                return base.isEmpty ? endpoint.debugDescription : base
            }
            return base.isEmpty ? "@\(interface.name)" : "\(base)@\(interface.name)"
        case let .unix(path):
            return path
        default:
            return endpoint.debugDescription
        }
    }
}
