//
//  MirageHostBootstrapUnlockService.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom

#if os(macOS)

/// Result returned after a bootstrap daemon unlock attempt.
public struct MirageHostBootstrapUnlockAttemptResult: Sendable, Equatable {
    /// Whether the unlock attempt succeeded.
    public let success: Bool
    /// Host session state observed after the attempt.
    public let state: LoomSessionAvailability
    /// Human-readable status or failure message.
    public let message: String?
    /// Whether another unlock attempt is allowed.
    public let canRetry: Bool
    /// Remaining retry count when the host reports one.
    public let retriesRemaining: Int?
    /// Suggested retry delay when the host reports one.
    public let retryAfterSeconds: Int?

    public init(
        success: Bool,
        state: LoomSessionAvailability,
        message: String?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    ) {
        self.success = success
        self.state = state
        self.message = message
        self.canRetry = canRetry
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Coordinates session-state monitoring and credential-based host unlock attempts.
public actor MirageHostBootstrapUnlockService {
    private let sessionMonitor: SessionStateMonitor
    private let unlockManager: UnlockManager
    private var hasStartedMonitoring = false
    private let daemonClientID = UUID(uuidString: "6E7A26F8-45EF-462B-8428-7DFB32AD20A7") ?? UUID()

    /// Creates an unlock service using the current host environment.
    public init() {
        self.init(environment: .init())
    }

    package init(environment: UnlockEnvironment) {
        let sessionMonitor = SessionStateMonitor()
        self.sessionMonitor = sessionMonitor
        unlockManager = UnlockManager(sessionMonitor: sessionMonitor, environment: environment)
    }

    /// Starts monitoring host session availability and optionally reports state changes.
    public func startMonitoring(
        onStateChange: (@Sendable (LoomSessionAvailability) -> Void)? = nil
    ) async {
        guard !hasStartedMonitoring else { return }
        hasStartedMonitoring = true
        await sessionMonitor.start { state in
            onStateChange?(state)
        }
    }

    /// Stops host session availability monitoring.
    public func stopMonitoring() async {
        guard hasStartedMonitoring else { return }
        hasStartedMonitoring = false
        await sessionMonitor.stop()
    }

    /// Current host session availability without notifying state observers.
    public var currentState: LoomSessionAvailability {
        get async {
            await sessionMonitor.refreshState(notify: false)
        }
    }

    /// Attempts to unlock the host session with the supplied credentials.
    public func attemptUnlock(
        username: String?,
        password: String
    ) async -> MirageHostBootstrapUnlockAttemptResult {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        let stateBeforeAttempt = await sessionMonitor.refreshState(notify: false)

        guard !trimmedPassword.isEmpty else {
            return MirageHostBootstrapUnlockAttemptResult(
                success: false,
                state: stateBeforeAttempt,
                message: "Unlock password is empty.",
                canRetry: true,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
        }

        guard stateBeforeAttempt.requiresCredentials else {
            return MirageHostBootstrapUnlockAttemptResult(
                success: true,
                state: .ready,
                message: "Host session is already active.",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
        }

        let (result, retriesRemaining, retryAfterSeconds) = await unlockManager.attemptUnlock(
            username: username,
            password: trimmedPassword,
            requiresUserIdentifier: stateBeforeAttempt.requiresUserIdentifier,
            clientID: daemonClientID
        )
        let refreshedState = await sessionMonitor.refreshState(notify: false)

        switch result {
        case .success:
            let success = refreshedState == .ready
            let message = success ? "Host session is active." : "Unlock completed but session is \(refreshedState.rawValue)."
            return MirageHostBootstrapUnlockAttemptResult(
                success: success,
                state: refreshedState,
                message: message,
                canRetry: !success,
                retriesRemaining: retriesRemaining,
                retryAfterSeconds: retryAfterSeconds
            )
        case let .failure(_, message):
            return MirageHostBootstrapUnlockAttemptResult(
                success: false,
                state: refreshedState,
                message: message,
                canRetry: result.canRetry,
                retriesRemaining: retriesRemaining,
                retryAfterSeconds: retryAfterSeconds
            )
        }
    }
}

#endif
