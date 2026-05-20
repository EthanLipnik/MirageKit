//
//  MirageClientService+ConnectionTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import MirageKit

/// Waits for an outbound disconnect notice to be sent before teardown continues.
final class MirageDisconnectNoticeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isComplete = false

    /// Suspends until `complete()` is called, or returns immediately if already complete.
    func wait() async {
        await withCheckedContinuation { continuation in
            let continuationToResume = lockedContinuationToResumeForWait(continuation)
            continuationToResume?.resume()
        }
    }

    /// Marks the notice as delivered and resumes any waiter exactly once.
    func complete() {
        let continuationToResume = lockedContinuationToResumeForComplete()
        continuationToResume?.resume()
    }

    private func lockedContinuationToResumeForWait(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if isComplete {
            return continuation
        }
        self.continuation = continuation
        return nil
    }

    private func lockedContinuationToResumeForComplete() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if isComplete {
            return nil
        }
        isComplete = true
        let continuationToResume = continuation
        continuation = nil
        return continuationToResume
    }
}

@MainActor
extension MirageClientService {
    /// Result of establishing a Loom session and opening its Mirage control channel.
    struct BootstrappedControlSession {
        /// Authenticated Loom session backing the connection.
        let session: LoomAuthenticatedSession

        /// Control channel used for Mirage protocol messages.
        let controlChannel: MirageControlChannel
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once when racing
/// a connect task against a timeout. The first caller to `resume` wins;
/// subsequent calls are silently ignored.
actor ConnectSessionContinuationBox {
    private var continuation: CheckedContinuation<LoomAuthenticatedSession, Error>?

    init(_ continuation: CheckedContinuation<LoomAuthenticatedSession, Error>) {
        self.continuation = continuation
    }

    func resume(returning session: LoomAuthenticatedSession) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: session)
    }

    func resume(throwing error: Error) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(throwing: error)
    }
}

actor ConnectSessionBootstrapProgressTracker {
    private let startedAt = ContinuousClock.now
    private var latestProgress = LoomAuthenticatedSessionBootstrapProgress(phase: .idle)
    private var lastProgressAt = ContinuousClock.now

    /// Records a distinct bootstrap progress update and its observation time.
    func record(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        guard progress != latestProgress else { return }
        latestProgress = progress
        lastProgressAt = now
    }

    /// Returns whether bootstrap has exceeded the idle or absolute timeout budget.
    func shouldTimeOut(
        now: ContinuousClock.Instant,
        initialTimeout: Duration,
        activePhaseIdleTimeout: Duration,
        preRemoteHelloActivePhaseIdleTimeout: Duration? = nil,
        trustPendingIdleTimeout: Duration,
        absoluteTimeout: Duration,
        trustPendingAbsoluteTimeout: Duration
    ) -> Bool {
        if latestProgress.phase == .ready || latestProgress.isFailure {
            return false
        }

        let idleTimeout: Duration
        let resolvedAbsoluteTimeout: Duration

        switch latestProgress.phase {
        case .idle:
            idleTimeout = initialTimeout
            resolvedAbsoluteTimeout = absoluteTimeout
        case .trustPendingApproval:
            idleTimeout = trustPendingIdleTimeout
            resolvedAbsoluteTimeout = trustPendingAbsoluteTimeout
        case .transportStarting, .transportReady, .localHelloSent:
            idleTimeout = preRemoteHelloActivePhaseIdleTimeout ?? activePhaseIdleTimeout
            resolvedAbsoluteTimeout = absoluteTimeout
        case .remoteHelloReceived:
            idleTimeout = activePhaseIdleTimeout
            resolvedAbsoluteTimeout = trustPendingAbsoluteTimeout
        default:
            idleTimeout = activePhaseIdleTimeout
            resolvedAbsoluteTimeout = absoluteTimeout
        }

        if now - startedAt >= resolvedAbsoluteTimeout {
            return true
        }

        if latestProgress.phase == .idle {
            return now - startedAt >= idleTimeout
        }
        return now - lastProgressAt >= idleTimeout
    }

    func phase() -> LoomAuthenticatedSessionBootstrapPhase {
        latestProgress.phase
    }
}
