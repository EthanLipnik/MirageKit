//
//  MirageInstrumentation.swift
//  MirageKit
//
//  Created by Codex on 2/24/26.
//
//  App-agnostic instrumentation hooks for MirageKit host/client services.
//

import Foundation

public enum MirageHelloRejectionStepReason: String, Sendable, Equatable {
    case protocolVersionMismatch = "protocol_version_mismatch"
    case protocolFeaturesMismatch = "protocol_features_mismatch"
    case hostBusy = "host_busy"
    case rejected
    case unauthorized
    case unknown

    public init(name: String) {
        self = Self(rawValue: name) ?? .unknown
    }
}

public enum MirageClientHelloValidationStepReason: String, Sendable, Equatable {
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

public enum MirageUnlockResponseStepOutcome: String, Sendable, Equatable {
    case success
    case failure
}

public enum MirageHostConnectionApprovalStepResult: String, Sendable, Equatable {
    case accepted
    case rejected
    case connectionClosed = "connection_closed"
    case timedOut = "timed_out"
}

public enum MiragePerformanceModeStep: String, Sendable, Equatable {
    case standard
    case game

    public init(rawMode: String) {
        self = Self(rawValue: rawMode) ?? .standard
    }
}

public enum MirageHostUnlockRejectionStepReason: String, Sendable, Equatable {
    case remoteUnlockDisabled = "remote_unlock_disabled"
    case notAuthorized = "not_authorized"
    case invalidRequestFormat = "invalid_request_format"
    case sessionTokenExpired = "session_token_expired"
}

public enum MirageHostUnlockFailureStepCode: String, Sendable, Equatable {
    case invalidCredentials
    case rateLimited
    case sessionExpired
    case notLocked
    case notSupported
    case notAuthorized
    case timeout
    case internalError
    case unknown

    public init(name: String) {
        self = Self(rawValue: name) ?? .unknown
    }
}

public enum MirageStepEvent: Sendable, Equatable {
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
    case hostConnectionApprovalResult(MirageHostConnectionApprovalStepResult)
    case hostHelloAccepted
    case hostClientConnected
    case hostHelloReceived
    case hostStreamWindowStartedPerformanceMode(MiragePerformanceModeStep)
    case hostStreamDesktopStartedPerformanceMode(MiragePerformanceModeStep)
    case hostClientDisconnected
    case hostUnlockRequested
    case hostUnlockRejected(MirageHostUnlockRejectionStepReason)
    case hostUnlockSucceeded
    case hostUnlockFailed(MirageHostUnlockFailureStepCode)

    public var name: String {
        switch self {
        case .clientHelloSent:
            return "mirage.client.hello.sent"
        case .clientConnectionRequested:
            return "mirage.client.connection.requested"
        case .clientConnectionEstablished:
            return "mirage.client.connection.established"
        case .clientConnectionFailed:
            return "mirage.client.connection.failed"
        case .clientConnectionDisconnected:
            return "mirage.client.connection.disconnected"
        case .clientUnlockRequested:
            return "mirage.client.unlock.requested"
        case .clientHelloAccepted:
            return "mirage.client.hello.accepted"
        case let .clientHelloRejected(reason):
            return "mirage.client.hello.rejected.\(reason.rawValue)"
        case .clientHelloDecodeFailed:
            return "mirage.client.hello.decode_failed"
        case let .clientUnlockResponse(outcome):
            return "mirage.client.unlock.response.\(outcome.rawValue)"
        case let .clientHelloInvalid(reason):
            return "mirage.client.hello.invalid.\(reason.rawValue)"

        case .hostConnectionIncoming:
            return "mirage.host.connection.incoming"
        case let .hostHelloRejected(reason):
            return "mirage.host.hello.rejected.\(reason.rawValue)"
        case let .hostConnectionApprovalResult(result):
            return "mirage.host.connection.approval_result.\(result.rawValue)"
        case .hostHelloAccepted:
            return "mirage.host.hello.accepted"
        case .hostClientConnected:
            return "mirage.host.client.connected"
        case .hostHelloReceived:
            return "mirage.host.hello.received"
        case let .hostStreamWindowStartedPerformanceMode(mode):
            return "mirage.host.stream.window.started.performance_mode.\(mode.rawValue)"
        case let .hostStreamDesktopStartedPerformanceMode(mode):
            return "mirage.host.stream.desktop.started.performance_mode.\(mode.rawValue)"
        case .hostClientDisconnected:
            return "mirage.host.client.disconnected"
        case .hostUnlockRequested:
            return "mirage.host.unlock.requested"
        case let .hostUnlockRejected(reason):
            return "mirage.host.unlock.rejected.\(reason.rawValue)"
        case .hostUnlockSucceeded:
            return "mirage.host.unlock.succeeded"
        case let .hostUnlockFailed(code):
            return "mirage.host.unlock.failed.\(code.rawValue)"
        }
    }
}

public struct MirageInstrumentationEvent: Sendable, Equatable {
    public let step: MirageStepEvent
    public let timestamp: Date

    public var name: String {
        step.name
    }

    public init(
        step: MirageStepEvent,
        timestamp: Date = Date()
    ) {
        self.step = step
        self.timestamp = timestamp
    }
}

public struct MirageInstrumentationSinkToken: Hashable, Sendable {
    let rawValue = UUID()
}

public protocol MirageInstrumentationSink: Sendable {
    func record(event: MirageInstrumentationEvent) async
}

public extension MirageInstrumentationSink {
    func record(event _: MirageInstrumentationEvent) async {}
}

private final class MirageInstrumentationSinkRegistryState: @unchecked Sendable {
    private let lock = NSLock()
    private var sinkCount = 0

    var hasRegisteredSinks: Bool {
        withLock { sinkCount > 0 }
    }

    func setSinkCount(_ count: Int) {
        withLock {
            sinkCount = max(0, count)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let instrumentationSinkRegistryState = MirageInstrumentationSinkRegistryState()

private actor MirageInstrumentationStore {
    static let shared = MirageInstrumentationStore()

    private var sinks: [MirageInstrumentationSinkToken: any MirageInstrumentationSink] = [:]

    func addSink(_ sink: any MirageInstrumentationSink) -> MirageInstrumentationSinkToken {
        let token = MirageInstrumentationSinkToken()
        sinks[token] = sink
        instrumentationSinkRegistryState.setSinkCount(sinks.count)
        return token
    }

    func removeSink(_ token: MirageInstrumentationSinkToken) {
        sinks.removeValue(forKey: token)
        instrumentationSinkRegistryState.setSinkCount(sinks.count)
    }

    func removeAllSinks() {
        sinks.removeAll()
        instrumentationSinkRegistryState.setSinkCount(0)
    }

    func record(_ event: MirageInstrumentationEvent) async {
        for sink in sinks.values {
            await sink.record(event: event)
        }
    }
}

public enum MirageInstrumentation {
    public static var hasRegisteredSinks: Bool {
        instrumentationSinkRegistryState.hasRegisteredSinks
    }

    @discardableResult
    public static func addSink(_ sink: any MirageInstrumentationSink) async -> MirageInstrumentationSinkToken {
        await MirageInstrumentationStore.shared.addSink(sink)
    }

    public static func removeSink(_ token: MirageInstrumentationSinkToken) async {
        await MirageInstrumentationStore.shared.removeSink(token)
    }

    public static func removeAllSinks() async {
        await MirageInstrumentationStore.shared.removeAllSinks()
    }

    public static func record(_ step: @autoclosure () -> MirageStepEvent) {
        guard instrumentationSinkRegistryState.hasRegisteredSinks else { return }
        let resolvedEvent = MirageInstrumentationEvent(step: step())
        Task(priority: .utility) {
            await MirageInstrumentationStore.shared.record(resolvedEvent)
        }
    }
}
