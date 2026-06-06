//
//  MiragePeerAdvertisementMetadata.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Loom
import Network
import MirageMedia
import MirageWire

package enum MiragePeerAdvertisementMetadata {
    package enum AvailabilityReason: String, Sendable {
        case available
        case busy
        case softwareUpdate
    }

    private struct LocalEndpointHintsPayload: Codable {
        let version: Int
        let hints: [LocalEndpointHintPayload]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case hints = "n"
        }
    }

    private struct LocalEndpointHintPayload: Codable {
        let wifiSubnetSignatures: [String]
        let wiredSubnetSignatures: [String]
        let hosts: [String]
        let observedAt: TimeInterval

        init(_ hint: MirageLocalNetworkEndpointHint) {
            wifiSubnetSignatures = hint.network.wifiSubnetSignatures
            wiredSubnetSignatures = hint.network.wiredSubnetSignatures
            hosts = hint.hosts
            observedAt = hint.observedAt.timeIntervalSince1970
        }

        var hint: MirageLocalNetworkEndpointHint {
            MirageLocalNetworkEndpointHint(
                network: MirageLocalNetworkSignatureContext(
                    wifiSubnetSignatures: wifiSubnetSignatures,
                    wiredSubnetSignatures: wiredSubnetSignatures
                ),
                hosts: hosts,
                observedAt: Date(timeIntervalSince1970: observedAt)
            )
        }

        enum CodingKeys: String, CodingKey {
            case wifiSubnetSignatures = "w"
            case wiredSubnetSignatures = "r"
            case hosts = "a"
            case observedAt = "t"
        }
    }

    private static let maxStreamsKey = "mirage.max-streams"
    private static let acceptingConnectionsKey = "mirage.accepting-connections"
    private static let availabilityReasonKey = "mirage.availability-reason"
    private static let vpnAccessEnabledKey = "mirage.vpn-access"
    private static let supportsHEVCKey = "mirage.supports-hevc"
    private static let supportsP3Key = "mirage.supports-p3"
    private static let supportedColorDepthsKey = "mirage.color-depths"
    private static let supportsProRes4444Key = "mirage.supports-prores-4444"
    private static let maxFrameRateKey = "mirage.max-frame-rate"
    private static let discoveryProtocolVersionKey = "mirage.protocol.discovery"
    private static let controlProtocolVersionKey = "mirage.protocol.control"
    private static let mediaPacketProtocolVersionKey = "mirage.protocol.media"
    private static let wifiSubnetSignaturesKey = "mirage.net.wifi"
    private static let wiredSubnetSignaturesKey = "mirage.net.wired"
    private static let localEndpointHintsKey = "mirage.net.lan-hints"
    package static let localEndpointHintExpiration: TimeInterval = 30 * 24 * 60 * 60
    package static let maxLocalEndpointHintNetworks = 3
    package static let maxLocalEndpointHostsPerNetwork = 1

    package struct AdvertisedLocalNetworkContext: Sendable, Equatable {
        package let wifiSubnetSignatures: [String]
        package let wiredSubnetSignatures: [String]

        package var allSubnetSignatures: Set<String> {
            MirageLocalNetworkSnapshot.subnetSignatureSet(
                wifiSubnetSignatures: wifiSubnetSignatures,
                wiredSubnetSignatures: wiredSubnetSignatures
            )
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
        supportedColorDepths: [MirageMedia.MirageStreamColorDepth],
        supportsProRes4444: Bool = false
    ) -> LoomPeerAdvertisement {
        let normalizedColorDepths = supportedColorDepths.sorted { lhs, rhs in
            lhs.sortRank < rhs.sortRank
        }
        var metadata = currentProtocolMetadata()
        metadata.merge([
            maxStreamsKey: "4",
            acceptingConnectionsKey: acceptingConnections ? "1" : "0",
            availabilityReasonKey: acceptingConnections ?
                AvailabilityReason.available.rawValue :
                AvailabilityReason.busy.rawValue,
            vpnAccessEnabledKey: vpnAccessEnabled ? "1" : "0",
            supportsHEVCKey: "1",
            supportsP3Key: normalizedColorDepths.contains { $0 != .standard } ? "1" : "0",
            supportedColorDepthsKey: normalizedColorDepths.map(\.rawValue).joined(separator: ","),
            supportsProRes4444Key: supportsProRes4444 ? "1" : "0",
            maxFrameRateKey: "120",
        ]) { _, current in current }
        return LoomPeerAdvertisement(
            protocolVersion: Int(MirageWireProtocol.currentDiscoveryVersion),
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: .mac,
            modelIdentifier: modelIdentifier,
            iconName: iconName,
            machineFamily: machineFamily,
            hostName: hostName,
            metadata: metadata
        )
    }

    package static func makeClientAdvertisement(
        deviceID: UUID,
        deviceType: DeviceType,
        identityKeyID: String,
        additionalMetadata: [String: String] = [:]
    ) -> LoomPeerAdvertisement {
        var metadata = additionalMetadata
        currentProtocolMetadata().forEach { key, value in
            metadata[key] = value
        }
        return LoomPeerAdvertisement(
            protocolVersion: Int(MirageWireProtocol.currentDiscoveryVersion),
            deviceID: deviceID,
            identityKeyID: identityKeyID,
            deviceType: deviceType,
            metadata: metadata
        )
    }

    package static func discoveryProtocolVersion(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(discoveryProtocolVersionKey, from: advertisement, defaultValue: advertisement.protocolVersion)
    }

    package static func controlProtocolVersion(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(controlProtocolVersionKey, from: advertisement, defaultValue: advertisement.protocolVersion)
    }

    package static func mediaPacketProtocolVersion(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(mediaPacketProtocolVersionKey, from: advertisement, defaultValue: advertisement.protocolVersion)
    }

    package static func maxStreams(from advertisement: LoomPeerAdvertisement) -> Int {
        intValue(maxStreamsKey, from: advertisement, defaultValue: 4)
    }

    package static func acceptingConnections(in advertisement: LoomPeerAdvertisement) -> Bool {
        boolValue(acceptingConnectionsKey, in: advertisement, defaultValue: true)
    }

    package static func availabilityReason(in advertisement: LoomPeerAdvertisement) -> AvailabilityReason {
        guard let rawValue = advertisement.metadata[availabilityReasonKey],
              let reason = AvailabilityReason(rawValue: rawValue) else {
            return acceptingConnections(in: advertisement) ? .available : .busy
        }
        return reason
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

    package static func supportsProRes4444(in advertisement: LoomPeerAdvertisement) -> Bool {
        guard advertisement.metadata[supportsProRes4444Key] != nil else {
            return supportedColorDepths(in: advertisement).contains(.ultra)
        }
        return boolValue(supportsProRes4444Key, in: advertisement, defaultValue: false)
    }

    package static func supportedColorDepths(in advertisement: LoomPeerAdvertisement) -> [MirageMedia.MirageStreamColorDepth] {
        if let rawValue = advertisement.metadata[supportedColorDepthsKey] {
            let parsed = rawValue
                .split(separator: ",")
                .compactMap { MirageMedia.MirageStreamColorDepth(rawValue: String($0)) }
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

    package static func updatingAvailability(
        _ reason: AvailabilityReason,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        var metadata = advertisement.metadata
        metadata[acceptingConnectionsKey] = reason == .available ? "1" : "0"
        metadata[availabilityReasonKey] = reason.rawValue
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

    package static func updatingIdentityKeyID(
        _ keyID: String?,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        rebuildingAdvertisement(advertisement, identityKeyID: keyID)
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

    package static func updatingDirectTransportPorts(
        _ ports: [LoomTransportKind: UInt16],
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        let pathKindsByTransport = advertisement.directTransports.reduce(
            into: [LoomTransportKind: LoomDirectPathKind]()
        ) { result, transport in
            if let pathKind = transport.pathKind {
                result[transport.transportKind] = pathKind
            }
        }
        let directTransports = LoomTransportKind.allCases.compactMap {
            transportKind -> LoomDirectTransportAdvertisement? in
            guard let port = ports[transportKind], port > 0 else {
                return nil
            }
            return LoomDirectTransportAdvertisement(
                transportKind: transportKind,
                port: port,
                pathKind: pathKindsByTransport[transportKind]
            )
        }

        return rebuildingAdvertisement(
            advertisement,
            identityKeyID: advertisement.identityKeyID,
            directTransports: directTransports
        )
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

    package static func updatingLocalEndpointHints(
        localEndpointHosts: [NWEndpoint.Host],
        localNetwork: MirageLocalNetworkSnapshot,
        observedAt: Date = Date(),
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        let network = MirageLocalNetworkSignatureContext(localNetwork)
        let currentHosts = normalizedLocalEndpointHosts(localEndpointHosts)
        var hints = localEndpointHints(from: advertisement, now: observedAt)

        if !network.isEmpty && !currentHosts.isEmpty {
            let currentHint = MirageLocalNetworkEndpointHint(
                network: network,
                hosts: currentHosts,
                observedAt: observedAt
            )
            hints.removeAll { $0.network.intersects(network) }
            hints.append(currentHint)
        }

        return updatingLocalEndpointHints(hints, now: observedAt, in: advertisement)
    }

    package static func mergingLocalEndpointHints(
        from previousAdvertisement: LoomPeerAdvertisement?,
        into advertisement: LoomPeerAdvertisement,
        now: Date = Date()
    ) -> LoomPeerAdvertisement {
        let existingHints = previousAdvertisement.map {
            localEndpointHints(from: $0, now: now)
        } ?? []
        let currentHints = localEndpointHints(from: advertisement, now: now)
        return updatingLocalEndpointHints(
            currentHints + existingHints,
            now: now,
            in: advertisement
        )
    }

    package static func localEndpointHints(
        from advertisement: LoomPeerAdvertisement,
        now: Date = Date()
    ) -> [MirageLocalNetworkEndpointHint] {
        guard let rawValue = advertisement.metadata[localEndpointHintsKey],
              let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LocalEndpointHintsPayload.self, from: data),
              payload.version == 1 else {
            return []
        }

        return boundedLocalEndpointHints(
            payload.hints.map(\.hint),
            now: now
        )
    }

    package static func bestLocalEndpointHost(
        matching currentNetwork: MirageLocalNetworkSignatureContext,
        in advertisement: LoomPeerAdvertisement,
        now: Date = Date()
    ) -> String? {
        guard !currentNetwork.isEmpty else { return nil }
        return localEndpointHints(from: advertisement, now: now)
            .first { $0.matches(currentNetwork) }?
            .hosts
            .first
    }

    private static func updatingLocalEndpointHints(
        _ hints: [MirageLocalNetworkEndpointHint],
        now: Date,
        in advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        let boundedHints = boundedLocalEndpointHints(hints, now: now)
        var metadata = advertisement.metadata
        if let encodedHints = encodedLocalEndpointHints(boundedHints) {
            metadata[localEndpointHintsKey] = encodedHints
        } else {
            metadata.removeValue(forKey: localEndpointHintsKey)
        }
        return rebuildingAdvertisement(advertisement, metadata: metadata)
    }

    private static func boundedLocalEndpointHints(
        _ hints: [MirageLocalNetworkEndpointHint],
        now: Date
    ) -> [MirageLocalNetworkEndpointHint] {
        var boundedHints: [MirageLocalNetworkEndpointHint] = []
        let expirationDate = now.addingTimeInterval(-localEndpointHintExpiration)

        for hint in hints.sorted(by: { $0.observedAt > $1.observedAt }) {
            guard hint.observedAt >= expirationDate,
                  !hint.network.isEmpty,
                  !hint.hosts.isEmpty,
                  !boundedHints.contains(where: { $0.network.intersects(hint.network) }) else {
                continue
            }
            boundedHints.append(
                MirageLocalNetworkEndpointHint(
                    network: hint.network,
                    hosts: Array(hint.hosts.prefix(maxLocalEndpointHostsPerNetwork)),
                    observedAt: hint.observedAt
                )
            )
            if boundedHints.count == maxLocalEndpointHintNetworks {
                break
            }
        }

        return boundedHints
    }

    private static func encodedLocalEndpointHints(
        _ hints: [MirageLocalNetworkEndpointHint]
    ) -> String? {
        guard !hints.isEmpty else { return nil }
        let payload = LocalEndpointHintsPayload(
            version: 1,
            hints: hints.map(LocalEndpointHintPayload.init)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedLocalEndpointHosts(_ hosts: [NWEndpoint.Host]) -> [String] {
        var seenHosts = Set<String>()
        var normalizedHosts: [String] = []
        for host in hosts {
            let hostString = String(describing: host).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsableLocalEndpointHost(hostString),
                  seenHosts.insert(hostString).inserted else {
                continue
            }
            normalizedHosts.append(hostString)
        }
        return normalizedHosts
    }

    private static func isUsableLocalEndpointHost(_ hostString: String) -> Bool {
        guard let address = IPv4Address(hostString),
              MirageEndpointClassifier.classify(.ipv4(address)) == .privateLAN else {
            return false
        }

        let rawValue = address.rawValue
        guard rawValue.count >= 2 else { return false }
        let firstOctet = rawValue[rawValue.startIndex]
        let secondOctet = rawValue[rawValue.startIndex.advanced(by: 1)]
        return firstOctet != 0 &&
            firstOctet != 127 &&
            !(firstOctet == 169 && secondOctet == 254)
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

    private static func currentProtocolMetadata() -> [String: String] {
        [
            discoveryProtocolVersionKey: String(Int(MirageWireProtocol.currentDiscoveryVersion)),
            controlProtocolVersionKey: String(Int(MirageWireProtocol.currentControlVersion)),
            mediaPacketProtocolVersionKey: String(Int(MirageWireProtocol.currentMediaPacketVersion)),
        ]
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
        rebuildingAdvertisement(
            advertisement,
            identityKeyID: advertisement.identityKeyID,
            directTransports: advertisement.directTransports,
            metadata: metadata
        )
    }

    private static func rebuildingAdvertisement(
        _ advertisement: LoomPeerAdvertisement,
        identityKeyID: String?
    ) -> LoomPeerAdvertisement {
        rebuildingAdvertisement(
            advertisement,
            identityKeyID: identityKeyID,
            directTransports: advertisement.directTransports
        )
    }

    private static func rebuildingAdvertisement(
        _ advertisement: LoomPeerAdvertisement,
        identityKeyID: String?,
        directTransports: [LoomDirectTransportAdvertisement],
        metadata: [String: String]? = nil
    ) -> LoomPeerAdvertisement {
        LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: directTransports,
            metadata: metadata ?? advertisement.metadata
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

extension MirageLocalNetworkSignatureContext {
    package init(_ snapshot: MirageLocalNetworkSnapshot) {
        self.init(
            wifiSubnetSignatures: snapshot.wifiSubnetSignatures,
            wiredSubnetSignatures: snapshot.wiredSubnetSignatures
        )
    }
}
