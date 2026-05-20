//
//  MirageClientService+ConnectionBootstrap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import Network
import MirageKit

@MainActor
extension MirageClientService {
    /// Interval used while polling bootstrap progress for stalled control-session attempts.
    private static let controlSessionConnectWatchdogPollingInterval: Duration = .milliseconds(250)

    func connectBootstrappedControlSession(
        to host: LoomPeer,
        hello: LoomSessionHelloRequest,
        attemptID: UUID,
        requestTakeoverIfBusy: Bool = false
    ) async throws -> BootstrappedControlSession {
        try throwIfConnectAttemptIsStale(attemptID)

        let attempts = controlSessionAttempts(for: host)
        recordControlSessionAttemptPlan(attempts, host: host)
        var lastFailureReason: String?
        var retriedCurrentBootstrapTransportLossAttemptIndices: Set<Int> = []
        var attemptIndex = 0

        while attemptIndex < attempts.count {
            let attempt = attempts[attemptIndex]
            try throwIfConnectAttemptIsStale(attemptID)

            var openedSession: LoomAuthenticatedSession?
            var openedChannel: MirageControlChannel?

            do {
                let session = try await establishControlSession(
                    attempt: attempt,
                    hello: hello,
                    attemptID: attemptID
                )
                openedSession = session
                try await validateProximityControlSessionPath(
                    session,
                    attempt: attempt
                )
                let controlChannel = try await MirageControlChannel.open(on: session)
                openedChannel = controlChannel
                try Task.checkCancellation()
                try throwIfConnectAttemptIsStale(attemptID)
                try await performBootstrap(
                    over: controlChannel,
                    provisionalHost: host,
                    requestTakeoverIfBusy: requestTakeoverIfBusy
                )
                try Task.checkCancellation()
                try throwIfConnectAttemptIsStale(attemptID)
                recordControlSessionAttemptSucceeded(attempt)
                return BootstrappedControlSession(session: session, controlChannel: controlChannel)
            } catch {
                if let openedChannel {
                    await openedChannel.cancel()
                } else if let openedSession {
                    await openedSession.cancel()
                }

                if let rejectionError = error as? MirageError,
                   case let .connectionRejected(rejection) = rejectionError,
                   rejection.isTerminal {
                    throw rejectionError
                }

                guard let classification = Self.classifyBootstrappedControlSessionFailure(
                    error,
                    isCurrentAttempt: isCurrentConnectAttempt(attemptID),
                    taskIsCancelled: Task.isCancelled
                ) else {
                    throw error
                }

                let failureReason = Self.bootstrappedControlSessionFailureReason(
                    for: attempt,
                    classification: classification,
                    underlyingError: error
                )
                lastFailureReason = failureReason
                recordControlSessionAttemptFailed(attempt, reason: failureReason)

                if Self.shouldRetryCurrentBootstrappedControlSessionAttempt(
                    classification: classification,
                    controlChannelOpened: openedChannel != nil,
                    hasRetriedCurrentAttempt: retriedCurrentBootstrapTransportLossAttemptIndices.contains(
                        attemptIndex
                    )
                ) {
                    retriedCurrentBootstrapTransportLossAttemptIndices.insert(attemptIndex)
                    MirageLogger.client(
                        "\(failureReason); retrying same transport once before transport fallback"
                    )
                    continue
                }

                if Self.shouldRetryLaterControlSessionAttempt(
                    classification: classification,
                    attempts: attempts,
                    currentAttemptIndex: attemptIndex
                ) {
                    MirageLogger.client("\(failureReason); retrying over next advertised transport")
                    attemptIndex += 1
                    continue
                }

                if let networkMismatchReason = Self.localNetworkMismatchReason(
                    for: host,
                    classification: classification,
                    localNetwork: ControlSessionNetworkDiagnostics(snapshot: localNetworkMonitor.snapshot)
                ) {
                    MirageLogger.client(
                        "Bootstrap failure diagnosed as local-network mismatch: \(failureReason)"
                    )
                    throw MirageError.connectionRejected(
                        MirageConnectionRejection(
                            reason: .localNetworkBlocked,
                            hostName: host.name,
                            recoveryHint: networkMismatchReason
                        )
                    )
                }

                throw MirageError.protocolError(failureReason)
            }
        }

        throw MirageError.protocolError(
            lastFailureReason ?? "Failed to bootstrap control session to \(host.name)"
        )
    }

    func establishControlSession(
        attempt: ControlSessionAttempt,
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        try throwIfConnectAttemptIsStale(attemptID)
        MirageLogger.client(
            "Starting \(attempt.transportKind) control session to \(attempt.hostName) " +
                "candidate=\(attempt.candidateKind.rawValue) endpoint=\(attempt.endpoint) " +
                "interface=\(attempt.interfaceDescription)"
        )
        recordControlSessionAttemptStarted(attempt)
        let node = loomNode
        let bootstrapProgressTracker = ConnectSessionBootstrapProgressTracker()
        let connectTask = Task<LoomAuthenticatedSession, Error> { [weak self] in
            let session = try await node.connect(
                to: attempt.endpoint,
                using: attempt.transportKind,
                hello: hello,
                requiredInterface: attempt.requiredInterface,
                requiredInterfaceType: attempt.requiredInterfaceType,
                onTrustPending: { @MainActor [weak self] in
                    self?.authorizationState = .verifyingTrust
                },
                onBootstrapProgress: { [weak self] progress in
                    Task {
                        await bootstrapProgressTracker.record(progress)
                        await MainActor.run {
                            self?.handleConnectBootstrapProgress(
                                progress,
                                attempt: attempt,
                                attemptID: attemptID
                            )
                        }
                    }
                }
            )
            let shouldCancelSession = await MainActor.run {
                guard let self else { return true }
                return !self.isCurrentConnectAttempt(attemptID)
            }
            if shouldCancelSession {
                await session.cancel()
                throw CancellationError()
            }
            return session
        }
        pendingConnectTask = connectTask
        pendingConnectTaskAttemptID = attemptID

        do {
            let session = try await awaitConnectSession(
                connectTask,
                attempt: attempt,
                attemptID: attemptID,
                timeout: controlSessionConnectTimeout(for: attempt),
                bootstrapProgressTracker: bootstrapProgressTracker
            )
            clearPendingConnectTaskIfNeeded(for: attemptID)
            return session
        } catch {
            clearPendingConnectTaskIfNeeded(for: attemptID)
            throw error
        }
    }

    func validateProximityControlSessionPath(
        _ session: LoomAuthenticatedSession,
        attempt: ControlSessionAttempt
    ) async throws {
        guard attempt.requiresProximityPathValidation else {
            recordControlSessionProximityValidation(attempt, outcome: "notRequired")
            return
        }

        guard let pathSnapshot = await session.pathSnapshot else {
            let reason = "Proximity path validation failed for \(attempt.hostName) " +
                "expected=\(attempt.proximityDescription) actual=missing-path-snapshot"
            MirageLogger.client(reason)
            recordControlSessionProximityValidation(attempt, outcome: "missingPathSnapshot")
            throw MirageError.protocolError(reason)
        }

        let classifiedSnapshot = MirageNetworkPathClassifier.classify(pathSnapshot)
        guard attempt.acceptsProximityPath(classifiedSnapshot) else {
            let reason = "Proximity path validation failed for \(attempt.hostName) " +
                "expected=\(attempt.proximityDescription) actual=\(classifiedSnapshot.signature)"
            MirageLogger.client(reason)
            recordControlSessionProximityValidation(
                attempt,
                outcome: "rejected actual=\(classifiedSnapshot.signature)"
            )
            throw MirageError.protocolError(reason)
        }

        MirageLogger.client(
            "Accepted proximity control session for \(attempt.hostName): " +
                "expected=\(attempt.proximityDescription) actual=\(classifiedSnapshot.signature)"
        )
        recordControlSessionProximityValidation(
            attempt,
            outcome: "accepted actual=\(classifiedSnapshot.signature)"
        )
    }

    /// Races `connectTask` against `controlSessionConnectTimeout` using a
    /// continuation so the timeout can fire immediately without waiting for
    /// `NWConnection` to acknowledge cancellation (which may never happen when
    /// the macOS NECP policy engine is in a corrupted state).
    func awaitConnectSession(
        _ connectTask: Task<LoomAuthenticatedSession, Error>,
        attempt: ControlSessionAttempt,
        attemptID: UUID,
        timeout: Duration,
        bootstrapProgressTracker: ConnectSessionBootstrapProgressTracker
    ) async throws -> LoomAuthenticatedSession {
        let timeoutError = MirageError.timeout
        var connectResultTask: Task<Void, Never>?
        var timeoutMonitorTask: Task<Void, Never>?

        defer {
            connectResultTask?.cancel()
            timeoutMonitorTask?.cancel()
        }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = ConnectSessionContinuationBox(continuation)

                connectResultTask = Task {
                    do {
                        let session = try await connectTask.value
                        await box.resume(returning: session)
                    } catch {
                        await box.resume(throwing: error)
                    }
                }

                // Cancel the watchdog loop as soon as this race resolves so
                // repeated fallback attempts do not accumulate idle timers.
                timeoutMonitorTask = Task { [timeout, timeoutError] in
                    let absoluteTimeout = absoluteControlSessionConnectTimeout(for: attempt)
                    let trustPendingTimeout = max(
                        absoluteTimeout,
                        trustPendingControlSessionConnectTimeout
                    )

                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: Self.controlSessionConnectWatchdogPollingInterval)
                        } catch {
                            break
                        }
                        let timedOut = await bootstrapProgressTracker.shouldTimeOut(
                            now: ContinuousClock.now,
                            initialTimeout: timeout,
                            activePhaseIdleTimeout: timeout,
                            trustPendingIdleTimeout: trustPendingTimeout,
                            absoluteTimeout: absoluteTimeout,
                            trustPendingAbsoluteTimeout: trustPendingTimeout
                        )
                        guard timedOut else { continue }
                        connectTask.cancel()
                        await box.resume(throwing: timeoutError)
                        return
                    }
                }
            }
        } catch {
            if isCurrentConnectAttempt(attemptID) {
                cancelPendingConnectTask(attemptID: attemptID)
            }
            throw error
        }
    }

    func controlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.isPeerToPeerPreferred {
            return .seconds(2)
        }
        if attempt.transportKind == .udp {
            return .seconds(5)
        }
        return controlSessionConnectTimeout
    }

    func absoluteControlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.isPeerToPeerPreferred {
            return .seconds(6)
        }
        if attempt.transportKind == .udp {
            return .seconds(20)
        }
        return controlSessionConnectTimeout(for: attempt)
    }

    func handleConnectBootstrapProgress(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        attempt: ControlSessionAttempt,
        attemptID: UUID
    ) {
        guard isCurrentConnectAttempt(attemptID) else { return }

        if progress.phase == .remoteHelloReceived || progress.phase == .trustPendingApproval {
            if case .connecting = connectionState {
                connectionState = .handshaking(host: attempt.hostName)
            }
        }

        if let failureReason = progress.failureReason {
            authorizationState = .idle
            MirageLogger.client(
                "Pre-bootstrap \(attempt.transportKind.rawValue) control session failed at " +
                    "\(progress.phase.rawValue) for \(attempt.hostName): \(failureReason)"
            )
            return
        }

        if progress.phase == .ready {
            authorizationState = .approved
        }

        MirageLogger.client(
            "Pre-bootstrap \(attempt.transportKind.rawValue) progress for \(attempt.hostName): \(progress.phase.rawValue)"
        )
    }
}
