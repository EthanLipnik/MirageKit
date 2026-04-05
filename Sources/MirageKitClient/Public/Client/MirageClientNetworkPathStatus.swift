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
    public let localEndpointDescription: String?
    public let remoteEndpointDescription: String?

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
        usesOther: Bool,
        localEndpointDescription: String? = nil,
        remoteEndpointDescription: String? = nil
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
        self.localEndpointDescription = localEndpointDescription
        self.remoteEndpointDescription = remoteEndpointDescription
    }

    public var displayName: String {
        if interfaceNames.contains(where: Self.isAWDLInterface(_:)) {
            return "AWDL"
        }
        if interfaceNames.contains(where: Self.isThunderboltBridgeInterface(_:)) {
            return "Thunderbolt Bridge"
        }
        if interfaceNames.contains(where: Self.isOverlayInterface(_:)) {
            return "VPN / Overlay"
        }
        return switch kind {
        case .wifi:
            "Wi-Fi"
        case .wired:
            "Wired"
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

    public var primaryInterfaceName: String? {
        interfaceNames.first
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

    public var interfaceTypeSummary: String {
        var flags: [String] = []

        if usesWiFi {
            flags.append("Wi-Fi")
        }
        if usesWired {
            flags.append("Wired")
        }
        if usesCellular {
            flags.append("Cellular")
        }
        if usesLoopback {
            flags.append("Loopback")
        }
        if usesOther {
            flags.append("Other")
        }

        return flags.isEmpty ? "None" : flags.joined(separator: " + ")
    }

    public var transportDiagnosticNote: String? {
        if interfaceNames.contains(where: Self.isAWDLInterface(_:)) {
            return "The active control path exposes an AWDL interface, which is Apple's peer-to-peer transport."
        }
        if interfaceNames.contains(where: Self.isThunderboltBridgeInterface(_:)) {
            return "The active control path is using a Thunderbolt Bridge-style interface."
        }
        if interfaceNames.contains(where: Self.isOverlayInterface(_:)) {
            return "The active control path is using a tunnel or overlay interface."
        }
        if kind == .wired, usesWired {
            return "The active control path is using a generic wired path classification."
        }
        return nil
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
            usesOther: snapshot.usesOther,
            localEndpointDescription: snapshot.localEndpointDescription,
            remoteEndpointDescription: snapshot.remoteEndpointDescription
        )
    }

    private static func isAWDLInterface(_ name: String) -> Bool {
        normalizedInterfaceName(name).hasPrefix("awdl")
    }

    private static func isThunderboltBridgeInterface(_ name: String) -> Bool {
        let normalized = normalizedInterfaceName(name)
        return normalized.contains("thunderbolt") || normalized.contains("bridge")
    }

    private static func isOverlayInterface(_ name: String) -> Bool {
        normalizedInterfaceName(name).hasPrefix("utun")
    }

    private static func normalizedInterfaceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct MirageClientNetworkPathHistoryEntry: Sendable, Equatable, Identifiable {
    public let observedAt: Date
    public let status: MirageClientNetworkPathStatus

    public var id: String {
        let timestamp = Int(observedAt.timeIntervalSince1970 * 1000)
        let interfaceText = status.interfaceNames.joined(separator: ",")
        return "\(timestamp)|\(status.kind.rawValue)|\(status.status)|\(interfaceText)"
    }

    public init(
        observedAt: Date,
        status: MirageClientNetworkPathStatus
    ) {
        self.observedAt = observedAt
        self.status = status
    }
}
