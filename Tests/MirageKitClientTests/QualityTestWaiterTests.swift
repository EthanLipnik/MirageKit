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
    @Test("Stale quality-test timeout does not cancel a newer waiter")
    func staleQualityTestTimeoutDoesNotCancelNewerWaiter() async throws {
        let service = MirageClientService(deviceName: "Test Device")
        let firstTestID = UUID()
        let secondTestID = UUID()

        let firstWaiter = Task {
            await service.awaitQualityTestResult(
                testID: firstTestID,
                timeout: .milliseconds(50)
            )
        }

        try await Task.sleep(for: .milliseconds(10))

        let secondWaiter = Task {
            await service.awaitQualityTestResult(
                testID: secondTestID,
                timeout: .seconds(1)
            )
        }

        let firstResult = await firstWaiter.value
        #expect(firstResult == nil)

        try await Task.sleep(for: .milliseconds(120))

        let expectedResult = QualityTestResultMessage(
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
        service.handleQualityTestResult(message)

        let secondResult = await secondWaiter.value
        #expect(secondResult?.testID == secondTestID)
        #expect(secondResult?.benchmarkWidth == expectedResult.benchmarkWidth)
    }
}
