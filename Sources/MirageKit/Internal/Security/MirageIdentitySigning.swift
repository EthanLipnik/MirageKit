//
//  MirageIdentitySigning.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Canonical payload builders for signed Mirage identity messages.
//

import Foundation

package enum MirageIdentitySigning {
    package static func keyID(for publicKey: Data) -> String {
        MirageIdentityManager.keyID(for: publicKey)
    }

    package static func helloPayload(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        protocolVersion: Int,
        capabilities: MirageHostCapabilities,
        negotiation: MirageProtocolNegotiation,
        iCloudUserID: String?,
        keyID: String,
        publicKey: Data,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try canonicalData([
            ("type", "hello-v2"),
            ("deviceID", deviceID.uuidString.lowercased()),
            ("deviceName", deviceName),
            ("deviceType", deviceType.rawValue),
            ("protocolVersion", "\(protocolVersion)"),
            ("capabilities", try stableJSONBase64(capabilities)),
            ("negotiation", try stableJSONBase64(negotiation)),
            ("iCloudUserID", iCloudUserID ?? "-"),
            ("keyID", keyID),
            ("publicKey", publicKey.base64EncodedString()),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ])
    }

    package static func helloResponsePayload(
        accepted: Bool,
        hostID: UUID,
        hostName: String,
        requiresAuth: Bool,
        dataPort: UInt16,
        negotiation: MirageProtocolNegotiation,
        requestNonce: String,
        keyID: String,
        publicKey: Data,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try canonicalData([
            ("type", "hello-response-v2"),
            ("accepted", accepted ? "1" : "0"),
            ("hostID", hostID.uuidString.lowercased()),
            ("hostName", hostName),
            ("requiresAuth", requiresAuth ? "1" : "0"),
            ("dataPort", "\(dataPort)"),
            ("negotiation", try stableJSONBase64(negotiation)),
            ("requestNonce", requestNonce),
            ("keyID", keyID),
            ("publicKey", publicKey.base64EncodedString()),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ])
    }

    package static func workerRequestPayload(
        method: String,
        path: String,
        bodySHA256: String,
        keyID: String,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try canonicalData([
            ("type", "worker-request-v1"),
            ("method", method.uppercased()),
            ("path", path),
            ("bodySHA256", bodySHA256),
            ("keyID", keyID),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ])
    }

    package static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func canonicalData(_ fields: [(String, String)]) throws -> Data {
        let text = fields
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
        guard let data = text.data(using: .utf8) else {
            throw MirageError.protocolError("Failed to build canonical identity payload")
        }
        return data
    }

    private static func stableJSONBase64(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value).base64EncodedString()
    }
}
