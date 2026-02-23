//
//  MirageBootstrapControlProtocol.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Line-based JSON protocol used for host bootstrap daemon handoff.
//

import Foundation

/// Bootstrap control operation kind.
public enum MirageBootstrapControlOperation: String, Codable, Sendable {
    case status
    case unlock
}

/// Bootstrap control request payload sent to host bootstrap daemon.
public struct MirageBootstrapControlRequest: Codable, Sendable {
    /// Protocol schema version.
    public let version: Int
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Operation to execute.
    public let operation: MirageBootstrapControlOperation
    /// Username for unlock operations when login screen requires it.
    public let username: String?
    /// Password for unlock operations.
    public let password: String?

    public init(
        version: Int = 1,
        requestID: UUID = UUID(),
        operation: MirageBootstrapControlOperation,
        username: String? = nil,
        password: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
        self.username = username
        self.password = password
    }
}

/// Bootstrap control response payload returned by host bootstrap daemon.
public struct MirageBootstrapControlResponse: Codable, Sendable {
    /// Protocol schema version.
    public let version: Int
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Whether the requested operation succeeded.
    public let success: Bool
    /// Session state observed after operation.
    public let state: HostSessionState
    /// Human-readable message for diagnostics and remediation.
    public let message: String?
    /// Whether the request can be retried.
    public let canRetry: Bool
    /// Remaining retries available (if bounded by host policy).
    public let retriesRemaining: Int?
    /// Cooldown before retry is allowed.
    public let retryAfterSeconds: Int?

    public init(
        version: Int = 1,
        requestID: UUID,
        success: Bool,
        state: HostSessionState,
        message: String?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    ) {
        self.version = version
        self.requestID = requestID
        self.success = success
        self.state = state
        self.message = message
        self.canRetry = canRetry
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}
