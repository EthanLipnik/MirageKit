//
//  MirageHostService+DiagnosticsContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Registers a diagnostics provider for the current host state.
    func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await MirageDiagnosticsContextRegistry.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.diagnosticsContextSnapshot }
            }
        }
    }

    /// Point-in-time host diagnostics emitted with diagnostics reports.
    var diagnosticsContextSnapshot: MirageDiagnosticsContext {
        let advertisingDiagnostics = loomNode.advertisingDiagnostics
        let directListenerPorts = advertisingDiagnostics.directListenerPorts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { entry in "\(entry.key.rawValue):\(entry.value)" }
            .joined(separator: ",")
        let directTransports = advertisedPeerAdvertisement.directTransports
            .map { transport -> String in
                let path = transport.pathKind?.rawValue ?? "unknown"
                return "\(transport.transportKind.rawValue):\(transport.port):\(path)"
            }
            .joined(separator: ",")
        return [
            "host.state": .string(String(describing: state)),
            "host.connectedClients": .int(connectedClients.count),
            "host.activeStreams": .int(activeStreams.count),
            "host.proximityConnect": .bool(loomNode.configuration.enablePeerToPeer),
            "host.bonjour": .bool(loomNode.configuration.enableBonjour),
            "host.advertising.state": .string(advertisingDiagnostics.state.rawValue),
            "host.advertising.bonjourPort": advertisingDiagnostics.bonjourPort.map { .int(Int($0)) } ?? .null,
            "host.advertising.directListenerPorts": .string(directListenerPorts),
            "host.advertising.lastBonjourFailure": advertisingDiagnostics.lastBonjourFailureDescription
                .map(MirageDiagnosticsValue.string) ?? .null,
            "host.advertising.lastBonjourFailureAt": advertisingDiagnostics.lastBonjourFailureAt
                .map { .string($0.ISO8601Format()) } ?? .null,
            "host.advertising.bonjourRecoveryAttempt": .int(advertisingDiagnostics.bonjourRecoveryAttempt),
            "host.loom.directDatagramServiceClass": .string(String(describing: loomNode.configuration.directDatagramServiceClass)),
            "host.loom.maxPacketSize": .int(loomNode.configuration.maxPacketSize),
            "host.serviceName": .string(serviceName),
            "host.advertisedHostName": advertisedPeerAdvertisement.hostName.map(MirageDiagnosticsValue.string) ?? .null,
            "host.directTransports": .string(directTransports),
            "host.remoteControlListenerReady": .bool(remoteControlListenerReady),
            "host.remoteControlPort": remoteControlPort.map { .int(Int($0)) } ?? .null,
        ]
    }
}
#endif
