//
//  MirageClientRecoveryRetryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

@testable import MirageKitClient
import Testing

@Suite("Client Recovery Retry")
struct MirageClientRecoveryRetryTests {
    @Test("Recovery retry continues when packets resume without presentation progress")
    func recoveryRetryContinuesWithoutPresentationProgress() {
        let disposition = MirageClientService.recoveryKeyframeRetryDisposition(
            baselineSubmittedSequence: 12,
            latestSubmittedSequence: 12,
            previousPacketTime: 100,
            latestPacketTime: 101,
            awaitingKeyframe: false
        )

        #expect(disposition == .retry(packetFlowResumed: true, awaitingKeyframe: false))
    }

    @Test("Recovery retry stops only after presentation submission advances")
    func recoveryRetryStopsAfterPresentationSubmissionAdvances() {
        let disposition = MirageClientService.recoveryKeyframeRetryDisposition(
            baselineSubmittedSequence: 12,
            latestSubmittedSequence: 13,
            previousPacketTime: 100,
            latestPacketTime: 100,
            awaitingKeyframe: false
        )

        #expect(disposition == .recovered)
    }

    @Test("Recovery retry waits when packet flow has not resumed")
    func recoveryRetryWaitsWhenPacketFlowHasNotResumed() {
        let disposition = MirageClientService.recoveryKeyframeRetryDisposition(
            baselineSubmittedSequence: 12,
            latestSubmittedSequence: 12,
            previousPacketTime: 100,
            latestPacketTime: 100,
            awaitingKeyframe: true
        )

        #expect(disposition == .waitForTransport(awaitingKeyframe: true))
    }
}
