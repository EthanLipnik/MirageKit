//
//  HEVCEncoder+Metrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension EncodePerformanceTracker {
    func record(durationMs: Double) {
        lock.lock()
        samples.append(durationMs)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        lock.unlock()
    }

    func averageMs() -> Double {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return 0 }
        let total = snapshot.reduce(0, +)
        return total / Double(snapshot.count)
    }
}

#endif
