//
//  MirageQualityTestPlan.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Quality test stage plan for automatic streaming configuration.
//

import Foundation

public struct MirageQualityTestPlan: Codable, Equatable, Sendable {
    public enum ProbeKind: String, Codable, Equatable, Sendable {
        case transport
        case streamingReplay
    }

    public struct Stage: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let probeKind: ProbeKind
        public let targetBitrateBps: Int
        public let durationMs: Int
        public let settleGraceMs: Int

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
                settleGraceMs ?? Self.defaultSettleGraceMs(forMeasurementDurationMs: durationMs)
            )
        }

        public var totalCompletionBudgetMs: Int {
            durationMs + settleGraceMs
        }

        private static func defaultSettleGraceMs(
            forMeasurementDurationMs durationMs: Int
        ) -> Int {
            min(1_000, max(500, durationMs))
        }
    }

    public let stages: [Stage]

    public init(stages: [Stage]) {
        self.stages = stages
    }

    public var totalDurationMs: Int {
        stages.reduce(0) { $0 + $1.totalCompletionBudgetMs }
    }
}
