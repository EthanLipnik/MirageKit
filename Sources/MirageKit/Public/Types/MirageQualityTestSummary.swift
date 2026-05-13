//
//  MirageQualityTestSummary.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Summary output for connection quality tests.
//

import Foundation

/// Aggregated result from a Mirage connection quality test.
public struct MirageQualityTestSummary: Codable, Equatable, Sendable {
    /// Result for one executed quality-test stage.
    public struct StageResult: Codable, Equatable, Sendable, Identifiable {
        /// Stable identifier matching `stageID`.
        public var id: Int { stageID }
        /// Identifier of the plan stage that produced this result.
        public let stageID: Int
        /// Probe implementation used for the stage.
        public let probeKind: MirageQualityTestPlan.ProbeKind
        /// Bitrate requested for the stage.
        public let targetBitrateBps: Int
        /// Measurement duration in milliseconds.
        public let durationMs: Int
        /// Measured received throughput.
        public let throughputBps: Int
        /// Packet loss percentage observed during the stage.
        public let lossPercent: Double
        /// Number of packets sent by the probing side.
        public let sentPacketCount: Int
        /// Number of packets received by the measuring side.
        public let receivedPacketCount: Int
        /// Payload bytes sent by the probing side.
        public let sentPayloadBytes: Int
        /// Payload bytes received by the measuring side.
        public let receivedPayloadBytes: Int
        /// Whether expected delivery missed the stage's completion window.
        public let deliveryWindowMissed: Bool

        /// Creates one stage result.
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

    /// Identifier shared by all messages for the test run.
    public let testID: UUID
    /// Round-trip latency measured before or during the test.
    public let rttMs: Double
    /// Overall packet loss percentage.
    public let lossPercent: Double
    /// Estimated transport-only headroom.
    public let transportHeadroomBps: Int
    /// Streaming bitrate considered safe after replay validation.
    public let streamingSafeBitrateBps: Int
    /// Frame rate targeted by the test.
    public let targetFrameRate: Int
    /// Width used for streaming replay benchmark packets.
    public let benchmarkWidth: Int
    /// Height used for streaming replay benchmark packets.
    public let benchmarkHeight: Int
    /// Host-side encode latency estimate, when available.
    public let hostEncodeMs: Double?
    /// Client-side decode latency estimate, when available.
    public let clientDecodeMs: Double?
    /// Host capture capability inferred from the quality test, when available.
    public let hostCaptureCapability: MirageHostCaptureCapability?
    /// Results for each executed stage.
    public let stageResults: [StageResult]

    /// Creates a quality-test summary.
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
