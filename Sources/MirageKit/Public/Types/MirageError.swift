//
//  MirageError.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Shared Mirage error definitions.
//

import Foundation

/// Structured host-side rejection details for a Mirage connection attempt.
public struct MirageConnectionRejection: Sendable, Equatable, Codable {
    /// Machine-readable reason reported by the host or diagnosed by the client.
    public enum Reason: String, Sendable, Codable {
        case protocolVersionMismatch
        case protocolFeaturesMismatch
        case hostBusy
        case hostUpdateInProgress
        case rejected
        case unauthorized
        case takeoverRequiresTrustedRequester
        case localNetworkBlocked
        case malformedBootstrap
        case unknown
    }

    public let reason: Reason
    public let hostName: String?
    public let hostProtocolVersion: Int?
    public let clientProtocolVersion: Int?
    public let hostUpdateTriggerAccepted: Bool?
    public let hostUpdateTriggerMessage: String?
    public let recoveryHint: String?

    public init(
        reason: Reason,
        hostName: String? = nil,
        hostProtocolVersion: Int? = nil,
        clientProtocolVersion: Int? = nil,
        hostUpdateTriggerAccepted: Bool? = nil,
        hostUpdateTriggerMessage: String? = nil,
        recoveryHint: String? = nil
    ) {
        self.reason = reason
        self.hostName = hostName
        self.hostProtocolVersion = hostProtocolVersion
        self.clientProtocolVersion = clientProtocolVersion
        self.hostUpdateTriggerAccepted = hostUpdateTriggerAccepted
        self.hostUpdateTriggerMessage = hostUpdateTriggerMessage
        self.recoveryHint = recoveryHint
    }

    public var isTerminal: Bool {
        switch reason {
        case .protocolVersionMismatch,
             .protocolFeaturesMismatch,
             .hostBusy,
             .hostUpdateInProgress,
             .rejected,
             .unauthorized,
             .takeoverRequiresTrustedRequester,
             .localNetworkBlocked,
             .malformedBootstrap:
            true
        case .unknown:
            false
        }
    }

    public var userFacingMessage: String {
        if let recoveryHint,
           !recoveryHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recoveryHint
        }

        let hostDisplayName = hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPrefix = if let hostDisplayName, !hostDisplayName.isEmpty {
            "\(hostDisplayName): "
        } else {
            ""
        }

        switch reason {
        case .protocolVersionMismatch:
            let hostVersion = hostProtocolVersion.map(String.init) ?? "unknown"
            let clientVersion = clientProtocolVersion.map(String.init) ?? "unknown"
            return "\(hostPrefix)Mirage versions are incompatible. Host protocol \(hostVersion), client protocol \(clientVersion)."
        case .protocolFeaturesMismatch:
            return "\(hostPrefix)Mirage protocol features are incompatible. Update Mirage on both devices."
        case .hostBusy:
            return "\(hostPrefix)Host is already connected to another client."
        case .hostUpdateInProgress:
            return "\(hostPrefix)Host update is in progress."
        case .unauthorized:
            return "\(hostPrefix)Host rejected this device. Approve it in Mirage Host on the Mac."
        case .takeoverRequiresTrustedRequester:
            return "\(hostPrefix)Host is busy and takeover requires a trusted client."
        case .localNetworkBlocked:
            return "\(hostPrefix)Mirage can see the host but cannot open a control connection. Use the same local network, VPN Access, or turn on Proximity Connect in Network settings."
        case .malformedBootstrap:
            return "\(hostPrefix)The host received an incompatible Mirage handshake. Update Mirage on both devices."
        case .rejected:
            return "\(hostPrefix)Connection rejected by host."
        case .unknown:
            return "\(hostPrefix)Connection rejected by host."
        }
    }
}

public enum MirageError: Error, LocalizedError {
    case alreadyAdvertising
    case notAdvertising
    case connectionFailed(Error)
    case connectionRejected(MirageConnectionRejection)
    case authenticationFailed
    case streamNotFound
    case windowNotFound
    case encodingError(Error)
    case decodingError(Error)
    case permissionDenied
    case timeout
    case protocolError(String)
    case captureSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyAdvertising:
            "Already advertising service"
        case .notAdvertising:
            "Not currently advertising"
        case let .connectionFailed(error):
            "Connection failed: \(error.localizedDescription)"
        case let .connectionRejected(rejection):
            rejection.userFacingMessage
        case .authenticationFailed:
            "Authentication failed"
        case .streamNotFound:
            "Stream not found"
        case .windowNotFound:
            "Window not found"
        case let .encodingError(error):
            "Encoding error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Decoding error: \(error.localizedDescription)"
        case .permissionDenied:
            "Permission denied"
        case .timeout:
            "Operation timed out"
        case let .protocolError(message):
            "Protocol error: \(message)"
        case let .captureSetupFailed(message):
            "Capture setup failed: \(message)"
        }
    }
}
