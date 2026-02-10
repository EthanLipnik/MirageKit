//
//  MirageProtocolNegotiation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Protocol capability negotiation primitives for hello handshake.
//

import Foundation

package struct MirageFeatureSet: OptionSet, Sendable, Codable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Endpoints support registry-based control-message dispatch.
    package static let controlMessageRouting = MirageFeatureSet(rawValue: 1 << 0)
    /// Endpoints support typed hello negotiation fields.
    package static let protocolNegotiation = MirageFeatureSet(rawValue: 1 << 1)
    /// Endpoints enforce signed identity handshake metadata.
    package static let identityAuthV2 = MirageFeatureSet(rawValue: 1 << 2)
}

package struct MirageProtocolNegotiation: Codable, Sendable {
    package let protocolVersion: Int
    package let supportedFeatures: MirageFeatureSet
    package let selectedFeatures: MirageFeatureSet

    package init(
        protocolVersion: Int,
        supportedFeatures: MirageFeatureSet,
        selectedFeatures: MirageFeatureSet
    ) {
        self.protocolVersion = protocolVersion
        self.supportedFeatures = supportedFeatures
        self.selectedFeatures = selectedFeatures
    }

    package static func clientHello(
        protocolVersion: Int,
        supportedFeatures: MirageFeatureSet
    )
    -> MirageProtocolNegotiation {
        MirageProtocolNegotiation(
            protocolVersion: protocolVersion,
            supportedFeatures: supportedFeatures,
            selectedFeatures: []
        )
    }
}
