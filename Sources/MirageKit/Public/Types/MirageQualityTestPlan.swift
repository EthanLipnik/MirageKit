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
    public struct Stage: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let targetBitrateBps: Int
        public let durationMs: Int

        public init(id: Int, targetBitrateBps: Int, durationMs: Int) {
            self.id = id
            self.targetBitrateBps = targetBitrateBps
            self.durationMs = durationMs
        }
    }

    public let stages: [Stage]

    public init(stages: [Stage]) {
        self.stages = stages
    }

    public var totalDurationMs: Int {
        stages.reduce(0) { $0 + $1.durationMs }
    }
}
