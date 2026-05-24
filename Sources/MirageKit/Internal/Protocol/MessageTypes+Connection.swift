//
//  MessageTypes+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Connection Messages

/// Reason a host rejected a session bootstrap request.
package enum MirageSessionBootstrapRejectionReason: String, Codable {
    /// Client and host use incompatible protocol versions.
    case protocolVersionMismatch

    /// The host is already serving another client.
    case hostBusy

    /// The host is installing or preparing a software update.
    case hostUpdateInProgress

    /// The host rejected the connection without a more specific reason.
    case rejected

    /// Authentication or trust policy denied the client.
    case unauthorized

    /// A busy-host takeover was requested by a client that is not trusted to take over.
    case takeoverRequiresTrustedRequester
}

/// Initial client-to-host bootstrap payload sent before normal control traffic begins.
package struct MirageSessionBootstrapRequest: Codable {
    /// Client protocol version.
    package let protocolVersion: Int

    /// Whether the client requires encrypted media payloads for the session.
    package let clientRequiresMediaEncryption: Bool

    /// Whether the host may disconnect an existing client to accept this request.
    package let requestTakeoverIfBusy: Bool

    /// Creates a bootstrap request for protocol validation and media-encryption policy.
    package init(
        protocolVersion: Int,
        clientRequiresMediaEncryption: Bool,
        requestTakeoverIfBusy: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.clientRequiresMediaEncryption = clientRequiresMediaEncryption
        self.requestTakeoverIfBusy = requestTakeoverIfBusy
    }
}

/// Host-to-client response for session bootstrap.
package struct MirageSessionBootstrapResponse: Codable {
    /// Whether the host accepted the session.
    package let accepted: Bool

    /// Stable host identifier for the accepted session.
    package let hostID: UUID

    /// Display name for the host.
    package let hostName: String

    /// Whether media payload encryption is required for this session.
    package let mediaEncryptionEnabled: Bool

    /// Auth token required for datagram registration packets.
    package let datagramRegistrationToken: Data

    /// True when the host trust provider indicates a one-time auto-trust notice is appropriate.
    package let autoTrustGranted: Bool

    /// True when the host allows this client to reuse host-published off-LAN reachability metadata.
    package let remoteAccessAllowed: Bool

    /// Explicit rejection reason when `accepted` is false.
    package let rejectionReason: MirageSessionBootstrapRejectionReason?

    /// Optional metadata for protocol mismatch handling.
    package let protocolMismatchHostVersion: Int?

    /// Client protocol version observed by the host when rejecting for mismatch.
    package let protocolMismatchClientVersion: Int?

    /// Creates a bootstrap response for either an accepted or rejected session.
    package init(
        accepted: Bool,
        hostID: UUID,
        hostName: String,
        mediaEncryptionEnabled: Bool,
        datagramRegistrationToken: Data,
        autoTrustGranted: Bool = false,
        remoteAccessAllowed: Bool = false,
        rejectionReason: MirageSessionBootstrapRejectionReason? = nil,
        protocolMismatchHostVersion: Int? = nil,
        protocolMismatchClientVersion: Int? = nil
    ) {
        self.accepted = accepted
        self.hostID = hostID
        self.hostName = hostName
        self.mediaEncryptionEnabled = mediaEncryptionEnabled
        self.datagramRegistrationToken = datagramRegistrationToken
        self.autoTrustGranted = autoTrustGranted
        self.remoteAccessAllowed = remoteAccessAllowed
        self.rejectionReason = rejectionReason
        self.protocolMismatchHostVersion = protocolMismatchHostVersion
        self.protocolMismatchClientVersion = protocolMismatchClientVersion
    }
}

/// Control message explaining why a session is being disconnected.
package struct DisconnectMessage: Codable {
    /// Machine-readable disconnect reason.
    package let reason: DisconnectReason

    /// Reason a host or client is closing the control session.
    package enum DisconnectReason: String, Codable {
        /// A user explicitly requested disconnection.
        case userRequested

        /// The peer exceeded an inactivity or handshake timeout.
        case timeout

        /// The session closed because of an error.
        case error

        /// The host process is shutting down.
        case hostShutdown

        /// The host is disconnecting to perform a software update.
        case hostUpdateInProgress

        /// Authentication or trust validation failed.
        case authFailed

        /// Another trusted client took over the host session.
        case takenOver

        /// The client's background connection lease expired.
        case backgroundLeaseExpired
    }

    /// Creates a disconnect message with a concrete reason.
    package init(reason: DisconnectReason) {
        self.reason = reason
    }
}

/// Request to refresh media transport registration or path metadata.
package struct TransportRefreshRequestMessage: Codable {
    /// Stream that needs refreshed transport state, or `nil` for session-wide refresh.
    package let streamID: StreamID?

    /// Diagnostic reason for requesting the refresh.
    package let reason: String

    /// Creates a transport refresh request.
    package init(
        streamID: StreamID?,
        reason: String
    ) {
        self.streamID = streamID
        self.reason = reason
    }
}

/// Lease granted to let a client keep the control session alive briefly while backgrounded.
package struct ClientBackgroundLeaseMessage: Codable, Equatable {
    /// Unique identifier for this lease grant.
    package let leaseID: UUID

    /// Lease duration in seconds.
    package let durationSeconds: TimeInterval

    /// Creates a background lease grant.
    package init(
        leaseID: UUID = UUID(),
        durationSeconds: TimeInterval
    ) {
        self.leaseID = leaseID
        self.durationSeconds = durationSeconds
    }
}
