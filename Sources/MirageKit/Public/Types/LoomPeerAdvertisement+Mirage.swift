//
//  LoomPeerAdvertisement+Mirage.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Loom

public enum MirageHostAdvertisementAvailabilityReason: String, Sendable {
    case available
    case busy
    case softwareUpdate
}

public extension LoomPeerAdvertisement {
    var mirageMaxStreams: Int {
        MiragePeerAdvertisementMetadata.maxStreams(from: self)
    }

    var mirageAcceptingConnections: Bool {
        MiragePeerAdvertisementMetadata.acceptingConnections(in: self)
    }

    var mirageAvailabilityReason: MirageHostAdvertisementAvailabilityReason {
        switch MiragePeerAdvertisementMetadata.availabilityReason(in: self) {
        case .available:
            return .available
        case .busy:
            return .busy
        case .softwareUpdate:
            return .softwareUpdate
        }
    }

    var mirageVPNAccessEnabled: Bool {
        MiragePeerAdvertisementMetadata.vpnAccessEnabled(in: self)
    }

    var mirageSupportsHEVC: Bool {
        MiragePeerAdvertisementMetadata.supportsHEVC(in: self)
    }

    var mirageSupportsP3ColorSpace: Bool {
        MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: self)
    }

    var mirageSupportedColorDepths: [MirageStreamColorDepth] {
        MiragePeerAdvertisementMetadata.supportedColorDepths(in: self)
    }

    var mirageSupportsUltraColorDepth: Bool {
        mirageSupportedColorDepths.contains(.ultra)
    }

    var mirageSupportsProRes4444: Bool {
        MiragePeerAdvertisementMetadata.supportsProRes4444(in: self)
    }

    var mirageMaxFrameRate: Int {
        MiragePeerAdvertisementMetadata.maxFrameRate(from: self)
    }
}
