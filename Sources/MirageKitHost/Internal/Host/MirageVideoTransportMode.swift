//
//  MirageVideoTransportMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/26/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Internal transport contract for dependency-coded video packets.
enum MirageVideoTransportMode: Sendable, Equatable {
    case unreliableQueued
    case reliableOrdered

    var usesReliableOrderedDelivery: Bool {
        self == .reliableOrdered
    }

    static func defaultMode(for mediaPathProfile: MirageMediaPathProfile) -> MirageVideoTransportMode {
        switch mediaPathProfile {
        case .awdlRadio,
             .localWiFi,
             .wired,
             .proximityWiredLike,
             .vpnOrOverlay,
             .other,
             .unknown:
            .unreliableQueued
        }
    }
}

#endif
