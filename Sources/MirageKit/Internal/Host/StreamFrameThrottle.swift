//
//  StreamFrameThrottle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/26/26.
//
//  Drops captured frames when capture cadence exceeds the encoder target.
//

import CoreMedia
import Foundation

#if os(macOS)

final class StreamFrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var minInterval: CMTime = .invalid
    private var lastAcceptedTime: CMTime = .invalid
    private let toleranceFactor: Float64 = 0.9

    func configure(targetFrameRate: Int, captureFrameRate: Int, isPaced: Bool = false) {
        lock.lock()
        let clampedTarget = max(1, targetFrameRate)
        // When the capture pipeline is already paced to the target FPS,
        // a second throttle here just double-drops frames and lowers cadence.
        if !isPaced, captureFrameRate > clampedTarget {
            isEnabled = true
            minInterval = CMTime(value: 1, timescale: CMTimeScale(clampedTarget))
        } else {
            isEnabled = false
            minInterval = .invalid
        }
        lastAcceptedTime = .invalid
        lock.unlock()
    }

    func shouldDrop(_ frame: CapturedFrame) -> Bool {
        lock.lock()
        guard isEnabled, minInterval.isValid, frame.presentationTime.isValid else {
            lock.unlock()
            return false
        }
        if !lastAcceptedTime.isValid {
            lastAcceptedTime = frame.presentationTime
            lock.unlock()
            return false
        }
        let delta = CMTimeSubtract(frame.presentationTime, lastAcceptedTime)
        if !delta.isValid || CMTimeCompare(delta, .zero) <= 0 {
            lastAcceptedTime = frame.presentationTime
            lock.unlock()
            return false
        }
        let threshold = CMTimeMultiplyByFloat64(minInterval, multiplier: toleranceFactor)
        if CMTimeCompare(delta, threshold) < 0 {
            lock.unlock()
            return true
        }
        lastAcceptedTime = frame.presentationTime
        lock.unlock()
        return false
    }

    func reset() {
        lock.lock()
        lastAcceptedTime = .invalid
        lock.unlock()
    }
}

#endif
