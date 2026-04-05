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
    private static let vpnAccessEnabledKey = "mirage.vpn-access"
    private static let supportsHEVCKey = "mirage.supports-hevc"
    private static let supportsP3Key = "mirage.supports-p3"
    private static let supportedColorDepthsKey = "mirage.color-depths"
    private static let maxFrameRateKey = "mirage.max-frame-rate"
    private static let wifiSubnetSignaturesKey = "mirage.net.wifi"
    private static let wiredSubnetSignaturesKey = "mirage.net.wired"

    package struct AdvertisedLocalNetworkContext: Sendable, Equatable {
        package let wifiSubnetSignatures: [String]
        package let wiredSubnetSignatures: [String]

        package var allSubnetSignatures: Set<String> {
            Set(wifiSubnetSignatures).union(wiredSubnetSignatures)
        }
    }

    package static func makeHostAdvertisement(
        deviceID: UUID?,
        identityKeyID: String?,
        modelIdentifier: String?,
        iconName: String?,
        machineFamily: String?,
        hostName: String? = nil,
        acceptingConnections: Bool = true,
        vpnAccessEnabled: Bool = false,
        supportedColorDepths: [MirageStreamColorDepth]
    ) -> LoomPeerAdvertisement {
        let normalizedColorDepths = supportedColorDepths.sorted { lhs, rhs in
            lhs.sortRank < rhs.sortRank
        }
        return LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.protocolVersion),
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: .mac,
            modelIdentifier: modelIdentifier,
            iconName: iconName,
            machineFamily: machineFamily,
            hostName: hostName,
            metadata: [
                maxStreamsKey: "4",
                acceptingConnectionsKey: acceptingConnections ? "1" : "0",
                vpnAccessEnabledKey: vpnAccessEnabled ? "1" : "0",
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
            protocolVersion: Int(MirageKit.protocolVersion),
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

    package static func vpnAccessEnabled(in advertisement: LoomPeerAdvertisement) -> Bool {
        boolValue(vpnAccessEnabledKey, in: advertisement, defaultValue: false)
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

    package static func advertisedBonjourHostName(
        processHostName: String = ProcessInfo.processInfo.hostName
    ) -> String? {
        let trimmedHostName = processHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHostName.isEmpty == false else {
            return nil
        }

        let normalizedHostName = trimmedHostName.replacingOccurrences(of: " ", with: "-")
        if normalizedHostName.contains(".") {
            return normalizedHostName
        }

        return "\(normalizedHostName).local"
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
        return rebuildingAdvertisement(advertisement, metadata: metadata)
    }

    package static func updatingVPNAccessEnabled(
        _ vpnAccessEnabled: Bool,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        var metadata = advertisement.metadata
        metadata[vpnAccessEnabledKey] = vpnAccessEnabled ? "1" : "0"
        return rebuildingAdvertisement(advertisement, metadata: metadata)
    }

    package static func updatingLocalNetworkContext(
        _ context: MirageLocalNetworkSnapshot,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        var metadata = advertisement.metadata
        updateMetadataValue(
            context.wifiSubnetSignatures,
            for: wifiSubnetSignaturesKey,
            in: &metadata
        )
        updateMetadataValue(
            context.wiredSubnetSignatures,
            for: wiredSubnetSignaturesKey,
            in: &metadata
        )
        return rebuildingAdvertisement(advertisement, metadata: metadata)
    }

    package static func advertisedLocalNetworkContext(
        from advertisement: LoomPeerAdvertisement
    ) -> AdvertisedLocalNetworkContext {
        AdvertisedLocalNetworkContext(
            wifiSubnetSignatures: metadataValues(
                for: wifiSubnetSignaturesKey,
                in: advertisement.metadata
            ),
            wiredSubnetSignatures: metadataValues(
                for: wiredSubnetSignaturesKey,
                in: advertisement.metadata
            )
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

    private static func rebuildingAdvertisement(
        _ advertisement: LoomPeerAdvertisement,
        metadata: [String: String]
    ) -> LoomPeerAdvertisement {
        LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: advertisement.directTransports,
            metadata: metadata
        )
    }

    private static func updateMetadataValue(
        _ values: [String],
        for key: String,
        in metadata: inout [String: String]
    ) {
        if values.isEmpty {
            metadata.removeValue(forKey: key)
        } else {
            metadata[key] = values.joined(separator: ",")
        }
    }

    private static func metadataValues(
        for key: String,
        in metadata: [String: String]
    ) -> [String] {
        guard let rawValue = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return []
        }

        return rawValue
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
