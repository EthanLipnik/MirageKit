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
        guard let path = tcpConnection.currentPath else { return false }

        // Must be on WiFi or Ethernet (not cellular or other interface types)
        let isLocalInterface = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        guard isLocalInterface else { return false }

        // Check if remote endpoint is on local network
        guard case let .hostPort(host, _) = tcpConnection.endpoint else { return false }
        let hostString = "\(host)"

        // Check for private IPv4 ranges (RFC 1918) and link-local addresses
        return hostString.hasPrefix("192.168.") ||
            hostString.hasPrefix("10.") ||
            hostString.hasPrefix("172.16.") ||
            hostString.hasPrefix("172.17.") ||
            hostString.hasPrefix("172.18.") ||
            hostString.hasPrefix("172.19.") ||
            hostString.hasPrefix("172.2") ||
            hostString.hasPrefix("172.3") ||
            hostString.hasPrefix("169.254.") || // IPv4 link-local (AWDL/USB tether)
            hostString.contains(".local") || // mDNS/Bonjour
            hostString.hasPrefix("fe80:") // IPv6 link-local
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

    /// Send video data over UDP
    func sendVideoPacket(_ data: Data) {
        udpConnection?.send(content: data, completion: .idempotent)
    }
}

#endif
