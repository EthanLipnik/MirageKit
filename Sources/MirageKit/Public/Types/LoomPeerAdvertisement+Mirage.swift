//
//  LoomPeerAdvertisement+Mirage.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Loom

/// Host availability reason decoded from a Mirage peer advertisement.
public enum MirageHostAdvertisementAvailabilityReason: String, Sendable {
    /// Host is accepting new Mirage sessions.
    case available
    /// Host is reachable but currently at capacity or otherwise busy.
    case busy
    /// Host is temporarily unavailable while software update work is active.
    case softwareUpdate
}

public extension LoomPeerAdvertisement {
    /// Maximum simultaneous Mirage streams advertised by the host.
    var mirageMaxStreams: Int {
        MiragePeerAdvertisementMetadata.maxStreams(from: self)
    }

    /// Whether the host is currently accepting Mirage client connections.
    var mirageAcceptingConnections: Bool {
        MiragePeerAdvertisementMetadata.acceptingConnections(in: self)
    }

    /// Current availability reason advertised by the host.
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

    /// Whether the host advertises reusable VPN access metadata.
    var mirageVPNAccessEnabled: Bool {
        MiragePeerAdvertisementMetadata.vpnAccessEnabled(in: self)
    }

    /// Whether the host supports HEVC video streams.
    var mirageSupportsHEVC: Bool {
        MiragePeerAdvertisementMetadata.supportsHEVC(in: self)
    }

    /// Whether the host supports Display P3 color output.
    var mirageSupportsP3ColorSpace: Bool {
        MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: self)
    }

    /// Color-depth modes advertised by the host.
    var mirageSupportedColorDepths: [MirageStreamColorDepth] {
        MiragePeerAdvertisementMetadata.supportedColorDepths(in: self)
    }

    /// Whether the host advertises ultra color-depth support.
    var mirageSupportsUltraColorDepth: Bool {
        mirageSupportedColorDepths.contains(.ultra)
    }

    /// Whether the host supports ProRes 4444 app/window streams.
    var mirageSupportsProRes4444: Bool {
        MiragePeerAdvertisementMetadata.supportsProRes4444(in: self)
    }

    /// Maximum frame rate advertised by the host.
    var mirageMaxFrameRate: Int {
        MiragePeerAdvertisementMetadata.maxFrameRate(from: self)
    }
}
