//
//  LoomPeerAdvertisement+Mirage.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageMedia

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
    /// Mirage discovery compatibility version advertised by the peer.
    var mirageDiscoveryProtocolVersion: Int {
        MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from: self)
    }

    /// Mirage control protocol version advertised by the peer.
    var mirageControlProtocolVersion: Int {
        MiragePeerAdvertisementMetadata.controlProtocolVersion(from: self)
    }

    /// Mirage media packet protocol version advertised by the peer.
    var mirageMediaPacketProtocolVersion: Int {
        MiragePeerAdvertisementMetadata.mediaPacketProtocolVersion(from: self)
    }

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
    var mirageSupportedColorDepths: [MirageMedia.MirageStreamColorDepth] {
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

    /// Operating system name advertised by the peer, if available.
    var mirageOperatingSystemName: String? {
        MiragePeerAdvertisementMetadata.operatingSystemName(in: self)
    }

    /// Operating system version advertised by the peer, if available.
    var mirageOperatingSystemVersion: String? {
        MiragePeerAdvertisementMetadata.operatingSystemVersion(in: self)
    }

    /// Operating system major version advertised by the peer, if available.
    var mirageOperatingSystemMajorVersion: Int? {
        MiragePeerAdvertisementMetadata.operatingSystemMajorVersion(in: self)
    }

    /// Bounded local-network endpoint hints advertised by the host.
    var mirageLocalNetworkEndpointHints: [MirageLocalNetworkEndpointHint] {
        MiragePeerAdvertisementMetadata.localEndpointHints(from: self)
    }

    /// Best saved local endpoint host for the supplied current network, if one still applies.
    func mirageLocalEndpointHost(
        matching currentNetwork: MirageLocalNetworkSignatureContext
    ) -> String? {
        MiragePeerAdvertisementMetadata.bestLocalEndpointHost(
            matching: currentNetwork,
            in: self
        )
    }

    /// Returns this advertisement after preserving unexpired local-network hints from a previous publication.
    func mirageMergingLocalNetworkEndpointHints(
        from previousAdvertisement: LoomPeerAdvertisement?
    ) -> LoomPeerAdvertisement {
        MiragePeerAdvertisementMetadata.mergingLocalEndpointHints(
            from: previousAdvertisement,
            into: self
        )
    }
}
