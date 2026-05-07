//
//  DecodeRecoveryAdmissionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Decode Recovery Admission")
struct DecodeRecoveryAdmissionTests {
    @Test("Callback failure limiter coalesces repeated status logs")
    func callbackFailureLimiterCoalescesRepeatedStatusLogs() {
        let limiter = DecodeCallbackFailureLogLimiter(interval: 1.0)
        let status = OSStatus(-12909)

        let first = limiter.record(status: status, now: 10.0)
        let second = limiter.record(status: status, now: 10.2)
        let third = limiter.record(status: status, now: 10.4)
        let afterInterval = limiter.record(status: status, now: 11.1)

        #expect(first == DecodeCallbackFailureLogLimiter.Decision(shouldLog: true, suppressedCount: 0))
        #expect(second == DecodeCallbackFailureLogLimiter.Decision(shouldLog: false, suppressedCount: 0))
        #expect(third == DecodeCallbackFailureLogLimiter.Decision(shouldLog: false, suppressedCount: 0))
        #expect(afterInterval == DecodeCallbackFailureLogLimiter.Decision(shouldLog: true, suppressedCount: 2))
    }

    @Test("Session reset blocks P-frame admission until a recovery keyframe decodes")
    func sessionResetBlocksPFrameAdmissionUntilRecoveryKeyframeDecodes() {
        let tracker = DecodeErrorTracker(maxErrors: 2, onThresholdReached: {})

        tracker.clearForSessionReset()

        #expect(!tracker.shouldDecodeFrame(isKeyframe: false))
        #expect(tracker.shouldDecodeFrame(isKeyframe: true))

        tracker.recordSuccess(isKeyframe: true)

        #expect(tracker.shouldDecodeFrame(isKeyframe: false))
    }

    @Test("Decode error threshold blocks P-frame admission until a keyframe decodes")
    func decodeErrorThresholdBlocksPFrameAdmissionUntilKeyframeDecodes() {
        let thresholdRequests = TestCounter()
        let tracker = DecodeErrorTracker(maxErrors: 2) {
            thresholdRequests.increment()
        }

        tracker.recordError(isKeyframe: false)
        tracker.recordError(isKeyframe: false)

        #expect(thresholdRequests.value == 1)
        #expect(!tracker.shouldDecodeFrame(isKeyframe: false))
        #expect(tracker.shouldDecodeFrame(isKeyframe: true))

        tracker.recordSuccess(isKeyframe: true)

        #expect(tracker.shouldDecodeFrame(isKeyframe: false))
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
