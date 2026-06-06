//
//  MirageRuntimeCapabilities.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageMedia

/// Mirage control protocol version supported by a runtime capability snapshot.
public struct MirageProtocolVersion: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MirageProtocolVersion, rhs: MirageProtocolVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Current Mirage control protocol generation.
    public static let currentControl = MirageProtocolVersion(Int(MirageWireProtocol.currentControlVersion))

    /// First Mirage control protocol generation reserved for the rearchitecture cutover.
    public static let rearchitectureCutoverControl = MirageProtocolVersion(
        Int(MirageWireProtocol.rearchitectureCutoverVersion)
    )
}

/// Mirage control-plane feature advertised in runtime capabilities.
public struct MirageControlFeature: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MirageControlFeature, rhs: MirageControlFeature) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let sessionBootstrap = MirageControlFeature("session-bootstrap")
    public static let mediaEncryptionPolicy = MirageControlFeature("media-encryption-policy")
    public static let streamLifecycle = MirageControlFeature("stream-lifecycle")
    public static let appStreaming = MirageControlFeature("app-streaming")
    public static let audioStreaming = MirageControlFeature("audio-streaming")
    public static let sharedClipboard = MirageControlFeature("shared-clipboard")
    public static let hostMetadata = MirageControlFeature("host-metadata")
    public static let softwareUpdate = MirageControlFeature("software-update")
    public static let remoteAccessAuthorization = MirageControlFeature("remote-access-authorization")
}

/// Media packet family that can be selected only after capability negotiation.
public struct MirageMediaPacketFamily: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MirageMediaPacketFamily, rhs: MirageMediaPacketFamily) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Current full-frame media packets with the fixed video/audio header layouts.
    public static let fixedHeaderFullFrame = MirageMediaPacketFamily("fixed-header-full-frame")
}

/// Input feature advertised in runtime capabilities.
public struct MirageInputFeature: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MirageInputFeature, rhs: MirageInputFeature) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let pointer = MirageInputFeature("pointer")
    public static let keyboard = MirageInputFeature("keyboard")
    public static let stylus = MirageInputFeature("stylus")
    public static let hostSystemAction = MirageInputFeature("host-system-action")
    public static let priorityInput = MirageInputFeature("priority-input")
}

/// Diagnostics feature advertised in runtime capabilities.
public struct MirageDiagnosticsFeature: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MirageDiagnosticsFeature, rhs: MirageDiagnosticsFeature) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let streamMetrics = MirageDiagnosticsFeature("stream-metrics")
    public static let mediaFeedback = MirageDiagnosticsFeature("media-feedback")
    public static let supportLogs = MirageDiagnosticsFeature("support-logs")
}

/// Structured snapshot of the Mirage runtime capabilities that can participate in negotiation.
public struct MirageRuntimeCapabilities: Equatable, Codable, Sendable {
    public let protocolVersions: Set<MirageProtocolVersion>
    public let controlFeatures: Set<MirageControlFeature>
    public let mediaPacketFamilies: Set<MirageMediaPacketFamily>
    public let mediaTopologies: Set<MirageMediaTopologyKind>
    public let codecs: Set<MirageMedia.MirageVideoCodec>
    public let inputFeatures: Set<MirageInputFeature>
    public let diagnosticsFeatures: Set<MirageDiagnosticsFeature>

    public init(
        protocolVersions: Set<MirageProtocolVersion>,
        controlFeatures: Set<MirageControlFeature>,
        mediaPacketFamilies: Set<MirageMediaPacketFamily>,
        mediaTopologies: Set<MirageMediaTopologyKind>,
        codecs: Set<MirageMedia.MirageVideoCodec>,
        inputFeatures: Set<MirageInputFeature>,
        diagnosticsFeatures: Set<MirageDiagnosticsFeature>
    ) {
        self.protocolVersions = protocolVersions
        self.controlFeatures = controlFeatures
        self.mediaPacketFamilies = mediaPacketFamilies
        self.mediaTopologies = mediaTopologies
        self.codecs = codecs
        self.inputFeatures = inputFeatures
        self.diagnosticsFeatures = diagnosticsFeatures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersions: try container.decodeSetIfPresent(
                MirageProtocolVersion.self,
                forKey: .protocolVersions
            ),
            controlFeatures: try container.decodeSetIfPresent(
                MirageControlFeature.self,
                forKey: .controlFeatures
            ),
            mediaPacketFamilies: try container.decodeSetIfPresent(
                MirageMediaPacketFamily.self,
                forKey: .mediaPacketFamilies
            ),
            mediaTopologies: try container.decodeSetIfPresent(
                MirageMediaTopologyKind.self,
                forKey: .mediaTopologies
            ),
            codecs: try container.decodeSetIfPresent(MirageMedia.MirageVideoCodec.self, forKey: .codecs),
            inputFeatures: try container.decodeSetIfPresent(MirageInputFeature.self, forKey: .inputFeatures),
            diagnosticsFeatures: try container.decodeSetIfPresent(
                MirageDiagnosticsFeature.self,
                forKey: .diagnosticsFeatures
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersions.sorted(), forKey: .protocolVersions)
        try container.encode(controlFeatures.sorted(), forKey: .controlFeatures)
        try container.encode(mediaPacketFamilies.sorted(), forKey: .mediaPacketFamilies)
        try container.encode(mediaTopologies.sorted { $0.rawValue < $1.rawValue }, forKey: .mediaTopologies)
        try container.encode(codecs.sorted { $0.rawValue < $1.rawValue }, forKey: .codecs)
        try container.encode(inputFeatures.sorted(), forKey: .inputFeatures)
        try container.encode(diagnosticsFeatures.sorted(), forKey: .diagnosticsFeatures)
    }

    /// Builds the full-frame baseline capability snapshot used by the current architecture.
    public static func fullFrameBaseline(codecs: Set<MirageMedia.MirageVideoCodec>) -> MirageRuntimeCapabilities {
        MirageRuntimeCapabilities(
            protocolVersions: [.currentControl],
            controlFeatures: [
                .sessionBootstrap,
                .mediaEncryptionPolicy,
                .streamLifecycle,
                .appStreaming,
                .audioStreaming,
                .sharedClipboard,
                .hostMetadata,
                .softwareUpdate,
                .remoteAccessAuthorization,
            ],
            mediaPacketFamilies: [.fixedHeaderFullFrame],
            mediaTopologies: [.singleUnit],
            codecs: codecs,
            inputFeatures: [.pointer, .keyboard, .stylus, .hostSystemAction, .priorityInput],
            diagnosticsFeatures: [.streamMetrics, .mediaFeedback, .supportLogs]
        )
    }

    /// Full-frame baseline capabilities used by the current host/client runtime.
    public static var currentFullFrameBaseline: MirageRuntimeCapabilities {
        fullFrameBaseline(codecs: Set(MirageMedia.MirageVideoCodec.allCases))
    }

    /// Returns the intersection of locally and remotely advertised capabilities.
    public func negotiated(with remote: MirageRuntimeCapabilities) -> MirageRuntimeCapabilities {
        MirageRuntimeCapabilities(
            protocolVersions: protocolVersions.intersection(remote.protocolVersions),
            controlFeatures: controlFeatures.intersection(remote.controlFeatures),
            mediaPacketFamilies: mediaPacketFamilies.intersection(remote.mediaPacketFamilies),
            mediaTopologies: mediaTopologies.intersection(remote.mediaTopologies),
            codecs: codecs.intersection(remote.codecs),
            inputFeatures: inputFeatures.intersection(remote.inputFeatures),
            diagnosticsFeatures: diagnosticsFeatures.intersection(remote.diagnosticsFeatures)
        )
    }

    /// Returns the first mutually supported media packet family in preference order.
    public func preferredMediaPacketFamily(
        matching remote: MirageRuntimeCapabilities,
        preferredOrder: [MirageMediaPacketFamily] = [.fixedHeaderFullFrame]
    ) -> MirageMediaPacketFamily? {
        let negotiatedFamilies = mediaPacketFamilies.intersection(remote.mediaPacketFamilies)
        return preferredOrder.first { negotiatedFamilies.contains($0) }
    }

    /// Selects a packet family that may be used for sending media to a peer.
    public func selectedMediaPacketFamilyForSend(
        matching remote: MirageRuntimeCapabilities?,
        requiredTopology: MirageMediaTopologyKind = .singleUnit,
        requiredControlFeatures: Set<MirageControlFeature> = [.sessionBootstrap, .streamLifecycle],
        preferredOrder: [MirageMediaPacketFamily] = [.fixedHeaderFullFrame]
    ) -> MirageMediaPacketFamily? {
        guard supportsCurrentControlProtocol,
              requiredControlFeatures.isSubset(of: controlFeatures),
              mediaTopologies.contains(requiredTopology) else {
            return nil
        }

        guard let remote else {
            return preferredOrder.first { mediaPacketFamilies.contains($0) }
        }

        guard remote.supportsCurrentControlProtocol,
              requiredControlFeatures.isSubset(of: remote.controlFeatures),
              remote.mediaTopologies.contains(requiredTopology) else {
            return nil
        }

        return preferredMediaPacketFamily(matching: remote, preferredOrder: preferredOrder)
    }

    /// Returns whether the snapshot advertises a control feature.
    public func supportsControlFeature(_ feature: MirageControlFeature) -> Bool {
        controlFeatures.contains(feature)
    }

    /// Returns whether the snapshot advertises a media topology family.
    public func supportsMediaTopology(_ topology: MirageMediaTopologyKind) -> Bool {
        mediaTopologies.contains(topology)
    }

    private var supportsCurrentControlProtocol: Bool {
        protocolVersions.contains(.currentControl)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersions
        case controlFeatures
        case mediaPacketFamilies
        case mediaTopologies
        case codecs
        case inputFeatures
        case diagnosticsFeatures
    }
}

private extension KeyedDecodingContainer {
    func decodeSetIfPresent<Value>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Set<Value> where Value: Decodable & Hashable {
        try decodeIfPresent(Set<Value>.self, forKey: key) ?? []
    }
}
