//
//  MirageAwdlRouteHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Foundation
import MirageKit

/// Tracks active AWDL stream health and decides when the stream should reconnect on a lower route tier.
public struct MirageAwdlRouteHealthController: Sendable {
    /// Decision emitted by the AWDL route health controller.
    public struct Decision: Sendable, Equatable {
        public let reason: String
        public let degradedSampleCount: Int
        public let severeSampleCount: Int
    }

    private var streamStartedAt: CFAbsoluteTime?
    private var startedOnAwdl: Bool
    private var startupBitrateBps: Int?
    private var degradedSampleCount: Int = 0
    private var severeSampleCount: Int = 0
    private var earlyStartupFailureSampleCount: Int = 0
    private var hasEmittedDecision = false

    public init(
        startedOnAwdl: Bool = false,
        startupBitrateBps: Int? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        self.startedOnAwdl = startedOnAwdl
        self.startupBitrateBps = startupBitrateBps
        self.streamStartedAt = startedOnAwdl ? now : nil
    }

    /// Resets the controller for a new stream startup.
    public mutating func reset(
        startedOnAwdl: Bool,
        startupBitrateBps: Int? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        self.startedOnAwdl = startedOnAwdl
        self.startupBitrateBps = startupBitrateBps
        streamStartedAt = startedOnAwdl ? now : nil
        degradedSampleCount = 0
        severeSampleCount = 0
        earlyStartupFailureSampleCount = 0
        hasEmittedDecision = false
    }

    /// Advances AWDL health using the latest active stream snapshots.
    public mutating func advance(
        snapshots: [MirageClientMetricsSnapshot],
        currentPathKind: MirageNetworkPathKind?,
        currentBitrateBps: Int?,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Decision? {
        guard !hasEmittedDecision,
              startedOnAwdl,
              currentPathKind == .awdl,
              !snapshots.isEmpty else {
            return nil
        }
        if streamStartedAt == nil {
            streamStartedAt = now
        }
        guard let streamStartedAt else { return nil }

        let snapshot = Self.worstAwdlSnapshot(from: snapshots)
        let sample = MirageReceiverHealthController.sample(from: snapshot)
        let assessment = Self.assess(
            sample: sample,
            snapshot: snapshot,
            currentBitrateBps: currentBitrateBps,
            startupBitrateBps: startupBitrateBps
        )
        let age = now - streamStartedAt
        let isAtBitrateFloor = currentBitrateBps.map {
            $0 <= MirageReceiverHealthController.minimumBitrateBps
        } ?? false
        let localStartupFailure = Self.hasEarlyStartupFailure(snapshot)
        if assessment.isDegraded {
            degradedSampleCount += 1
        } else {
            degradedSampleCount = max(0, degradedSampleCount - 1)
        }

        if localStartupFailure,
           age >= Self.earlyDemotionMinimumAgeSeconds,
           age <= Self.earlyDemotionMaximumAgeSeconds {
            earlyStartupFailureSampleCount += 1
        } else {
            earlyStartupFailureSampleCount = max(0, earlyStartupFailureSampleCount - 1)
        }

        if assessment.isSevere && age >= Self.earlyDemotionMinimumAgeSeconds {
            severeSampleCount += 1
        } else {
            severeSampleCount = max(0, severeSampleCount - 1)
        }

        let shouldDemoteForSevereCollapse =
            age >= Self.severeDemotionMinimumAgeSeconds &&
            isAtBitrateFloor &&
            severeSampleCount >= Self.severeDemotionSampleThreshold
        let shouldDemoteForSustainedDegradation =
            age >= Self.sustainedDemotionMinimumAgeSeconds &&
            isAtBitrateFloor &&
            degradedSampleCount >= Self.sustainedDemotionSampleThreshold
        let shouldDemoteForEarlyStartupFailure =
            age >= Self.earlyDemotionMinimumAgeSeconds &&
            age <= Self.earlyDemotionMaximumAgeSeconds &&
            earlyStartupFailureSampleCount >= Self.earlyDemotionSampleThreshold

        guard shouldDemoteForEarlyStartupFailure ||
            shouldDemoteForSevereCollapse ||
            shouldDemoteForSustainedDegradation else {
            return nil
        }

        hasEmittedDecision = true
        return Decision(
            reason: assessment.reason,
            degradedSampleCount: degradedSampleCount,
            severeSampleCount: severeSampleCount
        )
    }

    private static func assess(
        sample: ReceiverHealthSample,
        snapshot: MirageClientMetricsSnapshot,
        currentBitrateBps: Int?,
        startupBitrateBps: Int?
    ) -> AwdlSampleAssessment {
        let receivedGapMs = max(0, snapshot.clientReceivedWorstGapMs)
        let pFrameP95Ms = max(0, snapshot.clientPFrameCompletionLatencyP95Ms)
        let pFrameMaxMs = max(0, snapshot.clientPFrameCompletionLatencyMaxMs)
        let severeArrivalGap = receivedGapMs >= severeReceivedGapMs
        let severePFrameLatency = pFrameP95Ms >= severePFrameLatencyP95Ms ||
            pFrameMaxMs >= severePFrameLatencyMaxMs
        let mediaDeliveryFailure = sample.hasReceiverMediaDeliveryFailure
        let bitrateCollapsed = Self.hasBitrateCollapsed(
            currentBitrateBps: currentBitrateBps,
            startupBitrateBps: startupBitrateBps
        )
        let localStartupFailure = Self.hasEarlyStartupFailure(snapshot)
        let degraded = sample.hasTransportPressure ||
            mediaDeliveryFailure ||
            sample.hasReceiverMediaLatencyPressure ||
            localStartupFailure ||
            bitrateCollapsed
        let severe = sample.hasSevereTransportPressure ||
            severeArrivalGap ||
            severePFrameLatency ||
            (mediaDeliveryFailure && (receivedGapMs >= degradedReceivedGapMs || pFrameP95Ms >= degradedPFrameLatencyP95Ms)) ||
            (bitrateCollapsed && sample.hasSevereTransportPressure)

        return AwdlSampleAssessment(
            isDegraded: degraded || severe,
            isSevere: severe,
            reason: Self.reason(
                sample: sample,
                bitrateCollapsed: bitrateCollapsed,
                receivedGapMs: receivedGapMs,
                pFrameP95Ms: pFrameP95Ms,
                pFrameMaxMs: pFrameMaxMs
            )
        )
    }

    private static func hasBitrateCollapsed(
        currentBitrateBps: Int?,
        startupBitrateBps: Int?
    ) -> Bool {
        guard let currentBitrateBps,
              let startupBitrateBps,
              currentBitrateBps > 0,
              startupBitrateBps > 0 else {
            return false
        }
        return currentBitrateBps <= Int(Double(startupBitrateBps) * bitrateCollapseRatio)
    }

    private static func hasEarlyStartupFailure(_ snapshot: MirageClientMetricsSnapshot) -> Bool {
        snapshot.clientPresentationStallCount > 0 ||
            snapshot.clientDroppedFrames > 0 ||
            snapshot.clientDecodeBacklogFrames >= earlyDecodeBacklogFrameThreshold
    }

    private static func reason(
        sample: ReceiverHealthSample,
        bitrateCollapsed: Bool,
        receivedGapMs: Double,
        pFrameP95Ms: Double,
        pFrameMaxMs: Double
    ) -> String {
        var components: [String] = []
        if let transportPressureReason = sample.transportPressureReason {
            components.append(transportPressureReason)
        }
        if bitrateCollapsed {
            components.append("bitrate collapsed below \(Int(bitrateCollapseRatio * 100))% of startup")
        }
        if receivedGapMs >= degradedReceivedGapMs {
            components.append("receive gap \(formatMilliseconds(receivedGapMs))")
        }
        if pFrameP95Ms >= degradedPFrameLatencyP95Ms || pFrameMaxMs >= severePFrameLatencyMaxMs {
            components.append(
                "p-frame latency p95=\(formatMilliseconds(pFrameP95Ms)) max=\(formatMilliseconds(pFrameMaxMs))"
            )
        }
        return components.isEmpty ? "sustained AWDL media degradation" : components.joined(separator: "; ")
    }

    private static func worstAwdlSnapshot(
        from snapshots: [MirageClientMetricsSnapshot]
    ) -> MirageClientMetricsSnapshot {
        MirageReceiverHealthController.worstSnapshot(
            from: snapshots,
            minimumHealthyFrameRate: nil
        )
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))ms"
    }
}

private struct AwdlSampleAssessment: Equatable {
    let isDegraded: Bool
    let isSevere: Bool
    let reason: String
}

extension MirageAwdlRouteHealthController {
    static let severeDemotionMinimumAgeSeconds: CFAbsoluteTime = 30
    static let sustainedDemotionMinimumAgeSeconds: CFAbsoluteTime = 90
    static let earlyDemotionMinimumAgeSeconds: CFAbsoluteTime = 15
    static let earlyDemotionMaximumAgeSeconds: CFAbsoluteTime = 30
    static let severeDemotionSampleThreshold = 2
    static let sustainedDemotionSampleThreshold = 4
    static let earlyDemotionSampleThreshold = 2
    static let earlyDecodeBacklogFrameThreshold = 30
    static let bitrateCollapseRatio = 0.55
    static let degradedReceivedGapMs = 500.0
    static let severeReceivedGapMs = 1_000.0
    static let degradedPFrameLatencyP95Ms = 250.0
    static let severePFrameLatencyP95Ms = 450.0
    static let severePFrameLatencyMaxMs = 1_000.0
}
