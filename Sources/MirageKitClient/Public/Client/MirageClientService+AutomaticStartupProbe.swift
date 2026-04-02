//
//  MirageClientService+AutomaticStartupProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Short startup-only bitrate probe for automatic stream startup.
//

import CoreGraphics
import Foundation
import MirageKit

public struct MirageAutomaticStartupProbeConfiguration: Sendable, Equatable {
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let targetFrameRate: Int
    public let desiredBitrateBps: Int
    public let plan: MirageQualityTestPlan

    public init(
        encodedWidth: Int,
        encodedHeight: Int,
        targetFrameRate: Int,
        desiredBitrateBps: Int,
        plan: MirageQualityTestPlan
    ) {
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.targetFrameRate = targetFrameRate
        self.desiredBitrateBps = desiredBitrateBps
        self.plan = plan
    }
}

public struct MirageAutomaticStartupProbeResult: Sendable, Equatable {
    public let startupBitrateBps: Int
    public let desiredBitrateBps: Int
    public let targetFrameRate: Int
    public let peakMeasuredBitrateBps: Int
    public let selectedStageResult: MirageQualityTestSummary.StageResult?
    public let stageResults: [MirageQualityTestSummary.StageResult]

    public init(
        startupBitrateBps: Int,
        desiredBitrateBps: Int,
        targetFrameRate: Int,
        peakMeasuredBitrateBps: Int,
        selectedStageResult: MirageQualityTestSummary.StageResult?,
        stageResults: [MirageQualityTestSummary.StageResult]
    ) {
        self.startupBitrateBps = startupBitrateBps
        self.desiredBitrateBps = desiredBitrateBps
        self.targetFrameRate = targetFrameRate
        self.peakMeasuredBitrateBps = peakMeasuredBitrateBps
        self.selectedStageResult = selectedStageResult
        self.stageResults = stageResults
    }
}

@MainActor
public extension MirageClientService {
    nonisolated private static let automaticStartupProbeTargetFrameQuality: Float = 0.75
    nonisolated private static let automaticStartupProbeTargets: [(multiplier: Double, durationMs: Int)] = [
        (0.50, 500),
        (0.70, 900),
        (0.85, 1_100),
        (1.00, 1_300),
    ]
    nonisolated private static let automaticStartupProbeThroughputFloor = 0.90
    nonisolated private static let automaticStartupProbeLossCeiling = 1.0

    func automaticStartupProbeConfiguration(
        logicalResolution: CGSize,
        explicitScaleFactor: CGFloat? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        targetFrameRate: Int
    ) -> MirageAutomaticStartupProbeConfiguration? {
        let geometry = resolvedStreamGeometry(
            for: logicalResolution,
            explicitScaleFactor: explicitScaleFactor,
            requestedStreamScale: clampedStreamScale(),
            encoderMaxWidth: encoderOverrides?.encoderMaxWidth,
            encoderMaxHeight: encoderOverrides?.encoderMaxHeight,
            disableResolutionCap: encoderOverrides?.disableResolutionCap ?? false
        )
        return Self.automaticStartupProbeConfiguration(
            encodedWidth: Int(geometry.encodedPixelSize.width.rounded()),
            encodedHeight: Int(geometry.encodedPixelSize.height.rounded()),
            targetFrameRate: targetFrameRate
        )
    }

    nonisolated static func automaticStartupProbeConfiguration(
        encodedWidth: Int,
        encodedHeight: Int,
        targetFrameRate: Int
    ) -> MirageAutomaticStartupProbeConfiguration? {
        guard encodedWidth > 0, encodedHeight > 0, targetFrameRate > 0 else { return nil }
        guard let desiredBitrateBps = MirageBitrateQualityMapper.targetBitrateBps(
            forFrameQuality: Self.automaticStartupProbeTargetFrameQuality,
            width: encodedWidth,
            height: encodedHeight,
            frameRate: targetFrameRate
        ) else {
            return nil
        }

        return MirageAutomaticStartupProbeConfiguration(
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            targetFrameRate: targetFrameRate,
            desiredBitrateBps: desiredBitrateBps,
            plan: automaticStartupProbePlan(desiredBitrateBps: desiredBitrateBps)
        )
    }

    func runAutomaticStartupProbe(
        configuration: MirageAutomaticStartupProbeConfiguration,
        onStageUpdate: (@MainActor (MirageQualityTestProgressUpdate) -> Void)? = nil
    ) async throws -> MirageAutomaticStartupProbeResult {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize()
        let payloadBytes = miragePayloadSize(maxPacketSize: mediaMaxPacketSize)
        let desiredText = (Double(configuration.desiredBitrateBps) / 1_000_000.0)
            .formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client(
            "Automatic startup probe starting: target \(desiredText) Mbps, encoded \(configuration.encodedWidth)x\(configuration.encodedHeight)@\(configuration.targetFrameRate)"
        )

        let stageResults = try await runQualityTestSession(
            testID: testID,
            plan: configuration.plan,
            payloadBytes: payloadBytes,
            mediaMaxPacketSize: mediaMaxPacketSize,
            mode: .automaticSelection,
            stopAfterFirstBreach: false,
            onStageUpdate: onStageUpdate
        )
        let resolved = Self.resolvedAutomaticStartupProbeBitrate(
            stageResults: stageResults,
            payloadBytes: payloadBytes
        )
        guard resolved.startupBitrateBps > 0 else {
            throw MirageError.protocolError("Automatic startup probe failed: no usable throughput measurement was recorded.")
        }

        let startupText = (Double(resolved.startupBitrateBps) / 1_000_000.0)
            .formatted(.number.precision(.fractionLength(1)))
        let peakText = (Double(resolved.peakMeasuredBitrateBps) / 1_000_000.0)
            .formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client(
            "Automatic startup probe resolved start \(startupText) Mbps, ceiling \(desiredText) Mbps, peak \(peakText) Mbps"
        )

        return MirageAutomaticStartupProbeResult(
            startupBitrateBps: resolved.startupBitrateBps,
            desiredBitrateBps: configuration.desiredBitrateBps,
            targetFrameRate: configuration.targetFrameRate,
            peakMeasuredBitrateBps: resolved.peakMeasuredBitrateBps,
            selectedStageResult: resolved.selectedStageResult,
            stageResults: stageResults
        )
    }

    nonisolated static func automaticStartupProbePlan(
        desiredBitrateBps: Int
    ) -> MirageQualityTestPlan {
        var stages: [MirageQualityTestPlan.Stage] = []
        for (index, target) in Self.automaticStartupProbeTargets.enumerated() {
            let stageTarget = max(1, Int((Double(desiredBitrateBps) * target.multiplier).rounded()))
            stages.append(
                MirageQualityTestPlan.Stage(
                    id: index,
                    probeKind: .streamingReplay,
                    targetBitrateBps: stageTarget,
                    durationMs: target.durationMs
                )
            )
        }
        return MirageQualityTestPlan(stages: stages)
    }

    nonisolated static func resolvedAutomaticStartupProbeBitrate(
        stageResults: [MirageQualityTestSummary.StageResult],
        payloadBytes: Int
    ) -> (
        startupBitrateBps: Int,
        selectedStageResult: MirageQualityTestSummary.StageResult?,
        peakMeasuredBitrateBps: Int
    ) {
        let orderedStages = stageResults.sorted { $0.stageID < $1.stageID }
        var highestStableStage: MirageQualityTestSummary.StageResult?
        var highestMeasuredStage: MirageQualityTestSummary.StageResult?

        for stage in orderedStages {
            if highestMeasuredStage == nil || stage.throughputBps > (highestMeasuredStage?.throughputBps ?? 0) {
                highestMeasuredStage = stage
            }

            let isStable = qualityTestStageIsStable(
                stage,
                targetBitrate: stage.targetBitrateBps,
                payloadBytes: payloadBytes,
                throughputFloor: Self.automaticStartupProbeThroughputFloor,
                lossCeiling: Self.automaticStartupProbeLossCeiling
            )
            if isStable,
               highestStableStage == nil || stage.throughputBps >= (highestStableStage?.throughputBps ?? 0) {
                highestStableStage = stage
            }
        }

        let selectedStage = highestStableStage ?? highestMeasuredStage
        return (
            startupBitrateBps: selectedStage?.throughputBps ?? 0,
            selectedStageResult: selectedStage,
            peakMeasuredBitrateBps: highestMeasuredStage?.throughputBps ?? 0
        )
    }
}
