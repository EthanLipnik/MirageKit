//
//  QualityTestWaiterTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Quality Test Waiters", .serialized)
struct QualityTestWaiterTests {
    @MainActor
    @Test("Concurrent ping callers share a single in-flight wire ping")
    func concurrentPingCallersShareInFlightRequest() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Host")

        let sendCounter = PingSendCounter()
        let sendPing: @MainActor @Sendable () async throws -> Void = {
            sendCounter.value += 1
        }

        let firstWaiter = Task {
            try await service.sendPingAndAwaitPong(sendPing: sendPing)
        }
        try await Task.sleep(for: .milliseconds(10))

        let secondWaiter = Task {
            try await service.sendPingAndAwaitPong(sendPing: sendPing)
        }
        try await Task.sleep(for: .milliseconds(10))

        #expect(sendCounter.value == 1)
        service.completePingRequest(
            expectedRequestID: service.pingRequestID,
            result: .success(())
        )

        try await firstWaiter.value
        try await secondWaiter.value
        #expect(sendCounter.value == 1)
    }

    @MainActor
    @Test("RTT sampling shares a heartbeat ping already in flight")
    func measureRTTSharesExistingInFlightPing() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Host")

        let sendCounter = PingSendCounter()
        let sendPing: @MainActor @Sendable () async throws -> Void = {
            sendCounter.value += 1
        }

        let heartbeatPing = Task {
            try await service.sendPingAndAwaitPong(sendPing: sendPing)
        }
        try await waitForPingRequestToStart(on: service, sendCounter: sendCounter)

        let rttTask = Task {
            try await service.measureRTT(sendPing: sendPing)
        }

        try await waitForPingRequest(
            on: service,
            sendCounter: sendCounter,
            expectedSendCount: 1,
            minimumWaiterCount: 2
        )
        service.completePingRequest(
            expectedRequestID: service.pingRequestID,
            result: .success(())
        )
        try await heartbeatPing.value

        for expectedSendCount in 2 ... 3 {
            try await waitForPingRequest(
                on: service,
                sendCounter: sendCounter,
                expectedSendCount: expectedSendCount,
                minimumWaiterCount: 1
            )
            service.completePingRequest(
                expectedRequestID: service.pingRequestID,
                result: .success(())
            )
        }

        let rttMs = try await rttTask.value

        #expect(sendCounter.value == 3)
        #expect(rttMs >= 0)
    }

    @MainActor
    @Test("Stale quality-test timeout does not cancel a newer waiter")
    func staleQualityTestTimeoutDoesNotCancelNewerWaiter() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        let firstTestID = UUID()
        let secondTestID = UUID()

        let firstWaiter = Task {
            await service.awaitQualityTestBenchmark(
                testID: firstTestID,
                timeout: .milliseconds(50)
            )
        }

        try await Task.sleep(for: .milliseconds(10))

        let secondWaiter = Task {
            await service.awaitQualityTestBenchmark(
                testID: secondTestID,
                timeout: .seconds(1)
            )
        }

        let firstResult = await firstWaiter.value
        #expect(firstResult == nil)

        try await Task.sleep(for: .milliseconds(120))

        let expectedResult = QualityTestBenchmarkMessage(
            testID: secondTestID,
            benchmarkWidth: 3_840,
            benchmarkHeight: 2_160,
            benchmarkFrameRate: 60,
            encodeMs: 4.2,
            benchmarkVersion: 1
        )
        let message = try ControlMessage(
            type: .qualityTestResult,
            content: expectedResult
        )
        service.handleQualityTestBenchmark(message)

        let secondResult = await secondWaiter.value
        #expect(secondResult?.testID == secondTestID)
        #expect(secondResult?.benchmarkWidth == expectedResult.benchmarkWidth)
    }

    @MainActor
    @Test("Buffered stage completion is delivered to a later stage waiter")
    func bufferedStageCompletionIsDeliveredToLaterWaiter() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        let testID = UUID()
        service.qualityTestPendingTestID = testID

        let expectedResult = QualityTestStageCompleteMessage(
            testID: testID,
            stageID: 4,
            probeKind: .streamingReplay,
            targetBitrateBps: 181_000_000,
            configuredDurationMs: 1_500,
            startedAtTimestampNs: 100,
            measurementEndedAtTimestampNs: 1_500_000_100,
            completedAtTimestampNs: 1_500_000_200,
            sentPacketCount: 256,
            sentPayloadBytes: 1_024 * 1_024,
            deliveryWindowMissed: false
        )
        let message = try ControlMessage(
            type: .qualityTestStageComplete,
            content: expectedResult
        )

        service.handleQualityTestStageCompletion(message)
        #expect(service.qualityTestStageCompletionBuffer.count == 1)

        let result = await service.awaitQualityTestStageCompletion(
            testID: testID,
            stageID: expectedResult.stageID,
            timeout: .seconds(1)
        )

        #expect(result?.testID == testID)
        #expect(result?.stageID == expectedResult.stageID)
        #expect(result?.probeKind == .streamingReplay)
        #expect(result?.sentPacketCount == expectedResult.sentPacketCount)
        #expect(service.qualityTestStageCompletionBuffer.isEmpty)
    }

    @MainActor
    @Test("Stale stage-completion timeout does not cancel a newer waiter")
    func staleStageCompletionTimeoutDoesNotCancelNewerWaiter() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        let firstTestID = UUID()
        let secondTestID = UUID()

        let firstWaiter = Task {
            await service.awaitQualityTestStageCompletion(
                testID: firstTestID,
                stageID: 1,
                timeout: .milliseconds(50)
            )
        }

        try await Task.sleep(for: .milliseconds(10))

        let secondWaiter = Task {
            await service.awaitQualityTestStageCompletion(
                testID: secondTestID,
                stageID: 2,
                timeout: .seconds(1)
            )
        }

        let firstResult = await firstWaiter.value
        #expect(firstResult == nil)

        try await Task.sleep(for: .milliseconds(120))

        let expectedResult = QualityTestStageCompleteMessage(
            testID: secondTestID,
            stageID: 2,
            probeKind: .transport,
            targetBitrateBps: 64_000_000,
            configuredDurationMs: 1_500,
            startedAtTimestampNs: 300,
            measurementEndedAtTimestampNs: 1_500_000_300,
            completedAtTimestampNs: 1_500_000_600,
            sentPacketCount: 1_024,
            sentPayloadBytes: 2_048 * 1_024,
            deliveryWindowMissed: false
        )
        let message = try ControlMessage(
            type: .qualityTestStageComplete,
            content: expectedResult
        )
        service.handleQualityTestStageCompletion(message)

        let secondResult = await secondWaiter.value
        #expect(secondResult?.testID == secondTestID)
        #expect(secondResult?.stageID == expectedResult.stageID)
        #expect(secondResult?.sentPayloadBytes == expectedResult.sentPayloadBytes)
    }

    @MainActor
    @Test("Cancelling an active quality test resumes pending stage waiters immediately")
    func cancellingActiveQualityTestResumesPendingStageWaitersImmediately() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        let testID = UUID()
        service.qualityTestPendingTestID = testID

        let waiter = Task {
            await service.awaitQualityTestStageCompletion(
                testID: testID,
                stageID: 7,
                timeout: .seconds(30)
            )
        }

        try await Task.sleep(for: .milliseconds(10))
        await service.cancelActiveQualityTest(
            reason: "test cancellation",
            notifyHost: false
        )

        let result = await waiter.value
        #expect(result == nil)
        #expect(service.qualityTestPendingTestID == nil)
        #expect(service.qualityTestStageCompletionBuffer.isEmpty)

        let completion = QualityTestStageCompleteMessage(
            testID: testID,
            stageID: 7,
            probeKind: .transport,
            targetBitrateBps: 32_000_000,
            configuredDurationMs: 1_500,
            startedAtTimestampNs: 10,
            measurementEndedAtTimestampNs: 1_500_000_010,
            completedAtTimestampNs: 1_500_000_020,
            sentPacketCount: 100,
            sentPayloadBytes: 12_800,
            deliveryWindowMissed: false
        )
        let message = try ControlMessage(
            type: .qualityTestStageComplete,
            content: completion
        )
        service.handleQualityTestStageCompletion(message)

        #expect(service.qualityTestStageCompletionBuffer.isEmpty)
    }

    @Test("Stage completion timeout budget includes settle grace and control margin")
    func stageCompletionTimeoutBudgetIncludesSettleGraceAndMargin() {
        let stage = MirageQualityTestPlan.Stage(
            id: 1,
            probeKind: .transport,
            targetBitrateBps: 128_000_000,
            durationMs: 1_500,
            settleGraceMs: 900
        )

        #expect(
            MirageClientService.qualityTestStageCompletionTimeoutMs(for: stage)
                == stage.durationMs + stage.settleGraceMs + MirageClientService.qualityTestControlMessageMarginMs
        )
    }
}

@MainActor
private final class PingSendCounter {
    var value = 0
}

@MainActor
private func waitForPingRequestToStart(
    on service: MirageClientService,
    sendCounter: PingSendCounter,
    timeout: Duration = .seconds(1)
) async throws {
    try await waitForPingRequest(
        on: service,
        sendCounter: sendCounter,
        expectedSendCount: 1,
        minimumWaiterCount: 1,
        timeout: timeout
    )
}

@MainActor
private func waitForPingRequest(
    on service: MirageClientService,
    sendCounter: PingSendCounter,
    expectedSendCount: Int,
    minimumWaiterCount: Int,
    timeout: Duration = .seconds(1)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if service.pingContinuations.count >= minimumWaiterCount,
           sendCounter.value == expectedSendCount {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record(
        """
        Timed out waiting for ping request with sendCount=\(expectedSendCount), \
        waiters>=\(minimumWaiterCount); observed sendCount=\(sendCounter.value), \
        waiters=\(service.pingContinuations.count)
        """
    )
    throw MirageError.timeout
}
