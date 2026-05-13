//
//  VideoEncoder+Metrics.swift
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
        defer { lock.unlock() }
        samples.append(durationMs)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    var averageMs: Double {
        let snapshot: [Double]
        lock.lock()
        do {
            defer { lock.unlock() }
            snapshot = samples
        }
        guard !snapshot.isEmpty else { return 0 }
        let total = snapshot.reduce(0, +)
        return total / Double(snapshot.count)
    }
}

#endif
