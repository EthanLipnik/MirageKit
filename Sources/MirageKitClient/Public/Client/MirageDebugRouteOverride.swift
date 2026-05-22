//
//  MirageDebugRouteOverride.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Foundation
import Loom

/// Debug-only route forcing used by Mirage clients to pin a connection attempt
/// to a specific transport and interface family.
public struct MirageDebugRouteOverride: Sendable, Codable, Equatable {
    public enum InterfaceKind: String, Sendable, Codable, CaseIterable {
        case awdl
        case wifi
        case wired
    }

    public let transportKind: LoomTransportKind
    public let interfaceKind: InterfaceKind?
    public let interfaceName: String?

    public init(
        transportKind: LoomTransportKind,
        interfaceKind: InterfaceKind? = nil,
        interfaceName: String? = nil
    ) {
        self.transportKind = transportKind
        self.interfaceKind = interfaceKind
        self.interfaceName = interfaceName
    }

    public var displayName: String {
        let route = interfaceName ?? interfaceKind?.rawValue.uppercased() ?? "Any"
        return "\(route) \(transportKind.rawValue.uppercased())"
    }
}
