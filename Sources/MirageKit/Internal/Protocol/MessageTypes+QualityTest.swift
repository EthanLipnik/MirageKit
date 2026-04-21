//
//  MessageTypes+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Control messages for quality testing.
//

import Foundation

package struct QualityTestRequestMessage: Codable {
    package let testID: UUID
    package let plan: MirageQualityTestPlan
    package let payloadBytes: Int
    package let mediaMaxPacketSize: Int
    package let stopAfterFirstBreach: Bool

    package init(
        testID: UUID,
        plan: MirageQualityTestPlan,
        payloadBytes: Int,
        mediaMaxPacketSize: Int,
        stopAfterFirstBreach: Bool = false
    ) {
        self.testID = testID
        self.plan = plan
        self.payloadBytes = payloadBytes
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.stopAfterFirstBreach = stopAfterFirstBreach
    }
}

package struct QualityTestCancelMessage: Codable {
    package let testID: UUID

    package init(testID: UUID) {
        self.testID = testID
    }
}

package struct QualityTestBenchmarkMessage: Codable {
    package let testID: UUID
    package let benchmarkWidth: Int
    package let benchmarkHeight: Int
    package let benchmarkFrameRate: Int
    package let encodeMs: Double?
    package let benchmarkVersion: Int
    package let hostCaptureCapability: MirageHostCaptureCapability?

    package init(
        testID: UUID,
        benchmarkWidth: Int,
        benchmarkHeight: Int,
        benchmarkFrameRate: Int,
        encodeMs: Double?,
        benchmarkVersion: Int,
        hostCaptureCapability: MirageHostCaptureCapability? = nil
    ) {
        self.testID = testID
        self.benchmarkWidth = benchmarkWidth
        self.benchmarkHeight = benchmarkHeight
        self.benchmarkFrameRate = benchmarkFrameRate
        self.encodeMs = encodeMs
        self.benchmarkVersion = benchmarkVersion
        self.hostCaptureCapability = hostCaptureCapability
    }
}

package struct QualityTestStageCompleteMessage: Codable {
    package let testID: UUID
    package let stageID: Int
    package let probeKind: MirageQualityTestPlan.ProbeKind
    package let targetBitrateBps: Int
    package let configuredDurationMs: Int
    package let startedAtTimestampNs: UInt64
    package let measurementEndedAtTimestampNs: UInt64
    package let completedAtTimestampNs: UInt64
    package let sentPacketCount: Int
    package let sentPayloadBytes: Int
    package let deliveryWindowMissed: Bool

    package init(
        testID: UUID,
        stageID: Int,
        probeKind: MirageQualityTestPlan.ProbeKind,
        targetBitrateBps: Int,
        configuredDurationMs: Int,
        startedAtTimestampNs: UInt64,
        measurementEndedAtTimestampNs: UInt64,
        completedAtTimestampNs: UInt64,
        sentPacketCount: Int,
        sentPayloadBytes: Int,
        deliveryWindowMissed: Bool
    ) {
        self.testID = testID
        self.stageID = stageID
        self.probeKind = probeKind
        self.targetBitrateBps = targetBitrateBps
        self.configuredDurationMs = configuredDurationMs
        self.startedAtTimestampNs = startedAtTimestampNs
        self.measurementEndedAtTimestampNs = measurementEndedAtTimestampNs
        self.completedAtTimestampNs = completedAtTimestampNs
        self.sentPacketCount = sentPacketCount
        self.sentPayloadBytes = sentPayloadBytes
        self.deliveryWindowMissed = deliveryWindowMissed
    }
}
