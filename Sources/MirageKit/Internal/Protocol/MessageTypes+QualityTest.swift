//
//  MessageTypes+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Control messages for quality testing.
//

import Foundation

/// Client-to-host request to run a media transport quality test.
package struct QualityTestRequestMessage: Codable {
    /// Test run identifier.
    package let testID: UUID

    /// Ordered stages and probe definitions to execute.
    package let plan: MirageQualityTestPlan

    /// Payload bytes to send per probe packet.
    package let payloadBytes: Int

    /// Requested media packet size for test packets.
    package let mediaMaxPacketSize: Int

    /// Whether the host should stop after the first stage that breaches limits.
    package let stopAfterFirstBreach: Bool

    /// Byte count for a Loom object-transfer based connection test, or zero for staged probes.
    package let transferByteCount: UInt64

    /// Creates a quality-test request.
    package init(
        testID: UUID,
        plan: MirageQualityTestPlan,
        payloadBytes: Int,
        mediaMaxPacketSize: Int,
        stopAfterFirstBreach: Bool = false,
        transferByteCount: UInt64 = 0
    ) {
        self.testID = testID
        self.plan = plan
        self.payloadBytes = payloadBytes
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.stopAfterFirstBreach = stopAfterFirstBreach
        self.transferByteCount = transferByteCount
    }
}

/// Client-to-host request to cancel a running quality test.
package struct QualityTestCancelMessage: Codable {
    /// Test run to cancel.
    package let testID: UUID

    /// Creates a quality-test cancellation request.
    package init(testID: UUID) {
        self.testID = testID
    }
}

/// Host-to-client benchmark result captured before a quality test starts.
package struct QualityTestBenchmarkMessage: Codable {
    /// Test run identifier.
    package let testID: UUID

    /// Measured encode time in milliseconds, when available.
    package let encodeMs: Double?

    /// Host capture capability snapshot observed during benchmarking.
    package let hostCaptureCapability: MirageHostCaptureCapability?

    /// Creates a quality-test benchmark payload.
    package init(
        testID: UUID,
        encodeMs: Double?,
        hostCaptureCapability: MirageHostCaptureCapability? = nil
    ) {
        self.testID = testID
        self.encodeMs = encodeMs
        self.hostCaptureCapability = hostCaptureCapability
    }
}

/// Host-to-client completion result for one quality-test stage.
package struct QualityTestStageCompleteMessage: Codable {
    /// Test run identifier.
    package let testID: UUID

    /// Stage identifier from the quality-test plan.
    package let stageID: Int

    /// Probe kind that completed.
    package let probeKind: MirageQualityTestPlan.ProbeKind

    /// Stage start timestamp in nanoseconds.
    package let startedAtTimestampNs: UInt64

    /// Measurement end timestamp in nanoseconds.
    package let measurementEndedAtTimestampNs: UInt64

    /// Packets submitted during the stage.
    package let sentPacketCount: Int

    /// Payload bytes submitted during the stage.
    package let sentPayloadBytes: Int

    /// Whether the stage missed its delivery window.
    package let deliveryWindowMissed: Bool

    /// Creates a quality-test stage completion payload.
    package init(
        testID: UUID,
        stageID: Int,
        probeKind: MirageQualityTestPlan.ProbeKind,
        startedAtTimestampNs: UInt64,
        measurementEndedAtTimestampNs: UInt64,
        sentPacketCount: Int,
        sentPayloadBytes: Int,
        deliveryWindowMissed: Bool
    ) {
        self.testID = testID
        self.stageID = stageID
        self.probeKind = probeKind
        self.startedAtTimestampNs = startedAtTimestampNs
        self.measurementEndedAtTimestampNs = measurementEndedAtTimestampNs
        self.sentPacketCount = sentPacketCount
        self.sentPayloadBytes = sentPayloadBytes
        self.deliveryWindowMissed = deliveryWindowMissed
    }
}
