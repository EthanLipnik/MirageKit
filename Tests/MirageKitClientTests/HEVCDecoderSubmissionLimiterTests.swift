//
//  HEVCDecoderSubmissionLimiterTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/12/26.
//
//  Coverage for bounded decode submission behavior.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("HEVC Decoder Submission Limiter")
struct HEVCDecoderSubmissionLimiterTests {
    @Test("Target refresh updates choose baseline decode submission limits")
    func submissionLimitUsesLatencyFirstBaseline() async {
        let decoder = HEVCDecoder()
        #expect(await decoder.currentDecodeSubmissionLimit() == 1)

        await decoder.setDecodeSubmissionLimit(targetFrameRate: 120)
        #expect(await decoder.currentDecodeSubmissionLimit() == 3)

        await decoder.setDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await decoder.currentDecodeSubmissionLimit() == 2)
    }

    @Test("Submission limiter enforces cap and releases waiters")
    func submissionLimiterEnforcesCapAndRelease() async throws {
        let decoder = HEVCDecoder()
        await decoder.setDecodeSubmissionLimit(limit: 3, reason: "test setup")

        await decoder.acquireDecodeSubmissionSlot()
        await decoder.acquireDecodeSubmissionSlot()
        await decoder.acquireDecodeSubmissionSlot()
        #expect(await decoder.currentInFlightDecodeSubmissions() == 3)

        let fourthAcquired = LockedBool()
        let waitingTask = Task {
            await decoder.acquireDecodeSubmissionSlot()
            fourthAcquired.setTrue()
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(fourthAcquired.value == false)

        await decoder.releaseDecodeSubmissionSlot()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fourthAcquired.value == true)

        await decoder.releaseDecodeSubmissionSlot()
        await decoder.releaseDecodeSubmissionSlot()
        await decoder.releaseDecodeSubmissionSlot()
        _ = await waitingTask.result
        #expect(await decoder.currentInFlightDecodeSubmissions() == 0)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setTrue() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
#endif
