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
        /// Host and client use incompatible Mirage wire protocol versions.
        case protocolVersionMismatch
        /// Host is already serving another client.
        case hostBusy
        /// Host is installing or preparing a software update.
        case hostUpdateInProgress
        /// Host rejected the connection without a more specific reason.
        case rejected
        /// Host trust or authentication policy rejected the client.
        case unauthorized
        /// The client used a remote route, but the host does not currently allow VPN Access.
        case remoteAccessDisabled
        /// Client requested takeover but is not trusted to take over a busy host.
        case takeoverRequiresTrustedRequester
        /// Local network policy or reachability blocked the control connection.
        case localNetworkBlocked
        /// Host could not decode or validate the Mirage bootstrap payload.
        case malformedBootstrap
        /// Rejection reason was not classified.
        case unknown
    }

    /// Machine-readable rejection reason.
    public let reason: Reason
    /// Host display name reported with the rejection, when available.
    public let hostName: String?
    /// Protocol version reported by the rejecting host, when known.
    public let hostProtocolVersion: Int?
    /// Protocol version used by the connecting client, when known.
    public let clientProtocolVersion: Int?
    /// User-facing recovery guidance supplied by the host or client classifier.
    public let recoveryHint: String?

    /// Creates structured rejection details for a failed host connection attempt.
    public init(
        reason: Reason,
        hostName: String? = nil,
        hostProtocolVersion: Int? = nil,
        clientProtocolVersion: Int? = nil,
        recoveryHint: String? = nil
    ) {
        self.reason = reason
        self.hostName = hostName
        self.hostProtocolVersion = hostProtocolVersion
        self.clientProtocolVersion = clientProtocolVersion
        self.recoveryHint = recoveryHint
    }

    /// Whether retrying the same connection attempt is expected to fail without user action.
    public var isTerminal: Bool {
        switch reason {
        case .protocolVersionMismatch,
             .hostBusy,
             .hostUpdateInProgress,
             .rejected,
             .unauthorized,
             .remoteAccessDisabled,
             .takeoverRequiresTrustedRequester,
             .localNetworkBlocked,
             .malformedBootstrap:
            true
        case .unknown:
            false
        }
    }

    /// Localized fallback message suitable for connection failure UI.
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
        case .hostBusy:
            return "\(hostPrefix)Host is already connected to another client."
        case .hostUpdateInProgress:
            return "\(hostPrefix)Host update is in progress."
        case .unauthorized:
            return "\(hostPrefix)Host rejected this device. Approve it in Mirage Host on the Mac."
        case .remoteAccessDisabled:
            return "\(hostPrefix)VPN Access is turned off on this Mac. Use the same local network or turn on VPN Access in Mirage Host."
        case .takeoverRequiresTrustedRequester:
            return "\(hostPrefix)Host is busy and takeover requires a trusted client."
        case .localNetworkBlocked:
            return "\(hostPrefix)Mirage can see the host but cannot open a control connection. Use the same local network, VPN Access, or turn on Proximity Connect in Network settings."
        case .malformedBootstrap:
            return "\(hostPrefix)The host could not finish setup with this device. Try again."
        case .rejected:
            return "\(hostPrefix)Connection rejected by host."
        case .unknown:
            return "\(hostPrefix)Connection rejected by host."
        }
    }
}

/// Shared Mirage error type used across client, host, protocol, and capture paths.
public enum MirageError: Error, LocalizedError {
    /// Host service is already advertising.
    case alreadyAdvertising
    /// Host service is not currently advertising.
    case notAdvertising
    /// Transport or control-channel connection failed.
    case connectionFailed(Error)
    /// Host rejected the connection attempt with structured details.
    case connectionRejected(MirageConnectionRejection)
    /// Authentication failed for the connection or request.
    case authenticationFailed
    /// Requested stream could not be found.
    case streamNotFound
    /// Requested host window could not be found.
    case windowNotFound
    /// Video or audio encoding failed.
    case encodingError(Error)
    /// Video or audio decoding failed.
    case decodingError(Error)
    /// Required system permission is not available.
    case permissionDenied
    /// Operation did not complete before its timeout.
    case timeout
    /// Mirage protocol validation failed with a diagnostic message.
    case protocolError(String)
    /// Capture setup failed with a diagnostic message.
    case captureSetupFailed(String)

    /// Localized error description for user-visible errors and diagnostics.
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
