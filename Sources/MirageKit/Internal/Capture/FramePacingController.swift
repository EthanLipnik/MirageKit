//
//  FramePacingController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import Foundation

#if os(macOS)

/// Frame pacing controller for consistent frame timing.
final class FramePacingController: @unchecked Sendable {
    private let lock = NSLock()
    private var targetFrameInterval: TimeInterval
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    private let toleranceFactor: Double = 0.9

    init(targetFPS: Int) {
        let clamped = max(1, targetFPS)
        self.targetFrameInterval = 1.0 / Double(clamped)
    }

    func updateTargetFPS(_ targetFPS: Int) {
        let clamped = max(1, targetFPS)
        lock.lock()
        targetFrameInterval = 1.0 / Double(clamped)
        lastFrameTime = 0
        frameCount = 0
        droppedCount = 0
        lock.unlock()
    }

    /// Check if a frame should be captured based on timing.
    func shouldCaptureFrame(at time: CFAbsoluteTime) -> Bool {
        lock.lock()
        if lastFrameTime == 0 {
            lastFrameTime = time
            frameCount += 1
            lock.unlock()
            return true
        }

        let elapsedSeconds = time - lastFrameTime
        if elapsedSeconds >= targetFrameInterval * toleranceFactor {
            lastFrameTime = time
            frameCount += 1
            lock.unlock()
            return true
        }

        droppedCount += 1
        lock.unlock()
        return false
    }

    /// Get statistics.
    func getStatistics() -> (frames: UInt64, dropped: UInt64) {
        lock.lock()
        let stats = (frameCount, droppedCount)
        lock.unlock()
        return stats
    }
}

#endif
