//
//  MirageStunProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Direct STUN probe utilities for remote connectivity preflight.
//

import Foundation
import Network

/// Result of a direct STUN reachability probe.
public struct MirageStunProbeResult: Sendable {
    public let reachable: Bool
    public let mappedAddress: String?
    public let mappedPort: UInt16?
    public let failureReason: String?

    public init(
        reachable: Bool,
        mappedAddress: String? = nil,
        mappedPort: UInt16? = nil,
        failureReason: String? = nil
    ) {
        self.reachable = reachable
        self.mappedAddress = mappedAddress
        self.mappedPort = mappedPort
        self.failureReason = failureReason
    }
}

/// STUN probe entry point for remote preflight.
public enum MirageStunProbe {
    /// Sends a STUN binding request and parses XOR-MAPPED-ADDRESS if available.
    public static func run(
        host: String = "stun.cloudflare.com",
        port: UInt16 = 3478,
        localPort: UInt16? = nil,
        timeout: Duration = .seconds(2)
    )
    async -> MirageStunProbeResult {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return MirageStunProbeResult(reachable: false, failureReason: "invalid_port")
        }

        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        parameters.allowLocalEndpointReuse = true
        if let localPort {
            guard let requiredPort = NWEndpoint.Port(rawValue: localPort) else {
                return MirageStunProbeResult(reachable: false, failureReason: "invalid_local_port")
            }
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.any),
                port: requiredPort
            )
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )

        do {
            try await waitForReady(connection, timeout: timeout)

            let transactionID = randomTransactionID()
            let request = buildBindingRequest(transactionID: transactionID)
            try await send(connection, content: request, timeout: timeout)
            let response = try await receive(connection, timeout: timeout)
            connection.cancel()

            if let parsed = parseBindingResponse(response, expectedTransactionID: transactionID) {
                return MirageStunProbeResult(
                    reachable: true,
                    mappedAddress: parsed.address,
                    mappedPort: parsed.port
                )
            }

            return MirageStunProbeResult(reachable: false, failureReason: "invalid_stun_response")
        } catch {
            connection.cancel()
            return MirageStunProbeResult(reachable: false, failureReason: error.localizedDescription)
        }
    }
}

private enum MirageStunProbeError: LocalizedError {
    case timeout
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            "timeout"
        case let .connectionFailed(reason):
            "connection_failed:\(reason)"
        case let .sendFailed(reason):
            "send_failed:\(reason)"
        case let .receiveFailed(reason):
            "receive_failed:\(reason)"
        }
    }
}

private final class ProbeCompletionFlag: @unchecked Sendable {
    private var completed = false
    private let lock = NSLock()

    func completeOnce() -> Bool {
        lock.withLock {
            if completed { return false }
            completed = true
            return true
        }
    }
}

private func waitForReady(_ connection: NWConnection, timeout: Duration) async throws {
    let flag = ProbeCompletionFlag()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if flag.completeOnce() {
                    continuation.resume()
                }
            case let .failed(error):
                if flag.completeOnce() {
                    continuation.resume(throwing: MirageStunProbeError.connectionFailed(error.localizedDescription))
                }
            case .cancelled:
                if flag.completeOnce() {
                    continuation.resume(throwing: MirageStunProbeError.connectionFailed("cancelled"))
                }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))

        Task {
            try? await Task.sleep(for: timeout)
            if flag.completeOnce() {
                continuation.resume(throwing: MirageStunProbeError.timeout)
                connection.cancel()
            }
        }
    }
}

private func send(_ connection: NWConnection, content: Data, timeout: Duration) async throws {
    let flag = ProbeCompletionFlag()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: content, completion: .contentProcessed { error in
            if !flag.completeOnce() {
                return
            }
            if let error {
                continuation.resume(throwing: MirageStunProbeError.sendFailed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        })

        Task {
            try? await Task.sleep(for: timeout)
            if flag.completeOnce() {
                continuation.resume(throwing: MirageStunProbeError.timeout)
                connection.cancel()
            }
        }
    }
}

private func receive(_ connection: NWConnection, timeout: Duration) async throws -> Data {
    let flag = ProbeCompletionFlag()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        connection.receiveMessage { data, _, _, error in
            if !flag.completeOnce() {
                return
            }
            if let error {
                continuation.resume(throwing: MirageStunProbeError.receiveFailed(error.localizedDescription))
                return
            }
            guard let data, !data.isEmpty else {
                continuation.resume(throwing: MirageStunProbeError.receiveFailed("empty"))
                return
            }
            continuation.resume(returning: data)
        }

        Task {
            try? await Task.sleep(for: timeout)
            if flag.completeOnce() {
                continuation.resume(throwing: MirageStunProbeError.timeout)
                connection.cancel()
            }
        }
    }
}

private func randomTransactionID() -> Data {
    var bytes = [UInt8](repeating: 0, count: 12)
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0 ... 255)
    }
    return Data(bytes)
}

private func buildBindingRequest(transactionID: Data) -> Data {
    var data = Data()
    appendUInt16(0x0001, into: &data) // Binding request
    appendUInt16(0x0000, into: &data) // No attributes
    appendUInt32(0x2112A442, into: &data) // Magic cookie
    data.append(transactionID)
    return data
}

private func appendUInt16(_ value: UInt16, into data: inout Data) {
    let be = value.bigEndian
    data.append(contentsOf: withUnsafeBytes(of: be) { Array($0) })
}

private func appendUInt32(_ value: UInt32, into data: inout Data) {
    let be = value.bigEndian
    data.append(contentsOf: withUnsafeBytes(of: be) { Array($0) })
}

private func parseBindingResponse(
    _ data: Data,
    expectedTransactionID: Data
) -> (address: String, port: UInt16)? {
    guard data.count >= 20 else {
        return nil
    }

    let messageType = readUInt16(data, at: 0)
    guard messageType == 0x0101 else {
        return nil
    }

    let messageLength = Int(readUInt16(data, at: 2))
    let messageEnd = 20 + messageLength
    guard data.count >= messageEnd else {
        return nil
    }

    let cookie = readUInt32(data, at: 4)
    guard cookie == 0x2112A442 else {
        return nil
    }

    let transactionID = data.subdata(in: 8 ..< 20)
    guard transactionID == expectedTransactionID else {
        return nil
    }

    var offset = 20
    while offset + 4 <= messageEnd {
        let attributeType = readUInt16(data, at: offset)
        let attributeLength = Int(readUInt16(data, at: offset + 2))
        let valueStart = offset + 4
        let valueEnd = valueStart + attributeLength
        guard valueEnd <= messageEnd else {
            return nil
        }

        let value = data.subdata(in: valueStart ..< valueEnd)
        if attributeType == 0x0020 || attributeType == 0x0001 {
            if let parsed = parseMappedAddress(
                attributeType: attributeType,
                value: value,
                transactionID: expectedTransactionID
            ) {
                return parsed
            }
        }

        let paddedLength = (attributeLength + 3) & ~3
        offset = valueStart + paddedLength
    }

    return nil
}

private func parseMappedAddress(
    attributeType: UInt16,
    value: Data,
    transactionID: Data
) -> (address: String, port: UInt16)? {
    guard value.count >= 4 else {
        return nil
    }

    let family = value[1]
    let rawPort = readUInt16(value, at: 2)
    let isXor = attributeType == 0x0020
    let port: UInt16 = isXor ? (rawPort ^ 0x2112) : rawPort

    switch family {
    case 0x01:
        guard value.count >= 8 else {
            return nil
        }
        var bytes = [UInt8](value[4 ..< 8])
        if isXor {
            let cookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
            for index in 0 ..< 4 {
                bytes[index] ^= cookieBytes[index]
            }
        }
        let address = bytes.map(String.init).joined(separator: ".")
        return (address, port)

    case 0x02:
        guard value.count >= 20 else {
            return nil
        }
        var bytes = [UInt8](value[4 ..< 20])
        if isXor {
            let cookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
            let txBytes = [UInt8](transactionID)
            for index in 0 ..< 4 {
                bytes[index] ^= cookieBytes[index]
            }
            for index in 4 ..< 16 {
                bytes[index] ^= txBytes[index - 4]
            }
        }
        if let address = IPv6Address(Data(bytes)) {
            return (String(describing: address), port)
        }
        return nil

    default:
        return nil
    }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    let first = UInt16(data[offset])
    let second = UInt16(data[offset + 1])
    return (first << 8) | second
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let first = UInt32(data[offset])
    let second = UInt32(data[offset + 1])
    let third = UInt32(data[offset + 2])
    let fourth = UInt32(data[offset + 3])
    return (first << 24) | (second << 16) | (third << 8) | fourth
}
