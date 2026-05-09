//
//  VideoDecoderSubmissionLimiterTests.swift
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
struct VideoDecoderSubmissionLimiterTests {
    @Test("Target refresh updates choose baseline decode submission limits")
    func submissionLimitUsesThroughputBaseline() async {
        let decoder = VideoDecoder()
        #expect(await decoder.currentDecodeSubmissionLimit() == 1)

        await decoder.setDecodeSubmissionLimit(targetFrameRate: 120)
        #expect(await decoder.currentDecodeSubmissionLimit() == 3)

        await decoder.setDecodeSubmissionLimit(targetFrameRate: 60)
        #expect(await decoder.currentDecodeSubmissionLimit() == 2)
    }

    @Test("Submission limiter enforces cap and releases waiters")
    func submissionLimiterEnforcesCapAndRelease() async throws {
        let decoder = VideoDecoder()
        await decoder.setDecodeSubmissionLimit(limit: 3, reason: "test setup")

        let first = try #require(await decoder.acquireDecodeSubmissionSlot())
        let second = try #require(await decoder.acquireDecodeSubmissionSlot())
        let third = try #require(await decoder.acquireDecodeSubmissionSlot())
        #expect(await decoder.currentInFlightDecodeSubmissions() == 3)

        let fourthAcquired = LockedBool()
        let fourthLease = LockedLease()
        let waitingTask = Task {
            let lease = await decoder.acquireDecodeSubmissionSlot()
            fourthLease.store(lease)
            fourthAcquired.setTrue()
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(fourthAcquired.value == false)

        await decoder.releaseDecodeSubmissionSlot(first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fourthAcquired.value == true)

        if let lease = fourthLease.value {
            await decoder.releaseDecodeSubmissionSlot(lease)
        }
        await decoder.releaseDecodeSubmissionSlot(second)
        await decoder.releaseDecodeSubmissionSlot(third)
        _ = await waitingTask.result
        #expect(await decoder.currentInFlightDecodeSubmissions() == 0)
    }

    @Test("Cancelled submission waiters are removed")
    func cancelledSubmissionWaiterIsRemoved() async throws {
        let decoder = VideoDecoder()
        await decoder.setDecodeSubmissionLimit(limit: 1, reason: "test setup")

        let held = try #require(await decoder.acquireDecodeSubmissionSlot())
        let waitingTask = Task {
            await decoder.acquireDecodeSubmissionSlot()
        }

        try await Task.sleep(for: .milliseconds(50))
        waitingTask.cancel()
        let cancelledLease = await waitingTask.value
        #expect(cancelledLease == nil)

        await decoder.releaseDecodeSubmissionSlot(held)
        try await Task.sleep(for: .milliseconds(50))
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

private final class LockedLease: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: VideoDecoder.DecodeSubmissionLease?

    var value: VideoDecoder.DecodeSubmissionLease? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ lease: VideoDecoder.DecodeSubmissionLease?) {
        lock.lock()
        storage = lease
        lock.unlock()
    }
}
#endif
