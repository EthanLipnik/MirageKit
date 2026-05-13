//
//  MirageDiagnosticsSuppressionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

/// Tracks repeated breadcrumb-only events and escalates noisy patterns to captures.
public struct MirageDiagnosticsSuppressionState: Sendable {
    /// Default rolling window used for repeated-event suppression.
    public static let defaultWindow: TimeInterval = 600
    /// Default number of events in the rolling window before escalation.
    public static let defaultWindowThreshold = 5
    /// Default number of events during one launch before escalation.
    public static let defaultLaunchThreshold = 10

    private struct Bucket {
        var windowStart: TimeInterval
        var windowCount: Int
        var launchCount: Int
    }

    private var buckets: [String: Bucket] = [:]

    /// Creates an empty suppression tracker.
    public init() {}

    /// Returns whether a breadcrumb-only classification should be captured after repeated occurrences.
    public mutating func shouldEscalate(
        classification: MirageDiagnosticsEventClassification,
        at date: Date,
        window: TimeInterval = Self.defaultWindow,
        windowThreshold: Int = Self.defaultWindowThreshold,
        launchThreshold: Int = Self.defaultLaunchThreshold
    ) -> Bool {
        guard classification.disposition == .breadcrumbOnly,
              let suppressionKey = classification.suppressionKey else {
            return false
        }

        let now = date.timeIntervalSinceReferenceDate
        var bucket = buckets[suppressionKey] ?? Bucket(
            windowStart: now,
            windowCount: 0,
            launchCount: 0
        )

        if now - bucket.windowStart > window {
            bucket.windowStart = now
            bucket.windowCount = 0
        }

        bucket.windowCount += 1
        bucket.launchCount += 1
        buckets[suppressionKey] = bucket

        return bucket.windowCount == windowThreshold ||
            bucket.launchCount == launchThreshold ||
            (bucket.windowCount > windowThreshold && bucket.windowCount.isMultiple(of: windowThreshold)) ||
            (bucket.launchCount > launchThreshold && bucket.launchCount.isMultiple(of: launchThreshold))
    }
}
