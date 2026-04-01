//
//  MiragePeerAdvertisementMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Loom

package enum MiragePeerAdvertisementMetadata {
    private static let maxStreamsKey = "mirage.max-streams"
    private static let acceptingConnectionsKey = "mirage.accepting-connections"
    private static let supportsHEVCKey = "mirage.supports-hevc"
    private static let supportsP3Key = "mirage.supports-p3"
    private static let supportedColorDepthsKey = "mirage.color-depths"
    private static let maxFrameRateKey = "mirage.max-frame-rate"

    package static func makeHostAdvertisement(
        deviceID: UUID?,
        identityKeyID: String?,
        modelIdentifier: String?,
        iconName: String?,
        machineFamily: String?,
        acceptingConnections: Bool = true,
        supportedColorDepths: [MirageStreamColorDepth]
    ) -> LoomPeerAdvertisement {
        let normalizedColorDepths = supportedColorDepths.sorted { lhs, rhs in
            lhs.sortRank < rhs.sortRank
        }
        return LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: .mac,
            modelIdentifier: modelIdentifier,
            iconName: iconName,
            machineFamily: machineFamily,
            metadata: [
                maxStreamsKey: "4",
                acceptingConnectionsKey: acceptingConnections ? "1" : "0",
                supportsHEVCKey: "1",
                supportsP3Key: normalizedColorDepths.contains { $0 != .standard } ? "1" : "0",
                supportedColorDepthsKey: normalizedColorDepths.map(\.rawValue).joined(separator: ","),
                maxFrameRateKey: "120",
            ]
        )
    }

    package static func makeClientAdvertisement(
        deviceID: UUID,
        deviceType: DeviceType,
        identityKeyID: String,
        additionalMetadata: [String: String] = [:]
    ) -> LoomPeerAdvertisement {
        LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: deviceType,
            metadata: additionalMetadata
        )
    }

    package static func maxStreams(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(maxStreamsKey, from: advertisement, defaultValue: 4)
    }

    package static func acceptingConnections(in advertisement: LoomPeerAdvertisement) -> Bool {
        boolValue(acceptingConnectionsKey, in: advertisement, defaultValue: true)
    }

    package static func supportsHEVC(in advertisement: LoomPeerAdvertisement) -> Bool {
        boolValue(supportsHEVCKey, in: advertisement, defaultValue: true)
    }

    package static func supportsP3ColorSpace(in advertisement: LoomPeerAdvertisement) -> Bool {
        boolValue(supportsP3Key, in: advertisement, defaultValue: true)
    }

    package static func supportedColorDepths(in advertisement: LoomPeerAdvertisement) -> [MirageStreamColorDepth] {
        if let rawValue = advertisement.metadata[supportedColorDepthsKey] {
            let parsed = rawValue
                .split(separator: ",")
                .compactMap { MirageStreamColorDepth(rawValue: String($0)) }
                .sorted { lhs, rhs in
                    lhs.sortRank < rhs.sortRank
                }
            if !parsed.isEmpty {
                return parsed
            }
        }

        if supportsP3ColorSpace(in: advertisement) {
            return [.standard, .pro]
        }

        return [.standard]
    }

    package static func maxFrameRate(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(maxFrameRateKey, from: advertisement, defaultValue: 120)
    }

    package static func updatingAcceptingConnections(
        _ acceptingConnections: Bool,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        var metadata = advertisement.metadata
        metadata[acceptingConnectionsKey] = acceptingConnections ? "1" : "0"
        return LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            metadata: metadata
        )
    }

    private static func intValue(
        _ key: String,
        from advertisement: LoomPeerAdvertisement,
        defaultValue: Int
    ) -> Int {
        guard let rawValue = advertisement.metadata[key],
              let value = Int(rawValue) else {
            return defaultValue
        }
        return value
    }

    private static func boolValue(
        _ key: String,
        in advertisement: LoomPeerAdvertisement,
        defaultValue: Bool
    ) -> Bool {
        guard let rawValue = advertisement.metadata[key] else {
            return defaultValue
        }
        switch rawValue {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return defaultValue
        }
    }
}
