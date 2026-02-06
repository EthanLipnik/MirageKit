//
//  ClientFrameMetricsTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/25/26.
//
//  Lock-based frame metrics sampling for client streams.
//

import Foundation
import MirageKit

final class ClientFrameMetricsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedSampler = FrameRateSampler()
    private var receivedSampler = FrameRateSampler()
    private var queueDroppedFrames: UInt64 = 0
    private var sentFirstFrame = false

    func recordDecodedFrame(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        _ = decodedSampler.record(now: now)
        let isFirstFrame = !sentFirstFrame
        if isFirstFrame { sentFirstFrame = true }
        lock.unlock()
        return isFirstFrame
    }

    func recordReceivedFrame(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock()
        _ = receivedSampler.record(now: now)
        lock.unlock()
    }

    func recordQueueDrop(count: UInt64 = 1) {
        lock.lock()
        queueDroppedFrames &+= count
        lock.unlock()
    }

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent())
    -> (decodedFPS: Double, receivedFPS: Double, queueDroppedFrames: UInt64) {
        lock.lock()
        let decodedFPS = decodedSampler.snapshot(now: now)
        let receivedFPS = receivedSampler.snapshot(now: now)
        let dropped = queueDroppedFrames
        lock.unlock()
        return (decodedFPS, receivedFPS, dropped)
    }

    func reset() {
        lock.lock()
        decodedSampler.reset()
        receivedSampler.reset()
        queueDroppedFrames = 0
        sentFirstFrame = false
        lock.unlock()
    }
}

private struct FrameRateSampler {
    private var samples: [CFAbsoluteTime] = []
    private var startIndex: Int = 0
    private let windowSeconds: CFAbsoluteTime = 1.0

    mutating func record(now: CFAbsoluteTime) -> Double {
        samples.append(now)
        trim(now: now)
        return Double(samples.count - startIndex)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        return Double(samples.count - startIndex)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
        startIndex = 0
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex] < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}
