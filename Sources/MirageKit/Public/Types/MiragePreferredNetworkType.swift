//
//  MiragePreferredNetworkType.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

import Network

/// User-selectable preference for which network interface to prioritize during connection.
///
/// When set to a specific type (e.g., `.ethernet`), the connection race pins to that interface.
/// When set to `.automatic`, all available interfaces are raced with staggered starts.
public enum MiragePreferredNetworkType: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Race all eligible network interfaces with the default staggered connection policy.
    case automatic

    /// Prefer wired Ethernet paths.
    case ethernet

    /// Prefer Thunderbolt Bridge paths, represented by Network.framework as wired Ethernet.
    case thunderbolt

    /// Prefer Wi-Fi paths.
    case wifi

    /// Stable identity for SwiftUI controls and persisted selections.
    public var id: String { rawValue }

    /// User-facing label for network preference settings.
    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .ethernet:
            "Wired"
        case .thunderbolt:
            "Thunderbolt Bridge"
        case .wifi:
            "Wi-Fi"
        }
    }

    /// Maps to an `NWInterface.InterfaceType` for connection pinning, or nil for automatic racing.
    public var requiredInterfaceType: NWInterface.InterfaceType? {
        switch self {
        case .automatic:
            nil
        case .ethernet:
            .wiredEthernet
        case .thunderbolt:
            .wiredEthernet
        case .wifi:
            .wifi
        }
    }
}
