//
//  ClientVideoIngressSamplers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
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

struct CountRateSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let count: Int
    }

    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 1.0

    mutating func record(count: Int = 1, now: CFAbsoluteTime) {
        samples.append(Sample(timestamp: now, count: max(0, count)))
        trim(now: now)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        guard startIndex < samples.count else { return 0 }
        return Double(samples[startIndex ..< samples.count].reduce(0) { $0 + $1.count })
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}

struct IngressIntervalSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let intervalMs: Double
    }

    struct Snapshot: Sendable, Equatable {
        let p95Ms: Double
        let p99Ms: Double
        let maxMs: Double
    }

    private var lastSampleTime: CFAbsoluteTime = 0
    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 2.0

    mutating func record(now: CFAbsoluteTime) {
        trim(now: now)
        guard lastSampleTime > 0 else {
            lastSampleTime = now
            return
        }
        let intervalMs = max(0, (now - lastSampleTime) * 1000)
        lastSampleTime = now
        samples.append(Sample(timestamp: now, intervalMs: intervalMs))
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Snapshot {
        trim(now: now)
        var active = startIndex < samples.count
            ? samples[startIndex ..< samples.count].map(\.intervalMs)
            : []
        if lastSampleTime > 0 {
            active.append(max(0, (now - lastSampleTime) * 1000))
        }
        guard !active.isEmpty else {
            return Snapshot(p95Ms: 0, p99Ms: 0, maxMs: 0)
        }
        let sorted = active.sorted()
        return Snapshot(
            p95Ms: percentile(sorted: sorted, percentile: 0.95),
            p99Ms: percentile(sorted: sorted, percentile: 0.99),
            maxMs: active.max() ?? 0
        )
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func percentile(sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0, min(1, percentile))
        let index = Int(ceil(clamped * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}

struct IngressMaximumSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let value: Double
    }

    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 2.0

    mutating func record(_ value: Double, now: CFAbsoluteTime) {
        samples.append(Sample(timestamp: now, value: max(0, value)))
        trim(now: now)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        guard startIndex < samples.count else { return 0 }
        return samples[startIndex ..< samples.count].map(\.value).max() ?? 0
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}
