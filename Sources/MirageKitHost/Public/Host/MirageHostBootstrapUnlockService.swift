//
//  MirageHostBootstrapUnlockService.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Reusable unlock service for bootstrap daemon and host-side integrations.
//

import Foundation
import MirageKit

#if os(macOS)

public struct MirageHostBootstrapUnlockAttemptResult: Sendable, Equatable {
    public let success: Bool
    public let state: HostSessionState
    public let message: String?
    public let canRetry: Bool
    public let retriesRemaining: Int?
    public let retryAfterSeconds: Int?

    public init(
        success: Bool,
        state: HostSessionState,
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

/// Host-side unlock wrapper around `SessionStateMonitor` + `UnlockManager`.
public actor MirageHostBootstrapUnlockService {
    private let sessionMonitor: SessionStateMonitor
    private let unlockManager: UnlockManager
    private var hasStartedMonitoring = false
    private let daemonClientID = UUID(uuidString: "6E7A26F8-45EF-462B-8428-7DFB32AD20A7") ?? UUID()

    public init() {
        let sessionMonitor = SessionStateMonitor()
        self.sessionMonitor = sessionMonitor
        unlockManager = UnlockManager(sessionMonitor: sessionMonitor)
    }

    public func startMonitoring(
        onStateChange: (@Sendable (HostSessionState) -> Void)? = nil
    ) async {
        guard !hasStartedMonitoring else { return }
        hasStartedMonitoring = true
        await sessionMonitor.start { state in
            onStateChange?(state)
        }
    }

    public func stopMonitoring() async {
        guard hasStartedMonitoring else { return }
        hasStartedMonitoring = false
        await sessionMonitor.stop()
    }

    public func currentState() async -> HostSessionState {
        await sessionMonitor.refreshState(notify: false)
    }

    public func attemptUnlock(
        username: String?,
        password: String
    )
    async -> MirageHostBootstrapUnlockAttemptResult {
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

        guard stateBeforeAttempt.requiresUnlock else {
            return MirageHostBootstrapUnlockAttemptResult(
                success: true,
                state: .active,
                message: "Host session is already active.",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
        }

        let (result, retriesRemaining, retryAfterSeconds) = await unlockManager.attemptUnlock(
            username: username,
            password: trimmedPassword,
            requiresUsername: stateBeforeAttempt.requiresUsername,
            clientID: daemonClientID
        )
        let refreshedState = await sessionMonitor.refreshState(notify: false)

        switch result {
        case .success:
            let success = refreshedState == .active
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
