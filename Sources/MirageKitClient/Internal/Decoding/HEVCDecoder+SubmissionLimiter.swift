//
//  HEVCDecoder+SubmissionLimiter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  HEVC decoder submission limiter extensions.
//

import Foundation
import MirageKit

extension HEVCDecoder {
    func setDecodeSubmissionLimit(targetFrameRate: Int) {
        let desiredLimit = 1
        setDecodeSubmissionLimit(limit: desiredLimit, reason: "target \(targetFrameRate)fps")
    }

    func setDecodeSubmissionLimit(limit: Int, reason: String? = nil) {
        let desiredLimit = min(max(1, limit), 2)
        guard desiredLimit != decodeSubmissionLimit else { return }
        decodeSubmissionLimit = desiredLimit
        drainDecodeSubmissionWaiters()
        if let reason {
            MirageLogger.decoder("Decode submission limit set to \(desiredLimit) (\(reason))")
        } else {
            MirageLogger.decoder("Decode submission limit set to \(desiredLimit)")
        }
    }

    func currentDecodeSubmissionLimit() -> Int {
        decodeSubmissionLimit
    }

    func currentInFlightDecodeSubmissions() -> Int {
        inFlightDecodeSubmissions
    }

    func acquireDecodeSubmissionSlot() async {
        if inFlightDecodeSubmissions < decodeSubmissionLimit {
            inFlightDecodeSubmissions += 1
            return
        }
        await withCheckedContinuation { continuation in
            decodeSubmissionWaiters.append(continuation)
        }
    }

    func releaseDecodeSubmissionSlot() {
        if inFlightDecodeSubmissions > 0 {
            inFlightDecodeSubmissions -= 1
        }
        drainDecodeSubmissionWaiters()
    }

    func resetDecodeSubmissionSlots() {
        inFlightDecodeSubmissions = 0
        drainDecodeSubmissionWaiters()
    }

    private func drainDecodeSubmissionWaiters() {
        while inFlightDecodeSubmissions < decodeSubmissionLimit, !decodeSubmissionWaiters.isEmpty {
            inFlightDecodeSubmissions += 1
            let waiter = decodeSubmissionWaiters.removeFirst()
            waiter.resume()
        }
    }
}
