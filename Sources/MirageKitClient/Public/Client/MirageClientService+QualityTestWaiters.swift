//
//  MirageClientService+QualityTestWaiters.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

@MainActor
extension MirageClientService {
    /// Waits for the host benchmark result for a specific quality-test run.
    func awaitQualityTestBenchmark(
        testID: UUID,
        timeout: Duration
    ) async -> MirageWire.QualityTestBenchmarkMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            completeQualityTestBenchmarkWaiter(result: nil)
            completeQualityTestStageCompletionWaiter(result: nil)
            qualityTestStageCompletionBuffer.removeAll()
        }

        qualityTestBenchmarkWaiterID &+= 1
        let waiterID = qualityTestBenchmarkWaiterID
        qualityTestPendingTestID = testID

        return await withCheckedContinuation { continuation in
            qualityTestBenchmarkContinuation = continuation
            qualityTestBenchmarkTimeoutTask?.cancel()
            qualityTestBenchmarkTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.completeQualityTestBenchmarkWaiter(
                    expectedWaiterID: waiterID,
                    expectedTestID: testID,
                    result: nil
                )
            }
        }
    }

    /// Waits for the host to finish a specific quality-test stage.
    func awaitQualityTestStageCompletion(
        testID: UUID,
        stageID: Int,
        timeout: Duration
    ) async -> MirageWire.QualityTestStageCompleteMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            completeQualityTestBenchmarkWaiter(result: nil)
            completeQualityTestStageCompletionWaiter(result: nil)
            qualityTestStageCompletionBuffer.removeAll()
        }

        qualityTestPendingTestID = testID
        if let bufferedIndex = qualityTestStageCompletionBuffer.firstIndex(where: { completion in
            completion.testID == testID && completion.stageID == stageID
        }) {
            return qualityTestStageCompletionBuffer.remove(at: bufferedIndex)
        }

        qualityTestStageCompletionWaiterID &+= 1
        let waiterID = qualityTestStageCompletionWaiterID
        return await withCheckedContinuation { continuation in
            qualityTestStageCompletionContinuation = continuation
            qualityTestStageCompletionTimeoutTask?.cancel()
            qualityTestStageCompletionTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.completeQualityTestStageCompletionWaiter(
                    expectedWaiterID: waiterID,
                    expectedTestID: testID,
                    result: nil
                )
            }
        }
    }

    /// Completes and clears the active benchmark waiter if the optional guards match.
    func completeQualityTestBenchmarkWaiter(
        expectedWaiterID: UInt64? = nil,
        expectedTestID: UUID? = nil,
        result: MirageWire.QualityTestBenchmarkMessage?
    ) {
        if let expectedWaiterID, qualityTestBenchmarkWaiterID != expectedWaiterID { return }
        if let expectedTestID, qualityTestPendingTestID != expectedTestID { return }
        qualityTestBenchmarkTimeoutTask?.cancel()
        qualityTestBenchmarkTimeoutTask = nil
        guard let continuation = qualityTestBenchmarkContinuation else { return }
        qualityTestBenchmarkContinuation = nil
        continuation.resume(returning: result)
    }

    /// Completes and clears the active stage-completion waiter if the optional guards match.
    func completeQualityTestStageCompletionWaiter(
        expectedWaiterID: UInt64? = nil,
        expectedTestID: UUID? = nil,
        result: MirageWire.QualityTestStageCompleteMessage?
    ) {
        if let expectedWaiterID, qualityTestStageCompletionWaiterID != expectedWaiterID { return }
        if let expectedTestID, qualityTestPendingTestID != expectedTestID { return }
        qualityTestStageCompletionTimeoutTask?.cancel()
        qualityTestStageCompletionTimeoutTask = nil
        guard let continuation = qualityTestStageCompletionContinuation else { return }
        qualityTestStageCompletionContinuation = nil
        continuation.resume(returning: result)
    }
}
