//
//  MirageClientService+QualityTestPlanning.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

@MainActor
extension MirageClientService {
    /// Tunable parameters for one quality-test probe family.
    struct QualityTestProbeProfile {
        /// Transport path measured by this profile.
        let probeKind: MirageDiagnostics.MirageQualityTestPlan.ProbeKind

        /// Lowest bitrate sampled by the sweep.
        let minTargetBitrate: Int

        /// Highest bitrate the sweep may request.
        let maxTargetBitrate: Int

        /// Warmup time before measurements are considered stable.
        let warmupDurationMs: Int

        /// Measurement time for each stage.
        let stageDurationMs: Int

        /// Multiplier used when generating the next sweep target.
        let growthFactor: Double

        /// Upper bound on generated stages for this probe family.
        let maxStages: Int

        /// Optional throughput floor relative to requested payload bitrate.
        let throughputFloor: Double?

        /// Maximum acceptable packet loss for a stable stage.
        let lossCeiling: Double

        /// Whether the generated plan should include refinement targets around successful stages.
        let includesRefinementTargets: Bool
    }

    /// Pair of transport and streaming-replay profiles for a quality-test mode.
    struct QualityTestModeProfile {
        /// Probe profile for raw transport throughput.
        let transport: QualityTestProbeProfile

        /// Probe profile for in-stream replay throughput.
        let streamingReplay: QualityTestProbeProfile
    }

    /// Fully expanded quality-test plan plus stage ownership metadata.
    struct QualityTestExecutionPlan {
        /// Ordered stages sent to the host.
        let plan: MirageDiagnostics.MirageQualityTestPlan

        /// Stage IDs contributing to the transport summary.
        let transportMeasurementStageIDs: Set<Int>

        /// Stage IDs contributing to the streaming summary.
        let streamingReplayMeasurementStageIDs: Set<Int>

        /// Whether the sweep should stop when a stage breaches the loss threshold.
        let stopAfterFirstBreach: Bool
    }

    /// Reduced result for one quality-test phase.
    struct QualityTestPhaseSummary {
        /// Selected bitrate for the phase, in bits per second.
        let bitrateBps: Int

        /// Loss percentage associated with the selected bitrate.
        let lossPercent: Double
    }

    /// Selects the stable bitrate and loss value for one quality-test phase.
    nonisolated static func summarizeQualityTestPhase(
        stageResults: [MirageDiagnostics.MirageQualityTestSummary.StageResult],
        measurementStageIDs: Set<Int>,
        throughputFloor: Double?,
        lossCeiling: Double,
        payloadBytes: Int,
        requiresLossBelowCeiling: Bool = false,
        allowsMeasuredFallback: Bool = true
    ) -> QualityTestPhaseSummary {
        let measuredStages =
            stageResults
                .filter { measurementStageIDs.contains($0.stageID) }
                .sorted { $0.stageID < $1.stageID }

        var lastStableBitrate = 0
        var lastStableLoss = 0.0
        var candidateBitrate = 0
        var candidateLoss = 0.0

        for stage in measuredStages {
            if stage.throughputBps > candidateBitrate {
                candidateBitrate = stage.throughputBps
                candidateLoss = stage.lossPercent
            }
            if qualityTestStageIsStable(
                stage,
                targetBitrate: stage.targetBitrateBps,
                payloadBytes: payloadBytes,
                throughputFloor: throughputFloor,
                lossCeiling: lossCeiling,
                requiresLossBelowCeiling: requiresLossBelowCeiling
            ) {
                lastStableBitrate = stage.throughputBps
                lastStableLoss = stage.lossPercent
            }
        }

        let bitrateBps: Int = if lastStableBitrate > 0 || !allowsMeasuredFallback {
            lastStableBitrate
        } else {
            max(0, candidateBitrate)
        }

        let lossPercent: Double = if lastStableBitrate > 0 {
            lastStableLoss
        } else if allowsMeasuredFallback {
            candidateLoss
        } else {
            0
        }
        return QualityTestPhaseSummary(
            bitrateBps: bitrateBps,
            lossPercent: lossPercent
        )
    }

    /// Resolves transport and streaming bitrate fields for the final public summary.
    nonisolated static func resolvedQualityTestSummaryBitrates(
        mode: MirageQualityTestMode,
        transportSummary: QualityTestPhaseSummary,
        streamingSummary: QualityTestPhaseSummary
    ) -> (transportHeadroomBps: Int, streamingSafeBitrateBps: Int) {
        let transportHeadroomBps = transportSummary.bitrateBps
        let streamingSafeBitrateBps: Int = switch mode {
        case .automaticSelection:
            streamingSummary.bitrateBps
        case .connectionLimit:
            // Manual connection-limit probes can terminate during transport before any
            // replay stages are sampled. Surface the last clean transport bitrate as the
            // best available safe estimate instead of reporting an artificial zero.
            streamingSummary.bitrateBps > 0
                ? streamingSummary.bitrateBps
                : transportHeadroomBps
        }

        return (
            transportHeadroomBps: transportHeadroomBps,
            streamingSafeBitrateBps: streamingSafeBitrateBps
        )
    }

    /// Returns whether one measured stage satisfies the loss and throughput constraints for its phase.
    nonisolated static func qualityTestStageIsStable(
        _ stage: MirageDiagnostics.MirageQualityTestSummary.StageResult,
        targetBitrate: Int,
        payloadBytes: Int,
        throughputFloor: Double?,
        lossCeiling: Double,
        requiresLossBelowCeiling: Bool = false
    ) -> Bool {
        if requiresLossBelowCeiling {
            guard stage.lossPercent < lossCeiling else { return false }
        } else {
            guard stage.lossPercent <= lossCeiling else { return false }
        }
        guard !stage.deliveryWindowMissed else { return false }
        guard let throughputFloor else { return true }
        let packetBytes = payloadBytes + MirageWire.mirageQualityTestHeaderSize
        let payloadRatio =
            packetBytes > 0
                ? Double(payloadBytes) / Double(packetBytes)
                : 1.0
        let targetPayloadBps = Double(targetBitrate) * payloadRatio
        return Double(stage.throughputBps) >= targetPayloadBps * throughputFloor
    }

    /// Returns the sweep limits and stability thresholds for a quality-test mode.
    nonisolated static func qualityTestProfile(
        for mode: MirageQualityTestMode
    ) -> QualityTestModeProfile {
        switch mode {
        case .automaticSelection:
            QualityTestModeProfile(
                transport: QualityTestProbeProfile(
                    probeKind: .transport,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 600_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1200,
                    growthFactor: 1.55,
                    maxStages: 11,
                    throughputFloor: nil,
                    lossCeiling: 5.0,
                    includesRefinementTargets: false
                ),
                streamingReplay: QualityTestProbeProfile(
                    probeKind: .streamingReplay,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 600_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1500,
                    growthFactor: 1.55,
                    maxStages: 11,
                    throughputFloor: 0.9,
                    lossCeiling: 2.0,
                    includesRefinementTargets: true
                )
            )
        case .connectionLimit:
            QualityTestModeProfile(
                transport: QualityTestProbeProfile(
                    probeKind: .transport,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 10_000_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1500,
                    growthFactor: 2.0,
                    maxStages: 16,
                    throughputFloor: nil,
                    lossCeiling: 1.0,
                    includesRefinementTargets: false
                ),
                streamingReplay: QualityTestProbeProfile(
                    probeKind: .streamingReplay,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 10_000_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1500,
                    growthFactor: 2.0,
                    maxStages: 16,
                    throughputFloor: 0.9,
                    lossCeiling: 1.0,
                    includesRefinementTargets: false
                )
            )
        }
    }

    /// Builds the ordered host probe stages and tracks which stages contribute to each summary phase.
    nonisolated static func qualityTestExecutionPlan(
        for mode: MirageQualityTestMode
    ) -> QualityTestExecutionPlan {
        let modeProfile = Self.qualityTestProfile(for: mode)
        var stages: [MirageDiagnostics.MirageQualityTestPlan.Stage] = []
        var nextStageID = 0

        func appendStages(
            for profile: QualityTestProbeProfile
        ) -> Set<Int> {
            var measurementStageIDs: Set<Int> = []
            let measurementTargets = Self.qualityTestMeasurementTargets(profile: profile)

            stages.append(
                MirageDiagnostics.MirageQualityTestPlan.Stage(
                    id: nextStageID,
                    probeKind: profile.probeKind,
                    targetBitrateBps: profile.minTargetBitrate,
                    durationMs: profile.warmupDurationMs
                )
            )
            nextStageID += 1

            for target in measurementTargets {
                let stageID = nextStageID
                stages.append(
                    MirageDiagnostics.MirageQualityTestPlan.Stage(
                        id: stageID,
                        probeKind: profile.probeKind,
                        targetBitrateBps: target,
                        durationMs: profile.stageDurationMs
                    )
                )
                measurementStageIDs.insert(stageID)
                nextStageID += 1
            }
            return measurementStageIDs
        }

        let transportMeasurementStageIDs: Set<Int>
        let streamingReplayMeasurementStageIDs: Set<Int>
        switch mode {
        case .automaticSelection:
            transportMeasurementStageIDs = []
            streamingReplayMeasurementStageIDs = appendStages(for: modeProfile.streamingReplay)
        case .connectionLimit:
            transportMeasurementStageIDs = appendStages(for: modeProfile.transport)
            streamingReplayMeasurementStageIDs = appendStages(for: modeProfile.streamingReplay)
        }
        return QualityTestExecutionPlan(
            plan: MirageDiagnostics.MirageQualityTestPlan(stages: stages),
            transportMeasurementStageIDs: transportMeasurementStageIDs,
            streamingReplayMeasurementStageIDs: streamingReplayMeasurementStageIDs,
            stopAfterFirstBreach: false
        )
    }

    /// Returns the throughput and loss constraints for one mode/probe-kind pair.
    nonisolated static func qualityTestStabilityConstraints(
        for mode: MirageQualityTestMode,
        probeKind: MirageDiagnostics.MirageQualityTestPlan.ProbeKind
    ) -> (throughputFloor: Double?, lossCeiling: Double) {
        let modeProfile = qualityTestProfile(for: mode)
        switch probeKind {
        case .transport:
            return (modeProfile.transport.throughputFloor, modeProfile.transport.lossCeiling)
        case .streamingReplay:
            return (
                modeProfile.streamingReplay.throughputFloor, modeProfile.streamingReplay.lossCeiling
            )
        }
    }

    /// Expands a probe profile into measured bitrate targets, including optional refinement points.
    nonisolated private static func qualityTestMeasurementTargets(
        profile: QualityTestProbeProfile
    ) -> [Int] {
        let baseTargets = qualityTestSweepTargets(
            minTargetBitrate: profile.minTargetBitrate,
            maxTargetBitrate: profile.maxTargetBitrate,
            growthFactor: profile.growthFactor,
            maxStages: profile.maxStages
        )
        guard profile.includesRefinementTargets, baseTargets.count > 1 else {
            return baseTargets
        }

        var targets: [Int] = []
        for (index, lower) in baseTargets.enumerated() {
            targets.append(lower)
            guard index < baseTargets.count - 1 else { continue }
            let upper = baseTargets[index + 1]
            let midpoint = Int(Double(lower) * sqrt(Double(upper) / Double(max(1, lower))))
            if midpoint > lower, midpoint < upper {
                targets.append(midpoint)
            }
        }
        return targets
    }

    /// Generates a bounded geometric bitrate sweep.
    nonisolated private static func qualityTestSweepTargets(
        minTargetBitrate: Int,
        maxTargetBitrate: Int,
        growthFactor: Double,
        maxStages: Int
    ) -> [Int] {
        guard minTargetBitrate > 0 else { return [] }
        guard maxStages > 0 else { return [] }
        guard growthFactor > 1 else { return [minTargetBitrate] }

        var targets: [Int] = []
        var targetBitrate = minTargetBitrate
        while targets.count < maxStages, targetBitrate <= maxTargetBitrate {
            targets.append(targetBitrate)
            let next = Int(Double(targetBitrate) * growthFactor)
            if next <= targetBitrate { break }
            if next > maxTargetBitrate {
                if targets.count < maxStages, targets.last != maxTargetBitrate {
                    targets.append(maxTargetBitrate)
                }
                break
            }
            targetBitrate = next
        }

        return targets
    }
}
