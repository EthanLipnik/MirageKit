//
//  MirageQualityTestPlan.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Quality test stage plan for automatic streaming configuration.
//

import Foundation

/// Ordered bitrate-probe plan used to measure transport and streaming replay quality.
public struct MirageQualityTestPlan: Codable, Equatable, Sendable {
    /// Probe implementation used for a stage.
    public enum ProbeKind: String, Codable, Equatable, Sendable {
        /// Measures packet delivery over the transport without full media replay.
        case transport
        /// Measures the full streaming replay path at the target bitrate.
        case streamingReplay
    }

    /// One measurement stage in a quality test plan.
    public struct Stage: Codable, Equatable, Sendable, Identifiable {
        /// Stable stage identifier used in control messages and summaries.
        public let id: Int
        /// Probe implementation to run for this stage.
        public let probeKind: ProbeKind
        /// Target bitrate for packets or replayed media during the stage.
        public let targetBitrateBps: Int
        /// Primary measurement window in milliseconds.
        public let durationMs: Int
        /// Additional time after measurement for in-flight packets and control completion.
        public let settleGraceMs: Int

        /// Creates one quality-test stage.
        ///
        /// When `settleGraceMs` is omitted, the stage uses a bounded grace window based on
        /// the measurement duration so the host can drain queued packets before reporting
        /// delivery-window misses.
        public init(
            id: Int,
            probeKind: ProbeKind,
            targetBitrateBps: Int,
            durationMs: Int,
            settleGraceMs: Int? = nil
        ) {
            self.id = id
            self.probeKind = probeKind
            self.targetBitrateBps = targetBitrateBps
            self.durationMs = durationMs
            self.settleGraceMs = max(
                0,
                settleGraceMs ?? min(1_000, max(500, durationMs))
            )
        }

        /// Measurement plus settle grace used by client waiters for stage completion.
        public var totalCompletionBudgetMs: Int {
            durationMs + settleGraceMs
        }
    }

    /// Stages to execute in order.
    public let stages: [Stage]

    /// Creates a quality-test plan.
    public init(stages: [Stage]) {
        self.stages = stages
    }

    /// Total wall-clock budget for all stages, including settle grace.
    public var totalDurationMs: Int {
        stages.reduce(0) { $0 + $1.totalCompletionBudgetMs }
    }
}
