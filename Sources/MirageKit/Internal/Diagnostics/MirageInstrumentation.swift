//
//  MirageInstrumentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Foundation
import Loom

package enum MirageHelloRejectionStepReason: String, Sendable, Equatable {
    case protocolVersionMismatch = "protocol_version_mismatch"
    case protocolFeaturesMismatch = "protocol_features_mismatch"
    case hostBusy = "host_busy"
    case rejected
    case unauthorized
    case unknown

    package init(name: String) {
        self = Self(rawValue: name) ?? .unknown
    }
}

package enum MirageClientHelloValidationStepReason: String, Sendable, Equatable {
    case missingPendingNonce = "missing_pending_nonce"
    case mismatchedNonce = "mismatched_nonce"
    case invalidHostKeyID = "invalid_host_key_id"
    case replayDetected = "replay_detected"
    case invalidHostSignature = "invalid_host_signature"
    case hostIdentityMismatch = "host_identity_mismatch"
    case mediaEncryptionRequired = "media_encryption_required"
    case invalidUDPRegistrationToken = "invalid_udp_registration_token"
    case missingLocalIdentity = "missing_local_identity"
    case mediaKeyDerivationFailed = "media_key_derivation_failed"
    case protocolVersionMismatch = "protocol_version_mismatch"
    case protocolFeaturesMismatch = "protocol_features_mismatch"
}

package enum MirageUnlockResponseStepOutcome: String, Sendable, Equatable {
    case success
    case failure
}

package enum MirageConnectionApprovalStepResult: String, Sendable, Equatable {
    case accepted
    case rejected
    case connectionClosed = "connection_closed"
    case timedOut = "timed_out"
}

package enum MiragePerformanceModeStep: String, Sendable, Equatable {
    case standard
    case game

    package init(rawMode: String) {
        self = Self(rawValue: rawMode) ?? .standard
    }
}

package enum MirageUnlockRejectionStepReason: String, Sendable, Equatable {
    case remoteUnlockDisabled = "remote_unlock_disabled"
    case notAuthorized = "not_authorized"
    case invalidRequestFormat = "invalid_request_format"
    case sessionTokenExpired = "session_token_expired"
}

package enum MirageUnlockFailureStepCode: String, Sendable, Equatable {
    case invalidCredentials
    case rateLimited
    case sessionExpired
    case notLocked
    case notSupported
    case notAuthorized
    case timeout
    case internalError
    case unknown

    package init(name: String) {
        self = Self(rawValue: name) ?? .unknown
    }
}

package enum MirageStepEvent: Sendable, Equatable {
    case clientHelloSent
    case clientConnectionRequested
    case clientConnectionEstablished
    case clientConnectionFailed
    case clientConnectionDisconnected
    case clientUnlockRequested
    case clientHelloAccepted
    case clientHelloRejected(MirageHelloRejectionStepReason)
    case clientHelloDecodeFailed
    case clientUnlockResponse(MirageUnlockResponseStepOutcome)
    case clientHelloInvalid(MirageClientHelloValidationStepReason)

    case hostConnectionIncoming
    case hostHelloRejected(MirageHelloRejectionStepReason)
    case hostConnectionApprovalResult(MirageConnectionApprovalStepResult)
    case hostHelloAccepted
    case hostClientConnected
    case hostHelloReceived
    case hostStreamWindowStartedPerformanceMode(MiragePerformanceModeStep)
    case hostStreamDesktopStartedPerformanceMode(MiragePerformanceModeStep)
    case hostClientDisconnected
    case hostUnlockRequested
    case hostUnlockRejected(MirageUnlockRejectionStepReason)
    case hostUnlockSucceeded
    case hostUnlockFailed(MirageUnlockFailureStepCode)

    package var name: String {
        switch self {
        case .clientHelloSent:
            "mirage.client.hello.sent"
        case .clientConnectionRequested:
            "mirage.client.connection.requested"
        case .clientConnectionEstablished:
            "mirage.client.connection.established"
        case .clientConnectionFailed:
            "mirage.client.connection.failed"
        case .clientConnectionDisconnected:
            "mirage.client.connection.disconnected"
        case .clientUnlockRequested:
            "mirage.client.unlock.requested"
        case .clientHelloAccepted:
            "mirage.client.hello.accepted"
        case let .clientHelloRejected(reason):
            "mirage.client.hello.rejected.\(reason.rawValue)"
        case .clientHelloDecodeFailed:
            "mirage.client.hello.decode_failed"
        case let .clientUnlockResponse(outcome):
            "mirage.client.unlock.response.\(outcome.rawValue)"
        case let .clientHelloInvalid(reason):
            "mirage.client.hello.invalid.\(reason.rawValue)"
        case .hostConnectionIncoming:
            "mirage.host.connection.incoming"
        case let .hostHelloRejected(reason):
            "mirage.host.hello.rejected.\(reason.rawValue)"
        case let .hostConnectionApprovalResult(result):
            "mirage.host.connection.approval_result.\(result.rawValue)"
        case .hostHelloAccepted:
            "mirage.host.hello.accepted"
        case .hostClientConnected:
            "mirage.host.client.connected"
        case .hostHelloReceived:
            "mirage.host.hello.received"
        case let .hostStreamWindowStartedPerformanceMode(mode):
            "mirage.host.stream.window.started.performance_mode.\(mode.rawValue)"
        case let .hostStreamDesktopStartedPerformanceMode(mode):
            "mirage.host.stream.desktop.started.performance_mode.\(mode.rawValue)"
        case .hostClientDisconnected:
            "mirage.host.client.disconnected"
        case .hostUnlockRequested:
            "mirage.host.unlock.requested"
        case let .hostUnlockRejected(reason):
            "mirage.host.unlock.rejected.\(reason.rawValue)"
        case .hostUnlockSucceeded:
            "mirage.host.unlock.succeeded"
        case let .hostUnlockFailed(code):
            "mirage.host.unlock.failed.\(code.rawValue)"
        }
    }
}

package enum MirageInstrumentation {
    package static func record(_ step: @autoclosure () -> MirageStepEvent) {
        LoomInstrumentation.record(LoomStepEvent(rawValue: step().name))
    }
}
