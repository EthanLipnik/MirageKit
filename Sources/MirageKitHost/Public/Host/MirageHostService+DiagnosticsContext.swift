//
//  MirageHostService+DiagnosticsContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Registers a Loom diagnostics provider for the current host state.
    func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.diagnosticsContextSnapshot }
            }
        }
    }

    /// Point-in-time host diagnostics emitted with Loom reports.
    var diagnosticsContextSnapshot: LoomDiagnosticsContext {
        [
            "host.state": .string(String(describing: state)),
            "host.connectedClients": .int(connectedClients.count),
            "host.activeStreams": .int(activeStreams.count),
            "host.proximityConnect": .bool(loomNode.configuration.enablePeerToPeer),
            "host.bonjour": .bool(loomNode.configuration.enableBonjour),
            "host.serviceName": .string(serviceName),
            "host.advertisedHostName": advertisedPeerAdvertisement.hostName.map(LoomDiagnosticsValue.string) ?? .null,
            "host.directTransports": .string(
                advertisedPeerAdvertisement.directTransports
                    .map { "\($0.transportKind.rawValue):\($0.port):\($0.pathKind?.rawValue ?? "unknown")" }
                    .joined(separator: ",")
            ),
            "host.remoteControlListenerReady": .bool(remoteControlListenerReady),
            "host.remoteControlPort": remoteControlPort.map { .int(Int($0)) } ?? .null,
        ]
    }
}
#endif
