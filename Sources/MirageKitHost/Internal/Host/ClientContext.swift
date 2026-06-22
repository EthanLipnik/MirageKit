//
//  ClientContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
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
import Loom
import Network

#if os(macOS)

/// Runtime context for a connected client and its negotiated control channel.
struct ClientContext {
    /// Stable connection session identifier assigned by the host.
    let sessionID: UUID
    /// Public client identity advertised during bootstrap.
    let client: MirageConnectedClient
    /// Ordered control transport used for host-to-client messages.
    let controlChannel: MirageControlChannel
    /// Session-scoped transfer engine for bulk objects on this client session.
    let transferEngine: MirageTransferEngine
    /// Loom network-path metadata captured when the session was accepted.
    let pathSnapshot: LoomSessionNetworkPathSnapshot?

    init(
        sessionID: UUID,
        client: MirageConnectedClient,
        controlChannel: MirageControlChannel,
        transferEngine: MirageTransferEngine,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) {
        self.sessionID = sessionID
        self.client = client
        self.controlChannel = controlChannel
        self.transferEngine = transferEngine
        self.pathSnapshot = pathSnapshot
    }

    /// Returns whether a control session appears to be on the local peer-to-peer path.
    static func isPeerToPeerConnection(
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) -> Bool {
        guard let pathSnapshot else { return false }

        let isLocalInterface = pathSnapshot.usesWiFi ||
            pathSnapshot.usesWiredEthernet ||
            pathSnapshot.usesLoopback ||
            pathSnapshot.interfaceNames.contains(where: Self.isLocalProximityInterfaceName(_:))
        guard isLocalInterface else { return false }

        guard case let .hostPort(host, _) = remoteEndpoint ?? pathSnapshot.remoteEndpoint else { return false }
        return isLocalNetworkHost("\(host)")
    }

    private static func isLocalProximityInterfaceName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("anpi") ||
            normalized.hasPrefix("apni") ||
            normalized.hasPrefix("awdl") ||
            normalized.hasPrefix("llw") ||
            normalized.hasPrefix("bridge")
    }

    /// Returns whether a host string identifies a local-link or private-network endpoint.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" { return true }
        if normalized.contains(".local") { return true }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("[fe80:") { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("[fc") { return true }
        if normalized.hasPrefix("fd") || normalized.hasPrefix("[fd") { return true }

        guard let octets = parseIPv4Octets(from: normalized) else { return false }
        guard let first = octets.first,
              let second = octets.dropFirst().first else {
            return false
        }

        if first == 127 { return true }
        if first == 10 { return true }
        if first == 192, second == 168 { return true }
        if first == 172, (16 ... 31).contains(second) { return true }
        if first == 169, second == 254 { return true }
        return false
    }

    private static func parseIPv4Octets(from text: String) -> [UInt8]? {
        let tokens = text.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)

        for token in tokens {
            guard let value = UInt8(token) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Sends an encoded control payload over the reliable control channel.
    func send(_ type: MirageWire.ControlMessageType, content: some Encodable) async throws {
        let message = try MirageWire.ControlMessage(type: type, content: content)
        try await controlChannel.send(message)
    }

    /// Sends a prebuilt control message over the reliable control channel.
    func send(_ message: MirageWire.ControlMessage) async throws {
        try await controlChannel.send(message)
    }

    /// Queues an encoded control payload without waiting for transport completion.
    /// Preferred for high-frequency real-time interaction updates where latest-state wins.
    /// Returns false when the message cannot be encoded.
    func sendBestEffort(_ type: MirageWire.ControlMessageType, content: some Encodable) -> Bool {
        guard let message = try? MirageWire.ControlMessage(type: type, content: content) else { return false }
        controlChannel.sendBestEffort(message)
        return true
    }

    /// Queues an encoded control payload when the caller does not need send eligibility.
    func queueBestEffort(_ type: MirageWire.ControlMessageType, content: some Encodable) {
        _ = sendBestEffort(type, content: content)
    }

    /// Queues a no-payload control message without waiting for transport completion.
    func sendBestEffort(_ type: MirageWire.ControlMessageType) {
        controlChannel.sendBestEffort(type)
    }

    /// Queues a prebuilt control message without waiting for transport completion.
    func sendBestEffort(_ message: MirageWire.ControlMessage) {
        controlChannel.sendBestEffort(message)
    }
}

#endif
