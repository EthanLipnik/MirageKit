//
//  MirageQualityTestSummary.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Summary output for automatic quality tests.
//

import Foundation

public struct MirageQualityTestSummary: Codable, Equatable, Sendable {
    public struct StageResult: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let stageID: Int
        public let targetBitrateBps: Int
        public let durationMs: Int
        public let throughputBps: Int
        public let lossPercent: Double

        public init(
            stageID: Int,
            targetBitrateBps: Int,
            durationMs: Int,
            throughputBps: Int,
            lossPercent: Double
        ) {
            id = stageID
            self.stageID = stageID
            self.targetBitrateBps = targetBitrateBps
            self.durationMs = durationMs
            self.throughputBps = throughputBps
            self.lossPercent = lossPercent
        }
    }

    public let testID: UUID
    public let rttMs: Double
    public let lossPercent: Double
    public let maxStableBitrateBps: Int
    public let targetFrameRate: Int
    public let benchmarkWidth: Int
    public let benchmarkHeight: Int
    public let hostEncodeMs: Double?
    public let clientDecodeMs: Double?
    public let stageResults: [StageResult]

    public init(
        testID: UUID,
        rttMs: Double,
        lossPercent: Double,
        maxStableBitrateBps: Int,
        targetFrameRate: Int,
        benchmarkWidth: Int,
        benchmarkHeight: Int,
        hostEncodeMs: Double?,
        clientDecodeMs: Double?,
        stageResults: [StageResult]
    ) {
        self.testID = testID
        self.rttMs = rttMs
        self.lossPercent = lossPercent
        self.maxStableBitrateBps = maxStableBitrateBps
        self.targetFrameRate = targetFrameRate
        self.benchmarkWidth = benchmarkWidth
        self.benchmarkHeight = benchmarkHeight
        self.hostEncodeMs = hostEncodeMs
        self.clientDecodeMs = clientDecodeMs
        self.stageResults = stageResults
    }
}
