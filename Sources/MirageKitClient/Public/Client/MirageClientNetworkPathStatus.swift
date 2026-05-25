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
    /// High-level path kind inferred from Network.framework state and interface hints.
    public let kind: MirageNetworkPathKind
    /// Internal media behavior profile derived from the path kind and concrete interface hints.
    package let mediaProfile: MirageMediaPathProfile
    /// Raw path status label.
    public let status: String
    /// Interface names observed on the active path.
    public let interfaceNames: [String]
    /// Whether the path is marked expensive by the system.
    public let isExpensive: Bool
    /// Whether the path is marked constrained by the system.
    public let isConstrained: Bool
    /// Whether the path supports IPv4.
    public let supportsIPv4: Bool
    /// Whether the path supports IPv6.
    public let supportsIPv6: Bool
    /// Whether the path uses Wi-Fi.
    public let usesWiFi: Bool
    /// Whether the path uses a wired interface.
    public let usesWired: Bool
    /// Whether the path uses cellular.
    public let usesCellular: Bool
    /// Whether the path uses loopback.
    public let usesLoopback: Bool
    /// Whether the path uses another interface type.
    public let usesOther: Bool
    /// Local control-channel endpoint description, when known.
    public let localEndpointDescription: String?
    /// Remote control-channel endpoint description, when known.
    public let remoteEndpointDescription: String?

    /// Creates a public control-channel path snapshot.
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
        mediaProfile = MirageMediaPathProfile.classify(
            pathKind: kind,
            interfaceNames: interfaceNames,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther
        )
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

    /// User-facing path type label.
    public var displayName: String {
        if let interfaceKind = interfaceOverrideKind {
            return interfaceKind.displayName
        }
        return switch kind {
        case .wifi:
            "Wi-Fi"
        case .wired:
            "Wired"
        case .cellular:
            "Cellular"
        case .vpn:
            "VPN / Overlay"
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

    /// Comma-separated interface-name summary.
    public var interfaceSummary: String {
        if interfaceNames.isEmpty {
            return "unknown"
        }
        return interfaceNames.joined(separator: ", ")
    }

    /// First observed interface name, if any.
    public var primaryInterfaceName: String? {
        interfaceNames.first
    }

    /// Summary of IP protocol support on the active path.
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

    /// Summary of interface categories used by the active path.
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

    /// Extra explanation for path classifications that are easy to misread.
    public var transportDiagnosticNote: String? {
        if let interfaceKind = interfaceOverrideKind {
            return interfaceKind.diagnosticNote
        }
        if kind == .wired, usesWired {
            return "The active control path is using a generic wired path classification."
        }
        return nil
    }

    /// Whether the active path uses a fixed realtime-display policy instead of user-selectable latency modes.
    public var usesFixedRealtimeDisplayPolicy: Bool {
        mediaProfile.usesAwdlRadioPolicy
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

    /// Interface names can be more specific than `NWPath` interface categories.
    private var interfaceOverrideKind: InterfaceOverrideKind? {
        for interfaceName in interfaceNames {
            let normalized = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.hasPrefix("anpi") {
                return .applePrivateNCM
            }
            if normalized.hasPrefix("awdl") {
                return .awdl
            }
            if normalized.hasPrefix("llw") {
                return .lowLatencyWireless
            }
            if normalized.contains("thunderbolt") || normalized.contains("bridge") {
                return .thunderboltBridge
            }
            if normalized.hasPrefix("utun") {
                return .overlay
            }
        }
        return nil
    }

    private enum InterfaceOverrideKind {
        case applePrivateNCM
        case awdl
        case lowLatencyWireless
        case thunderboltBridge
        case overlay

        var displayName: String {
            switch self {
            case .applePrivateNCM:
                "USB-C Proximity"
            case .awdl:
                "AWDL"
            case .lowLatencyWireless:
                "Low-Latency Wireless"
            case .thunderboltBridge:
                "Thunderbolt Bridge"
            case .overlay:
                "VPN / Overlay"
            }
        }

        var diagnosticNote: String {
            switch self {
            case .applePrivateNCM:
                "The active control path is using an Apple private USB-C proximity interface."
            case .awdl:
                "The active control path is using Proximity Connect over Apple's AWDL transport."
            case .lowLatencyWireless:
                "The active control path is using Apple's low-latency wireless interface."
            case .thunderboltBridge:
                "The active control path is using a Thunderbolt Bridge-style interface."
            case .overlay:
                "The active control path is using a tunnel or overlay interface."
            }
        }
    }

}

/// One observed control-channel path snapshot in client path history.
public struct MirageClientNetworkPathHistoryEntry: Sendable, Equatable, Identifiable {
    /// Time this path snapshot was observed.
    public let observedAt: Date
    /// Path status captured at `observedAt`.
    public let status: MirageClientNetworkPathStatus

    /// Stable identity derived from timestamp and path signature.
    public var id: String {
        let timestamp = Int(observedAt.timeIntervalSince1970 * 1000)
        let interfaceText = status.interfaceNames.joined(separator: ",")
        return "\(timestamp)|\(status.kind.rawValue)|\(status.status)|\(interfaceText)"
    }

    /// Creates one observed control-path history entry.
    public init(
        observedAt: Date,
        status: MirageClientNetworkPathStatus
    ) {
        self.observedAt = observedAt
        self.status = status
    }
}
