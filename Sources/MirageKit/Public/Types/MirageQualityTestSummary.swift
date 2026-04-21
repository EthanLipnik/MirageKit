//
//  MirageQualityTestSummary.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Summary output for connection quality tests.
//

import Foundation

public struct MirageQualityTestSummary: Codable, Equatable, Sendable {
    public struct StageResult: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let stageID: Int
        public let probeKind: MirageQualityTestPlan.ProbeKind
        public let targetBitrateBps: Int
        public let durationMs: Int
        public let throughputBps: Int
        public let lossPercent: Double
        public let sentPacketCount: Int
        public let receivedPacketCount: Int
        public let sentPayloadBytes: Int
        public let receivedPayloadBytes: Int
        public let deliveryWindowMissed: Bool

        public init(
            stageID: Int,
            probeKind: MirageQualityTestPlan.ProbeKind,
            targetBitrateBps: Int,
            durationMs: Int,
            throughputBps: Int,
            lossPercent: Double,
            sentPacketCount: Int,
            receivedPacketCount: Int,
            sentPayloadBytes: Int,
            receivedPayloadBytes: Int,
            deliveryWindowMissed: Bool = false
        ) {
            id = stageID
            self.stageID = stageID
            self.probeKind = probeKind
            self.targetBitrateBps = targetBitrateBps
            self.durationMs = durationMs
            self.throughputBps = throughputBps
            self.lossPercent = lossPercent
            self.sentPacketCount = sentPacketCount
            self.receivedPacketCount = receivedPacketCount
            self.sentPayloadBytes = sentPayloadBytes
            self.receivedPayloadBytes = receivedPayloadBytes
            self.deliveryWindowMissed = deliveryWindowMissed
        }
    }

    public let testID: UUID
    public let rttMs: Double
    public let lossPercent: Double
    public let transportHeadroomBps: Int
    public let streamingSafeBitrateBps: Int
    public let targetFrameRate: Int
    public let benchmarkWidth: Int
    public let benchmarkHeight: Int
    public let hostEncodeMs: Double?
    public let clientDecodeMs: Double?
    public let hostCaptureCapability: MirageHostCaptureCapability?
    public let stageResults: [StageResult]

    public init(
        testID: UUID,
        rttMs: Double,
        lossPercent: Double,
        transportHeadroomBps: Int,
        streamingSafeBitrateBps: Int,
        targetFrameRate: Int,
        benchmarkWidth: Int,
        benchmarkHeight: Int,
        hostEncodeMs: Double?,
        clientDecodeMs: Double?,
        hostCaptureCapability: MirageHostCaptureCapability? = nil,
        stageResults: [StageResult]
    ) {
        self.testID = testID
        self.rttMs = rttMs
        self.lossPercent = lossPercent
        self.transportHeadroomBps = transportHeadroomBps
        self.streamingSafeBitrateBps = streamingSafeBitrateBps
        self.targetFrameRate = targetFrameRate
        self.benchmarkWidth = benchmarkWidth
        self.benchmarkHeight = benchmarkHeight
        self.hostEncodeMs = hostEncodeMs
        self.clientDecodeMs = clientDecodeMs
        self.hostCaptureCapability = hostCaptureCapability
        self.stageResults = stageResults
    }
}
