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

    nonisolated static func controlSessionHedgeDelayDescription(_ delay: Duration) -> String {
        String(describing: delay)
    }

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
            let groupedAttempts = controlSessionAttemptGroup(in: attempts, startingAt: attemptIndex)
            let failureAttemptIndex = attemptIndex + groupedAttempts.count - 1
            try throwIfConnectAttemptIsStale(attemptID)

            var openedSession: LoomAuthenticatedSession?
            var openedChannel: MirageControlChannel?
            var activeAttempt = attempt

            do {
                let session: LoomAuthenticatedSession
                if attempt.candidateKind == .overlay, groupedAttempts.count > 1 {
                    let result = try await establishOverlayControlSession(
                        attempts: groupedAttempts,
                        hello: hello,
                        attemptID: attemptID
                    )
                    session = result.session
                    activeAttempt = result.attempt
                } else {
                    session = try await establishControlSession(
                        attempt: attempt,
                        hello: hello,
                        attemptID: attemptID
                    )
                }
                openedSession = session
                try await validateProximityControlSessionPath(
                    session,
                    attempt: activeAttempt
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
                recordControlSessionAttemptSucceeded(activeAttempt)
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
                    for: activeAttempt,
                    classification: classification,
                    underlyingError: error
                )
                lastFailureReason = failureReason
                recordControlSessionAttemptFailed(activeAttempt, reason: failureReason)

                if Self.shouldRetryCurrentBootstrappedControlSessionAttempt(
                    classification: classification,
                    controlChannelOpened: openedChannel != nil,
                    hasRetriedCurrentAttempt: retriedCurrentBootstrapTransportLossAttemptIndices.contains(
                        failureAttemptIndex
                    )
                ) {
                    retriedCurrentBootstrapTransportLossAttemptIndices.insert(failureAttemptIndex)
                    MirageLogger.client(
                        "\(failureReason); retrying same transport once before transport fallback"
                    )
                    continue
                }

                if Self.shouldRetryLaterControlSessionAttempt(
                    classification: classification,
                    attempts: attempts,
                    currentAttemptIndex: failureAttemptIndex
                ) {
                    MirageLogger.client("\(failureReason); retrying over next advertised transport")
                    attemptIndex = failureAttemptIndex + 1
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

    func controlSessionAttemptGroup(
        in attempts: [ControlSessionAttempt],
        startingAt startIndex: Int
    ) -> [ControlSessionAttempt] {
        guard attempts.indices.contains(startIndex) else { return [] }
        let candidateKind = attempts[startIndex].candidateKind
        guard candidateKind == .overlay else { return [attempts[startIndex]] }

        var group: [ControlSessionAttempt] = []
        var index = startIndex
        while attempts.indices.contains(index),
              attempts[index].candidateKind == candidateKind {
            group.append(attempts[index])
            index += 1
        }
        return group
    }

    func establishOverlayControlSession(
        attempts: [ControlSessionAttempt],
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> OverlayControlSessionRaceResult {
        let raceState = OverlayControlSessionRaceState()
        var lastFailure: (classification: ControlSessionFailureClassification, reason: String)?

        return try await withThrowingTaskGroup(
            of: OverlayControlSessionCandidateOutcome.self,
            returning: OverlayControlSessionRaceResult.self
        ) { group in
            for (index, attempt) in attempts.enumerated() {
                group.addTask { [weak self] in
                    let delay = OverlayControlSessionRacePolicy.launchDelay(for: attempt.transportKind)
                    do {
                        if delay > .milliseconds(0) {
                            try await Task.sleep(for: delay)
                        }
                        guard await raceState.shouldLaunch(attempt.transportKind) else {
                            return .suppressed(
                                index: index,
                                attempt: attempt,
                                reason: "overlay hedge suppressed; another candidate reached remote hello or trust"
                            )
                        }
                        await raceState.recordLaunched(attempt.transportKind)
                        await MainActor.run {
                            self?.recordControlSessionAttemptHedgeLaunched(
                                attempt,
                                delayDescription: Self.controlSessionHedgeDelayDescription(delay)
                            )
                        }
                        guard let self else {
                            return .cancelled(index: index, attempt: attempt)
                        }
                        let session = try await self.establishControlSession(
                            attempt: attempt,
                            hello: hello,
                            attemptID: attemptID,
                            progressObserver: { progress in
                                await raceState.recordProgress(
                                    progress,
                                    transportKind: attempt.transportKind
                                )
                            }
                        )
                        return .connected(index: index, attempt: attempt, session: session)
                    } catch is CancellationError {
                        return .cancelled(index: index, attempt: attempt)
                    } catch {
                        let classification = Self.classifyControlSessionFailure(error)
                        return .failed(
                            index: index,
                            attempt: attempt,
                            classification: classification,
                            reason: Self.bootstrappedControlSessionFailureReason(
                                for: attempt,
                                classification: classification,
                                underlyingError: error
                            )
                        )
                    }
                }
            }

            while let outcome = try await group.next() {
                switch outcome {
                case let .connected(_, attempt, session):
                    if await raceState.markWinner(attempt.transportKind) {
                        recordControlSessionAttemptWinner(
                            attempt,
                            reason: "overlay race winner"
                        )
                        group.cancelAll()
                        cancelPendingConnectTask(attemptID: attemptID)
                        return OverlayControlSessionRaceResult(attempt: attempt, session: session)
                    }
                    await session.cancel()
                    recordControlSessionAttemptCancelled(
                        attempt,
                        reason: "overlay race loser"
                    )
                case let .failed(_, attempt, classification, reason):
                    lastFailure = (classification, reason)
                    recordControlSessionAttemptFailed(
                        attempt,
                        reason: reason
                    )
                case let .suppressed(_, attempt, reason):
                    recordControlSessionAttemptSuppressed(attempt, reason: reason)
                case let .cancelled(_, attempt):
                    recordControlSessionAttemptCancelled(
                        attempt,
                        reason: "overlay race cancelled"
                    )
                }
            }

            if let lastFailure {
                switch lastFailure.classification {
                case .timeout:
                    throw MirageError.timeout
                default:
                    throw MirageError.protocolError(lastFailure.reason)
                }
            }
            throw MirageError.timeout
        }
    }

    func establishControlSession(
        attempt: ControlSessionAttempt,
        hello: LoomSessionHelloRequest,
        attemptID: UUID,
        progressObserver: (@Sendable (LoomAuthenticatedSessionBootstrapProgress) async -> Void)? = nil
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
                        await progressObserver?(progress)
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
        let taskID = registerPendingConnectTask(connectTask, attemptID: attemptID)

        do {
            let session = try await awaitConnectSession(
                connectTask,
                attempt: attempt,
                initialTimeout: controlSessionInitialConnectTimeout(for: attempt),
                activePhaseIdleTimeout: controlSessionActivePhaseIdleTimeout(for: attempt),
                preRemoteHelloActivePhaseIdleTimeout: controlSessionPreRemoteHelloIdleTimeout(for: attempt),
                bootstrapProgressTracker: bootstrapProgressTracker
            )
            clearPendingConnectTaskIfNeeded(taskID: taskID, attemptID: attemptID)
            return session
        } catch {
            clearPendingConnectTaskIfNeeded(taskID: taskID, attemptID: attemptID)
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
        initialTimeout: Duration,
        activePhaseIdleTimeout: Duration,
        preRemoteHelloActivePhaseIdleTimeout: Duration?,
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
                timeoutMonitorTask = Task { [initialTimeout, activePhaseIdleTimeout, preRemoteHelloActivePhaseIdleTimeout, timeoutError] in
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
                            initialTimeout: initialTimeout,
                            activePhaseIdleTimeout: activePhaseIdleTimeout,
                            preRemoteHelloActivePhaseIdleTimeout: preRemoteHelloActivePhaseIdleTimeout,
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
            throw error
        }
    }

    func controlSessionInitialConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.isPeerToPeerPreferred {
            return .seconds(2)
        }
        if attempt.candidateKind == .overlay,
           attempt.transportKind != .udp {
            return OverlayControlSessionRacePolicy.preTransportReadyTimeout
        }
        if attempt.transportKind == .udp {
            return .seconds(5)
        }
        return controlSessionConnectTimeout
    }

    func controlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        controlSessionInitialConnectTimeout(for: attempt)
    }

    func controlSessionActivePhaseIdleTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.isPeerToPeerPreferred {
            return .seconds(2)
        }
        if attempt.transportKind == .udp {
            return .seconds(5)
        }
        return controlSessionConnectTimeout
    }

    func controlSessionPreRemoteHelloIdleTimeout(for attempt: ControlSessionAttempt) -> Duration? {
        guard attempt.candidateKind == .overlay,
              attempt.transportKind != .udp else {
            return nil
        }
        return OverlayControlSessionRacePolicy.preRemoteHelloIdleTimeout
    }

    func absoluteControlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.isPeerToPeerPreferred {
            return .seconds(6)
        }
        if attempt.candidateKind == .overlay {
            return OverlayControlSessionRacePolicy.groupBudget
        }
        if attempt.transportKind == .udp {
            return .seconds(20)
        }
        return controlSessionInitialConnectTimeout(for: attempt)
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
