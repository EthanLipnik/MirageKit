//
//  MirageMediaPathProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//
//  Media-path profiles used to choose real-time display behavior.
//

import Foundation

package enum MirageMediaPathProfile: String, Codable, Sendable, Equatable {
    case awdlRadio
    case localWiFi
    case wired
    case proximityWiredLike
    case vpnOrOverlay
    case other
    case unknown

    package var usesAwdlRadioPolicy: Bool {
        self == .awdlRadio
    }

    package var usesRemoteTolerance: Bool {
        switch self {
        case .vpnOrOverlay:
            true
        case .awdlRadio,
             .localWiFi,
             .wired,
             .proximityWiredLike,
             .other,
             .unknown:
            false
        }
    }

    package static func classify(
        pathKind: MirageNetworkPathKind,
        interfaceNames: [String],
        usesWiFi: Bool = false,
        usesWired: Bool = false,
        usesCellular: Bool = false,
        usesLoopback: Bool = false,
        usesOther: Bool = false
    ) -> MirageMediaPathProfile {
        let interfaces = InterfaceSummary(interfaceNames)
        if interfaces.hasOverlay || pathKind == .vpn || usesCellular || pathKind == .cellular {
            return .vpnOrOverlay
        }
        let selectedWiFi = pathKind == .wifi ||
            (usesWiFi && (interfaces.hasNonProximityRouteInterface || !interfaces.hasProximity))
        if selectedWiFi {
            return .localWiFi
        }
        if interfaces.hasApplePrivateNCM || interfaces.hasLowLatencyWireless {
            return .proximityWiredLike
        }
        if usesWired || usesLoopback || pathKind == .wired || pathKind == .loopback {
            return .wired
        }
        if interfaces.hasBridge {
            return .wired
        }
        if interfaces.hasAWDL {
            return .awdlRadio
        }
        if pathKind == .awdl {
            return .awdlRadio
        }
        if usesWiFi || pathKind == .wifi {
            return .localWiFi
        }
        if usesOther || pathKind == .other {
            return .other
        }
        return .unknown
    }

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
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .sorted()
            hasApplePrivateNCM = names.contains {
                $0.hasPrefix("anpi") || $0.hasPrefix("apni")
            }
            hasAWDL = names.contains { $0.hasPrefix("awdl") }
            hasLowLatencyWireless = names.contains { $0.hasPrefix("llw") }
            hasBridge = names.contains { $0.hasPrefix("bridge") || $0.contains("thunderbolt") }
            hasOverlay = names.contains { $0.hasPrefix("utun") }
            hasProximity = hasApplePrivateNCM || hasAWDL || hasLowLatencyWireless
            hasNonProximityRouteInterface = names.contains {
                !$0.hasPrefix("anpi") &&
                    !$0.hasPrefix("apni") &&
                    !$0.hasPrefix("awdl") &&
                    !$0.hasPrefix("llw") &&
                    !$0.hasPrefix("utun") &&
                    !$0.hasPrefix("bridge") &&
                    !$0.contains("thunderbolt")
            }
        }
    }
}
