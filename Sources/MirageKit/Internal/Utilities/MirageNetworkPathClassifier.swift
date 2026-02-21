//
//  MirageNetworkPathClassifier.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Path classification helpers used for AWDL transport stabilization.
//

import Foundation
import Network

package enum MirageNetworkPathKind: String, Sendable, Equatable {
    case awdl
    case wifi
    case wired
    case cellular
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

    package var isReady: Bool {
        status == "satisfied"
    }
}

package enum MirageNetworkPathClassifier {
    package static func classify(_ path: NWPath) -> MirageNetworkPathSnapshot {
        let interfaces = path.availableInterfaces.map { $0.name.lowercased() }
        return classify(
            interfaceNames: interfaces,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWired: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesOther: path.usesInterfaceType(.other),
            status: String(describing: path.status),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
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
        supportsIPv6: Bool
    ) -> MirageNetworkPathSnapshot {
        let sortedNames = interfaceNames
            .map { $0.lowercased() }
            .sorted()
        let hasAWDLInterface = sortedNames.contains { $0.hasPrefix("awdl") }
        let kind: MirageNetworkPathKind
        if hasAWDLInterface && usesOther {
            kind = .awdl
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
            "|if=\(sortedNames.joined(separator: ","))" +
            "|exp=\(isExpensive)" +
            "|con=\(isConstrained)" +
            "|v4=\(supportsIPv4)" +
            "|v6=\(supportsIPv6)"

        return MirageNetworkPathSnapshot(
            kind: kind,
            status: status,
            signature: signature,
            interfaceNames: sortedNames,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther
        )
    }
}
