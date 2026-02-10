//
//  MirageRemoteSignalingClient.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Signed Cloudflare signaling client for remote session presence and host advertisements.
//

import CryptoKit
import Foundation

/// Configuration for the remote signaling service endpoint.
public struct MirageRemoteSignalingConfiguration: Sendable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval

    public init(baseURL: URL, requestTimeout: TimeInterval = 5) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    public static var `default`: MirageRemoteSignalingConfiguration {
        MirageRemoteSignalingConfiguration(
            baseURL: URL(string: "https://mirage-remote-signaling.workers.dev") ?? URL(fileURLWithPath: "/"),
            requestTimeout: 5
        )
    }
}

/// Transport type for a remote connectivity candidate.
public enum MirageRemoteCandidateTransport: String, Sendable, Codable {
    case quic
}

/// Remote endpoint candidate published by signaling.
public struct MirageRemoteCandidate: Sendable, Codable, Hashable {
    public let transport: MirageRemoteCandidateTransport
    public let address: String
    public let port: UInt16

    public init(
        transport: MirageRemoteCandidateTransport,
        address: String,
        port: UInt16
    ) {
        self.transport = transport
        self.address = address
        self.port = port
    }
}

/// Presence state returned by remote signaling.
public struct MirageRemotePresenceStatus: Sendable {
    public let exists: Bool
    public let remoteEnabled: Bool
    public let hostCandidates: [MirageRemoteCandidate]
    public let lockedToClientKeyID: String?
    public let expiresAt: Date?
    public let lastHostSeen: Date?
    public let lastClientSeen: Date?

    public init(
        exists: Bool,
        remoteEnabled: Bool,
        hostCandidates: [MirageRemoteCandidate] = [],
        lockedToClientKeyID: String? = nil,
        expiresAt: Date? = nil,
        lastHostSeen: Date? = nil,
        lastClientSeen: Date? = nil
    ) {
        self.exists = exists
        self.remoteEnabled = remoteEnabled
        self.hostCandidates = hostCandidates
        self.lockedToClientKeyID = lockedToClientKeyID
        self.expiresAt = expiresAt
        self.lastHostSeen = lastHostSeen
        self.lastClientSeen = lastClientSeen
    }
}

/// Remote signaling errors.
public enum MirageRemoteSignalingError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case invalidPayload
    case http(statusCode: Int, errorCode: String?, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Remote signaling configuration is invalid"
        case .invalidResponse:
            "Remote signaling returned an invalid response"
        case .invalidPayload:
            "Remote signaling returned an invalid payload"
        case let .http(statusCode, errorCode, detail):
            if let errorCode, let detail {
                "Remote signaling error (\(statusCode)): \(errorCode) - \(detail)"
            } else if let errorCode {
                "Remote signaling error (\(statusCode)): \(errorCode)"
            } else {
                "Remote signaling request failed with status \(statusCode)"
            }
        }
    }
}

/// Signed signaling API wrapper used by host and client remote coordination.
@MainActor
public final class MirageRemoteSignalingClient {
    private let configuration: MirageRemoteSignalingConfiguration
    private let identityManager: MirageIdentityManager
    private let urlSession: URLSession

    public init(
        configuration: MirageRemoteSignalingConfiguration = .default,
        identityManager: MirageIdentityManager = .shared,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.urlSession = urlSession
    }

    /// Ensures a host session is advertised in signaling.
    ///
    /// On an existing session this updates liveness through heartbeat.
    public func advertiseHostSession(
        sessionID: String,
        hostID: UUID,
        remoteEnabled: Bool,
        hostCandidates: [MirageRemoteCandidate],
        ttlSeconds: Int = 120
    )
    async throws {
        do {
            try await createHostSession(
                sessionID: sessionID,
                hostID: hostID,
                remoteEnabled: remoteEnabled,
                hostCandidates: hostCandidates,
                ttlSeconds: ttlSeconds
            )
        } catch let error as MirageRemoteSignalingError {
            if case let .http(_, errorCode, _) = error, errorCode == "session_exists" {
                try await hostHeartbeat(
                    sessionID: sessionID,
                    remoteEnabled: remoteEnabled,
                    hostCandidates: hostCandidates,
                    ttlSeconds: ttlSeconds
                )
                return
            }
            throw error
        }
    }

    /// Sends a host heartbeat to maintain presence.
    public func hostHeartbeat(
        sessionID: String,
        remoteEnabled: Bool? = nil,
        hostCandidates: [MirageRemoteCandidate]? = nil,
        ttlSeconds: Int? = nil
    )
    async throws {
        var body: [String: Any] = ["role": "host"]
        if let remoteEnabled {
            body["remoteEnabled"] = remoteEnabled
        }
        if let hostCandidates {
            body["hostCandidates"] = encodeCandidates(hostCandidates)
        }
        if let ttlSeconds {
            body["ttlSeconds"] = ttlSeconds
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/heartbeat",
            bodyData: bodyData
        )
    }

    /// Closes a host signaling session.
    public func closeHostSession(sessionID: String) async throws {
        let body = ["role": "host"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/close",
            bodyData: bodyData
        )
    }

    /// Joins a host session and reserves the single-client signaling lock.
    public func joinSession(sessionID: String) async throws {
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/join",
            bodyData: Data("{}".utf8)
        )
    }

    /// Releases a joined client lock for a session.
    public func leaveSession(sessionID: String) async throws {
        let body: [String: Any] = ["role": "client"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/close",
            bodyData: bodyData
        )
    }

    /// Fetches remote presence state for a host session.
    public func fetchPresence(sessionID: String) async throws -> MirageRemotePresenceStatus {
        let (_, data) = try await sendSignedRequest(
            sessionID: sessionID,
            method: "GET",
            path: "/v1/session/presence",
            bodyData: nil
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MirageRemoteSignalingError.invalidPayload
        }
        let exists = object["exists"] as? Bool ?? false
        return MirageRemotePresenceStatus(
            exists: exists,
            remoteEnabled: object["remoteEnabled"] as? Bool ?? false,
            hostCandidates: parseCandidates(object["hostCandidates"]),
            lockedToClientKeyID: object["lockedToClientKeyID"] as? String,
            expiresAt: dateFromMilliseconds(object["expiresAtMs"]),
            lastHostSeen: dateFromMilliseconds(object["lastHostSeenMs"]),
            lastClientSeen: dateFromMilliseconds(object["lastClientSeenMs"])
        )
    }

    private func createHostSession(
        sessionID: String,
        hostID: UUID,
        remoteEnabled: Bool,
        hostCandidates: [MirageRemoteCandidate],
        ttlSeconds: Int
    )
    async throws {
        let body: [String: Any] = [
            "hostID": hostID.uuidString.lowercased(),
            "ttlSeconds": ttlSeconds,
            "remoteEnabled": remoteEnabled,
            "hostCandidates": encodeCandidates(hostCandidates),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendSignedRequest(
            sessionID: sessionID,
            method: "POST",
            path: "/v1/session/create",
            bodyData: bodyData
        )
    }

    private func sendSignedRequest(
        sessionID: String,
        method: String,
        path: String,
        bodyData: Data?
    )
    async throws -> (HTTPURLResponse, Data) {
        guard configuration.baseURL.scheme == "https" || configuration.baseURL.scheme == "http" else {
            throw MirageRemoteSignalingError.invalidConfiguration
        }
        let identity = try identityManager.currentIdentity()
        let nonce = UUID().uuidString.lowercased()
        let timestampMs = MirageIdentitySigning.currentTimestampMs()
        let bodyHash = Self.sha256Hex(bodyData ?? Data("-".utf8))
        let payload = try MirageIdentitySigning.workerRequestPayload(
            method: method,
            path: path,
            bodySHA256: bodyHash,
            keyID: identity.keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let signature = try identityManager.sign(payload)

        let url = configuration.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(sessionID, forHTTPHeaderField: "x-mirage-session-id")
        request.setValue(identity.keyID, forHTTPHeaderField: "x-mirage-key-id")
        request.setValue(identity.publicKey.base64EncodedString(), forHTTPHeaderField: "x-mirage-public-key")
        request.setValue("\(timestampMs)", forHTTPHeaderField: "x-mirage-timestamp-ms")
        request.setValue(nonce, forHTTPHeaderField: "x-mirage-nonce")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "x-mirage-signature")
        request.setValue(bodyHash, forHTTPHeaderField: "x-mirage-body-sha256")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MirageRemoteSignalingError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let parsed = parseErrorPayload(data)
            throw MirageRemoteSignalingError.http(
                statusCode: http.statusCode,
                errorCode: parsed.errorCode,
                detail: parsed.detail
            )
        }

        return (http, data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    private func encodeCandidates(_ candidates: [MirageRemoteCandidate]) -> [[String: Any]] {
        candidates.map { candidate in
            [
                "transport": candidate.transport.rawValue,
                "address": candidate.address,
                "port": Int(candidate.port),
            ]
        }
    }
}

private func parseErrorPayload(_ data: Data) -> (errorCode: String?, detail: String?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (nil, nil)
    }
    return (
        object["error"] as? String,
        object["detail"] as? String
    )
}

private func dateFromMilliseconds(_ rawValue: Any?) -> Date? {
    if let value = rawValue as? Int {
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
    if let value = rawValue as? Int64 {
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
    if let value = rawValue as? Double {
        return Date(timeIntervalSince1970: value / 1000)
    }
    return nil
}

private func parseCandidates(_ rawValue: Any?) -> [MirageRemoteCandidate] {
    guard let array = rawValue as? [[String: Any]] else {
        return []
    }
    return array.compactMap { candidateObject in
        guard let transportRaw = candidateObject["transport"] as? String,
              let transport = MirageRemoteCandidateTransport(rawValue: transportRaw),
              let address = candidateObject["address"] as? String else {
            return nil
        }

        if let intPort = candidateObject["port"] as? Int,
           let port = UInt16(exactly: intPort) {
            return MirageRemoteCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        if let int64Port = candidateObject["port"] as? Int64,
           let port = UInt16(exactly: int64Port) {
            return MirageRemoteCandidate(
                transport: transport,
                address: address,
                port: port
            )
        }

        return nil
    }
}
