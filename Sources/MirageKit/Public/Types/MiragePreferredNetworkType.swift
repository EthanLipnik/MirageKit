//
//  MiragePreferredNetworkType.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

import Foundation
import Network

/// User-selectable preference for which network interface to prioritize during connection.
///
/// When set to a specific type (e.g., `.ethernet`), the connection race pins to that interface.
/// When set to `.automatic`, all available interfaces are raced with staggered starts.
public enum MiragePreferredNetworkType: String, Sendable, Codable, CaseIterable, Identifiable {
    case automatic
    case ethernet
    case thunderbolt
    case wifi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .ethernet:
            "Ethernet"
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
