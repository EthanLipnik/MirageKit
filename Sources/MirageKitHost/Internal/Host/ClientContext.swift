//
//  ClientContext.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)

/// Context for a connected client including their connections
struct ClientContext {
    let client: MirageConnectedClient
    let tcpConnection: NWConnection
    var udpConnection: NWConnection?

    /// Check if connection is peer-to-peer (local network, low latency)
    /// Returns true when connected over local WiFi or Ethernet to a local network address
    var isPeerToPeer: Bool {
        Self.isPeerToPeerConnection(tcpConnection)
    }

    static func isPeerToPeerConnection(_ connection: NWConnection) -> Bool {
        guard let path = connection.currentPath else { return false }

        let isLocalInterface = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        guard isLocalInterface else { return false }

        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        return isLocalNetworkHost("\(host)")
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains(".local") { return true }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("[fe80:") { return true }

        guard let octets = parseIPv4Octets(from: normalized) else { return false }
        let first = octets[0]
        let second = octets[1]

        if first == 10 { return true }
        if first == 192 && second == 168 { return true }
        if first == 172 && (16 ... 31).contains(second) { return true }
        if first == 169 && second == 254 { return true }
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

    /// Send a control message over TCP
    func send(_ type: ControlMessageType, content: some Encodable) async throws {
        let message = try ControlMessage(type: type, content: content)
        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Queue a control message over TCP without awaiting contentProcessed.
    /// Returns false when the message cannot be encoded.
    @discardableResult
    func sendBestEffort(_ type: ControlMessageType, content: some Encodable) -> Bool {
        guard let message = try? ControlMessage(type: type, content: content) else { return false }
        tcpConnection.send(content: message.serialize(), completion: .idempotent)
        return true
    }

    /// Send video data over UDP
    func sendVideoPacket(_ data: Data) {
        udpConnection?.send(content: data, completion: .idempotent)
    }
}

#endif
