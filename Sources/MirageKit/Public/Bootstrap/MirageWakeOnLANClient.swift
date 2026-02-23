//
//  MirageWakeOnLANClient.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Wake-on-LAN runtime for host bootstrap.
//

import Foundation
import Network

/// Wake-on-LAN failures.
public enum MirageWakeOnLANError: LocalizedError, Sendable {
    case invalidMACAddress
    case noBroadcastTargets
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            "Wake-on-LAN failed: MAC address is invalid."
        case .noBroadcastTargets:
            "Wake-on-LAN failed: no broadcast targets are available."
        case let .sendFailed(detail):
            "Wake-on-LAN failed: \(detail)"
        }
    }
}

/// Sends Wake-on-LAN magic packets to configured broadcast targets.
public protocol MirageWakeOnLANClient: Sendable {
    func sendMagicPacket(
        _ wakeInfo: MirageWakeOnLANInfo,
        retries: Int,
        retryDelay: Duration
    ) async throws
}

/// Default Wake-on-LAN sender used by bootstrap coordinator.
public final class MirageDefaultWakeOnLANClient: MirageWakeOnLANClient {
    public init() {}

    public func sendMagicPacket(
        _ wakeInfo: MirageWakeOnLANInfo,
        retries: Int = 2,
        retryDelay: Duration = .milliseconds(400)
    )
    async throws {
        let packet = try Self.magicPacketData(for: wakeInfo.macAddress)
        let targets = wakeInfo.broadcastAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { throw MirageWakeOnLANError.noBroadcastTargets }

        let attempts = max(1, retries + 1)
        var lastError: Error?

        for attempt in 1 ... attempts {
            do {
                try await send(packet: packet, to: targets)
                return
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(for: retryDelay)
                }
            }
        }

        let detail = lastError.map { String(describing: $0) } ?? "unknown send error"
        throw MirageWakeOnLANError.sendFailed(detail)
    }

    private func send(packet: Data, to targets: [String]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    let port = NWEndpoint.Port(rawValue: 9) ?? .any
                    let host = NWEndpoint.Host(target)
                    let connection = NWConnection(
                        host: host,
                        port: port,
                        using: .udp
                    )
                    connection.start(queue: .global(qos: .utility))
                    defer { connection.cancel() }

                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(content: packet, completion: .contentProcessed { error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        })
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Builds standard WOL magic packet for a MAC address.
    public static func magicPacketData(for macAddress: String) throws -> Data {
        let separators = CharacterSet(charactersIn: ":-.")
        let compact = macAddress.unicodeScalars.filter { !separators.contains($0) }
        let normalized = String(String.UnicodeScalarView(compact))

        guard normalized.count == 12 else { throw MirageWakeOnLANError.invalidMACAddress }
        var macBytes: [UInt8] = []
        macBytes.reserveCapacity(6)

        var index = normalized.startIndex
        for _ in 0 ..< 6 {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteText = normalized[index ..< nextIndex]
            guard let byte = UInt8(byteText, radix: 16) else {
                throw MirageWakeOnLANError.invalidMACAddress
            }
            macBytes.append(byte)
            index = nextIndex
        }

        var payload = Data(repeating: 0xFF, count: 6)
        for _ in 0 ..< 16 {
            payload.append(contentsOf: macBytes)
        }
        return payload
    }
}
