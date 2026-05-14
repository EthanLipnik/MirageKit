//
//  RecoveryCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Recovery Coordinator")
struct RecoveryCoordinatorTests {
    @Test("Recovery coordinator waits for host ack deadline")
    func waitsForHostAckDeadline() {
        var coordinator = RecoveryCoordinator()
        let first = coordinator.requestAction(
            now: 10,
            reason: "frame-loss",
            targetFPS: 120
        )

        guard case .dispatch = first else {
            Issue.record("Expected first recovery action to dispatch")
            return
        }

        coordinator.recordHostAck(
            KeyframeRecoveryAckMessage(
                streamID: 1,
                deadlineMilliseconds: 750
            ),
            now: 10.05
        )

        let second = coordinator.requestAction(
            now: 10.40,
            reason: "frame-loss",
            targetFPS: 120
        )

        guard case let .wait(deadline) = second else {
            Issue.record("Expected recovery action to wait")
            return
        }
        #expect(deadline >= 10.80)
    }

    @Test("Rejected host ack waits without consuming a recovery attempt")
    func rejectedHostAckWaitsWithoutConsumingRecoveryAttempt() {
        var coordinator = RecoveryCoordinator()
        let first = coordinator.requestAction(now: 10, reason: "frame-loss", targetFPS: 120)

        guard case let .dispatch(_, firstAttempt) = first else {
            Issue.record("Expected first recovery action to dispatch")
            return
        }
        #expect(firstAttempt == 1)

        coordinator.recordHostAck(
            KeyframeRecoveryAckMessage(
                streamID: 1,
                deadlineMilliseconds: 750,
                accepted: false,
                state: .inFlight
            ),
            now: 10.05
        )

        let retry = coordinator.requestAction(now: 10.81, reason: "frame-loss", targetFPS: 120)
        guard case let .dispatch(_, retryAttempt) = retry else {
            Issue.record("Expected retry after host in-flight deadline")
            return
        }
        #expect(retryAttempt == 1)
    }

    @Test("No-stream host ack clears recovery episode")
    func noStreamHostAckClearsRecoveryEpisode() {
        var coordinator = RecoveryCoordinator()
        _ = coordinator.requestAction(now: 10, reason: "frame-loss", targetFPS: 120)
        coordinator.recordHostAck(
            KeyframeRecoveryAckMessage(
                streamID: 1,
                deadlineMilliseconds: 0,
                accepted: false,
                state: .noStream
            ),
            now: 10.05
        )

        let decision = coordinator.requestAction(now: 10.1, reason: "frame-loss", targetFPS: 120)
        guard case let .dispatch(episodeID, attempt) = decision else {
            Issue.record("Expected new episode after no-stream ack")
            return
        }

        #expect(episodeID == 2)
        #expect(attempt == 1)
    }

    @Test("Recovery coordinator clears episode on progress")
    func clearsEpisodeOnProgress() {
        var coordinator = RecoveryCoordinator()
        _ = coordinator.requestAction(now: 1, reason: "freeze", targetFPS: 60)
        coordinator.recordProgress()

        let decision = coordinator.requestAction(now: 1.1, reason: "freeze", targetFPS: 60)
        guard case let .dispatch(episodeID, attempt) = decision else {
            Issue.record("Expected dispatch after progress clears coordinator")
            return
        }

        #expect(episodeID == 2)
        #expect(attempt == 1)
    }

    @Test("Recovery coordinator caps low-FPS retry delay")
    func capsLowFPSRetryDelay() {
        var coordinator = RecoveryCoordinator()
        let first = coordinator.requestAction(
            now: 20,
            reason: "decode-threshold",
            targetFPS: 1
        )

        guard case .dispatch = first else {
            Issue.record("Expected first recovery action to dispatch")
            return
        }

        let waiting = coordinator.requestAction(
            now: 20.9,
            reason: "decode-threshold",
            targetFPS: 1
        )
        guard case .wait = waiting else {
            Issue.record("Expected retry to wait inside capped delay")
            return
        }

        let retry = coordinator.requestAction(
            now: 21.1,
            reason: "decode-threshold",
            targetFPS: 1
        )
        guard case let .dispatch(episodeID, attempt) = retry else {
            Issue.record("Expected capped retry to dispatch")
            return
        }

        #expect(episodeID == 1)
        #expect(attempt == 2)
    }
}
#endif
