//
//  MirageHostService+Diagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Loom
import MirageKit

#if os(macOS)
@MainActor
public extension MirageHostService {
    var networkDiagnosticsSummaryLines: [String] {
        let directTransports = advertisedPeerAdvertisement.directTransports
            .map { transport in
                let path = transport.pathKind?.rawValue ?? "unknown"
                return "\(transport.transportKind.rawValue):\(transport.port):\(path)"
            }
            .joined(separator: ",")

        return [
            "Host Proximity Connect Effective: \(loomNode.configuration.enablePeerToPeer)",
            "Host Bonjour Enabled: \(loomNode.configuration.enableBonjour)",
            "Host Advertised Name: \(serviceName)",
            "Host Advertised Bonjour Host Name: \(advertisedPeerAdvertisement.hostName ?? "none")",
            "Host Direct Transports: \(directTransports.isEmpty ? "none" : directTransports)",
            "Host Remote Control Listener Ready: \(remoteControlListenerReady)",
            "Host Remote Control Port: \(remoteControlPort.map(String.init) ?? "none")",
        ]
    }
}
#endif
