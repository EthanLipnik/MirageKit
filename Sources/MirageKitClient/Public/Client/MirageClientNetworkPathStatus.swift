//
//  MirageClientNetworkPathStatus.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import Foundation
import MirageKit

/// Public snapshot of the current control-channel network path.
public struct MirageClientNetworkPathStatus: Sendable, Equatable {
    public let kind: MirageNetworkPathKind
    public let status: String
    public let interfaceNames: [String]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let usesWiFi: Bool
    public let usesWired: Bool
    public let usesCellular: Bool
    public let usesLoopback: Bool
    public let usesOther: Bool

    public init(
        kind: MirageNetworkPathKind,
        status: String,
        interfaceNames: [String],
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        usesWiFi: Bool,
        usesWired: Bool,
        usesCellular: Bool,
        usesLoopback: Bool,
        usesOther: Bool
    ) {
        self.kind = kind
        self.status = status
        self.interfaceNames = interfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.usesWiFi = usesWiFi
        self.usesWired = usesWired
        self.usesCellular = usesCellular
        self.usesLoopback = usesLoopback
        self.usesOther = usesOther
    }

    public var displayName: String {
        if kind == .awdl {
            return "AWDL"
        }
        if interfaceNames.contains(where: Self.isThunderboltBridgeInterface(_:)) {
            return "Thunderbolt Bridge"
        }
        return switch kind {
        case .wifi:
            "Wi-Fi"
        case .wired:
            "Ethernet"
        case .cellular:
            "Cellular"
        case .loopback:
            "Loopback"
        case .other:
            "Other"
        case .unknown:
            "Unknown"
        case .awdl:
            "AWDL"
        }
    }

    public var interfaceSummary: String {
        if interfaceNames.isEmpty {
            return "unknown"
        }
        return interfaceNames.joined(separator: ", ")
    }

    public var protocolSummary: String {
        switch (supportsIPv4, supportsIPv6) {
        case (true, true):
            "IPv4 + IPv6"
        case (true, false):
            "IPv4"
        case (false, true):
            "IPv6"
        case (false, false):
            "none"
        }
    }

    package init(snapshot: MirageNetworkPathSnapshot) {
        self.init(
            kind: snapshot.kind,
            status: snapshot.status,
            interfaceNames: snapshot.interfaceNames,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained,
            supportsIPv4: snapshot.supportsIPv4,
            supportsIPv6: snapshot.supportsIPv6,
            usesWiFi: snapshot.usesWiFi,
            usesWired: snapshot.usesWired,
            usesCellular: snapshot.usesCellular,
            usesLoopback: snapshot.usesLoopback,
            usesOther: snapshot.usesOther
        )
    }

    private static func isThunderboltBridgeInterface(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("thunderbolt") || normalized.contains("bridge")
    }
}
