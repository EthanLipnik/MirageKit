//
//  MirageClientService+Types.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

extension MirageClientService {
    struct StreamStartAcknowledgement: Equatable {
        let width: Int
        let height: Int
        let dimensionToken: UInt16?
    }
}

public extension MirageClientService {
    /// Policy for processing non-essential control messages during interactive streaming.
    enum ControlUpdatePolicy: Sendable {
        /// Process every control update immediately.
        case normal

        /// Defer non-essential refreshes while an interactive stream is active.
        case interactiveStreaming
    }

    /// Lightweight snapshot of a foreground stream's receiver health.
    struct ForegroundStreamHealthSnapshot: Sendable, Equatable {
        /// Stream being sampled.
        public let streamID: StreamID

        /// Whether the stream still has an active controller.
        public let hasController: Bool

        /// Whether the stream still has an attached video media stream.
        public let hasVideoMediaStream: Bool

        /// Last observed packet time in absolute seconds.
        public let latestPacketTime: CFAbsoluteTime

        /// Latest submitted packet sequence observed by the receiver.
        public let submittedSequence: UInt64

        /// Whether the receiver is waiting for a keyframe before decoding can continue.
        public let isAwaitingKeyframe: Bool

        /// Creates a foreground stream health snapshot.
        public init(
            streamID: StreamID,
            hasController: Bool,
            hasVideoMediaStream: Bool,
            latestPacketTime: CFAbsoluteTime,
            submittedSequence: UInt64,
            isAwaitingKeyframe: Bool
        ) {
            self.streamID = streamID
            self.hasController = hasController
            self.hasVideoMediaStream = hasVideoMediaStream
            self.latestPacketTime = latestPacketTime
            self.submittedSequence = submittedSequence
            self.isAwaitingKeyframe = isAwaitingKeyframe
        }
    }

    /// Control refreshes deferred while non-essential updates are suppressed.
    struct DeferredControlRefreshRequirements: Sendable {
        /// Whether the installed-app list should refresh after suppression ends.
        public var needsAppListRefresh: Bool

        /// Whether the window list should refresh after suppression ends.
        public var needsWindowListRefresh: Bool

        /// Whether host software-update status should refresh after suppression ends.
        public var needsHostSoftwareUpdateRefresh: Bool

        /// Empty deferred-refresh set.
        public static let none = DeferredControlRefreshRequirements(
            needsAppListRefresh: false,
            needsWindowListRefresh: false,
            needsHostSoftwareUpdateRefresh: false
        )
    }

    /// Source of a client-requested app stream stop.
    enum StreamStopOrigin: Sendable {
        /// The local client window closed.
        case clientWindowClosed

        /// A remote command requested the stream stop.
        case remoteCommand
    }

    /// User-facing app startup failure reported before an app stream becomes active.
    struct AppStreamStartupFailure: Sendable, Equatable, Codable {
        /// Bundle identifier for the app that failed to start, when known.
        public let bundleIdentifier: String?

        /// User-facing failure message.
        public let message: String

        /// Creates an app stream startup failure.
        public init(bundleIdentifier: String?, message: String) {
            self.bundleIdentifier = bundleIdentifier
            self.message = message
        }
    }

    /// Result returned after asking the host app to restart.
    struct HostApplicationRestartResult: Sendable, Equatable, Codable {
        /// Whether the host accepted the restart request.
        public let accepted: Bool

        /// User-facing result message from the host.
        public let message: String

        /// Creates a host application restart result.
        public init(
            accepted: Bool,
            message: String
        ) {
            self.accepted = accepted
            self.message = message
        }
    }

    /// Protocol mismatch details surfaced when session bootstrap rejects a connection.
    struct ProtocolMismatchInfo: Sendable, Equatable, Codable {
        /// Reason session bootstrap rejected the connection.
        public enum Reason: String, Sendable, Codable {
            /// Host and client wire protocol versions differ.
            case protocolVersionMismatch

            /// Host is currently refusing new clients.
            case hostBusy

            /// Host is in software-update maintenance mode.
            case hostUpdateInProgress

            /// Host rejected the connection without a more specific reason.
            case rejected

            /// Host rejected the requester as unauthorized.
            case unauthorized

            /// Host did not provide a recognized rejection reason.
            case unknown
        }

        /// Mapped rejection reason.
        public let reason: Reason

        /// Host protocol version reported in the rejection, when available.
        public let hostProtocolVersion: Int?

        /// Client protocol version echoed in the rejection, when available.
        public let clientProtocolVersion: Int?

        /// Creates protocol mismatch details for UI and diagnostics.
        public init(
            reason: Reason,
            hostProtocolVersion: Int?,
            clientProtocolVersion: Int?
        ) {
            self.reason = reason
            self.hostProtocolVersion = hostProtocolVersion
            self.clientProtocolVersion = clientProtocolVersion
        }
    }

    /// Trust and authorization state for the active or pending host connection.
    enum AuthorizationState: String, Sendable, Codable, Equatable {
        /// No host authorization flow is active.
        case idle

        /// The client is evaluating the host identity.
        case verifyingTrust

        /// The host is waiting for manual trust approval.
        case awaitingManualApproval

        /// The current host identity is trusted.
        case approved
    }

    /// High-level client connection lifecycle state.
    enum ConnectionState: Equatable {
        /// No host connection is active.
        case disconnected

        /// Transport connection is being established.
        case connecting

        /// Loom is connected and Mirage bootstrap is in progress.
        case handshaking(host: String)

        /// Mirage bootstrap accepted the session.
        case connected(host: String)

        /// Client is trying to recover a previous connection.
        case reconnecting

        /// Connection failed with a user-facing message.
        case error(String)

        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): true
            case (.connecting, .connecting): true
            case let (.handshaking(a), .handshaking(b)): a == b
            case let (.connected(a), .connected(b)): a == b
            case (.reconnecting, .reconnecting): true
            case let (.error(a), .error(b)): a == b
            default: false
            }
        }

        /// Whether this state allows starting a new connection.
        var canConnect: Bool {
            switch self {
            case .disconnected,
                 .error: true
            default: false
            }
        }
    }
}
