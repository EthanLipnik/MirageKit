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

public enum MirageNetworkPathKind: String, Sendable, Equatable {
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

        if usesWiFi {
            return .wifi
        }
        if usesWired {
            return .wired
        }
        if usesCellular {
            return .cellular
        }
        if usesLoopback {
            return .loopback
        }
        if interfaces.hasAWDL {
            return .awdl
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
        if interfaces.hasAWDL {
            kind = .awdl
        } else if interfaces.hasOverlay {
            kind = .vpn
        } else if usesWiFi {
            kind = .wifi
        } else if usesWired {
            kind = .wired
        } else if usesCellular {
            kind = .cellular
        } else if usesLoopback {
            kind = .loopback
        } else if usesOther {
            kind = .other
        } else {
            kind = .unknown
        }

        let signature =
            "status=\(status)" +
            "|kind=\(kind.rawValue)" +
            "|if=\(interfaces.names.joined(separator: ","))" +
            "|exp=\(isExpensive)" +
            "|con=\(isConstrained)" +
            "|v4=\(supportsIPv4)" +
            "|v6=\(supportsIPv6)" +
            "|local=\(localEndpointDescription ?? "-")" +
            "|remote=\(remoteEndpointDescription ?? "-")"

        return MirageNetworkPathSnapshot(
            kind: kind,
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
        let hasAWDL: Bool
        let hasOverlay: Bool

        init(_ interfaceNames: [String]) {
            names = interfaceNames
                .map { $0.lowercased() }
                .sorted()
            hasAWDL = names.contains { $0.hasPrefix("awdl") }
            hasOverlay = names.contains { $0.hasPrefix("utun") }
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
