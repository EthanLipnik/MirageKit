//
//  StreamContext+QualityMapping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Bitrate-driven quality mapping helpers.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    private struct LowLatencyHighResolutionQualityBoost {
        let frameQuality: Float
        let keyframeQuality: Float
        let applied: Bool
        let drop: Float
    }

    private static let lowLatencyHighResolutionBoostStartPixels: Double = 4_096_000 // ~2560x1600
    private static let lowLatencyHighResolutionBoostFullPixels: Double = 10_500_000 // ~5K and above
    private static let lowLatencyHighResolutionBoostMinDrop: Float = 0.06
    private static let lowLatencyHighResolutionBoostMaxDrop: Float = 0.18
    private static let mapperMinimumQuality: Float = 0.05

    private func applyHostAdaptiveBudgetIfNeeded(
        for outputSize: CGSize,
        logLabel: String?
    ) async {
        guard !hostAdaptiveBudgetApplied else { return }

        guard let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            HostAdaptiveStreamBudgetPolicy.Request(
                requestedBitrateBps: requestedTargetBitrate ?? encoderConfig.bitrate,
                requestedCeilingBps: bitrateAdaptationCeiling,
                enteredBitrateBps: explicitEnteredTargetBitrate,
                runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
                codec: encoderConfig.codec,
                outputSize: outputSize,
                frameRate: currentFrameRate,
                transportPathKind: transportPathKind,
                mediaPathProfile: mediaPathProfile
            )
        ) else {
            return
        }
        hostAdaptiveBudgetApplied = true

        let previousBitrate = encoderConfig.bitrate
        let previousCeiling = bitrateAdaptationCeiling
        encoderConfig.bitrate = decision.startupBitrateBps
        currentTargetBitrateBps = decision.startupBitrateBps
        startupBitrate = decision.startupBitrateBps
        bitrateAdaptationCeiling = decision.maximumCeilingBps
        realtimeRuntimeBitrateCeilingBps = decision.startupBitrateBps
        realtimeMinimumBitrateFloorBps = decision.minimumBitrateFloorBps
        await packetSender?.setTargetBitrateBps(decision.startupBitrateBps)
        if encoder != nil, previousBitrate != decision.startupBitrateBps {
            await encoder?.updateBitrate(decision.startupBitrateBps)
            scheduleRateControlRetuneValidation(
                previousBitrate: previousBitrate,
                targetBitrate: decision.startupBitrateBps
            )
        }

        let prefix = logLabel.map { "\($0): " } ?? ""
        let previousBitrateText = previousBitrate.map(mirageFormattedMegabitRate) ?? "auto"
        let previousCeilingText = previousCeiling.map(mirageFormattedMegabitRate) ?? "none"
        MirageLogger.stream(
            "\(prefix)host adaptive budget \(decision.reason): " +
                "startup \(mirageFormattedMegabitRate(decision.startupBitrateBps)) " +
                "ceiling \(mirageFormattedMegabitRate(decision.maximumCeilingBps)) " +
                "floor \(mirageFormattedMegabitRate(decision.minimumBitrateFloorBps)) " +
                "(client target \(previousBitrateText), ceiling \(previousCeilingText))"
        )
    }

    /// Returns the runtime quality floor for the active bitrate policy.
    func resolvedRuntimeQualityFloor(for qualityCeiling: Float) -> Float {
        let ceiling = max(0.0, min(compressionQualityCeiling, qualityCeiling))
        guard ceiling > 0 else { return 0 }
        let hasBitrateCap = (encoderConfig.bitrate ?? 0) > 0
        let floorFactor: Float = if let pressureRatio = runtimeBitratePressureRatio() {
            max(0.18, min(bitrateCappedQualityFloorFactor, pressureRatio * 1.10))
        } else {
            hasBitrateCap ? bitrateCappedQualityFloorFactor : qualityFloorFactor
        }
        let minimumFloor = hasBitrateCap ? bitrateCappedQualityFloorMinimum : uncappedQualityFloorMinimum
        return min(ceiling, max(minimumFloor, ceiling * floorFactor))
    }

    /// Returns the runtime keyframe quality floor for the active bitrate policy.
    func resolvedRuntimeKeyframeQualityFloor(for qualityCeiling: Float) -> Float {
        let ceiling = max(0.0, min(compressionQualityCeiling, qualityCeiling))
        guard ceiling > 0 else { return 0 }
        let hasBitrateCap = (encoderConfig.bitrate ?? 0) > 0
        let floorFactor: Float = if let pressureRatio = runtimeBitratePressureRatio() {
            max(0.18, min(bitrateCappedKeyframeFloorFactor, pressureRatio * 1.10))
        } else {
            hasBitrateCap ? bitrateCappedKeyframeFloorFactor : keyframeFloorFactor
        }
        let minimumFloor = hasBitrateCap ? bitrateCappedKeyframeFloorMinimum : uncappedQualityFloorMinimum
        return min(ceiling, max(minimumFloor, ceiling * floorFactor))
    }

    private func runtimeBitratePressureRatio() -> Float? {
        let currentBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? 0
        let baselineBitrate = enteredTargetBitrate ??
            requestedTargetBitrate ??
            startupBitrate ??
            encoderConfig.bitrate ??
            0
        guard currentBitrate > 0, baselineBitrate > 0 else { return nil }
        let ratio = Float(currentBitrate) / Float(baselineBitrate)
        guard ratio < 0.95 else { return nil }
        return max(0.01, min(1.0, ratio))
    }

    private func applyLowLatencyHighResolutionCompressionBoost(
        frameQuality: Float,
        keyframeQuality: Float,
        width: Int,
        height: Int,
        targetBitrateBps: Int,
        frameRate: Int
    ) -> LowLatencyHighResolutionQualityBoost {
        guard lowLatencyHighResolutionCompressionBoostEnabled,
              latencyMode == .lowestLatency || latencyMode == .balanced else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let pixelCount = Double(width * height)
        guard pixelCount > Self.lowLatencyHighResolutionBoostStartPixels else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let range = max(
            1.0,
            Self.lowLatencyHighResolutionBoostFullPixels - Self.lowLatencyHighResolutionBoostStartPixels
        )
        let progress = max(0.0, min(1.0, (pixelCount - Self.lowLatencyHighResolutionBoostStartPixels) / range))
        let easedProgress = pow(progress, 0.70)
        let qualityDrop = Self.lowLatencyHighResolutionBoostMinDrop +
            Float(easedProgress) *
            (Self.lowLatencyHighResolutionBoostMaxDrop - Self.lowLatencyHighResolutionBoostMinDrop)
        let bitratePressureScale: Float = if let bpp = MirageBitrateQualityMapper.bitsPerPixelPerFrame(
            targetBitrateBps: targetBitrateBps,
            width: width,
            height: height,
            frameRate: frameRate
        ) {
            Float(MirageBitrateQualityMapper.compressionPressure(for: bpp))
        } else {
            1.0
        }
        let effectiveQualityDrop = qualityDrop * bitratePressureScale
        guard effectiveQualityDrop > 0.0001 else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let boostedFrameQuality = max(Self.mapperMinimumQuality, frameQuality - effectiveQualityDrop)
        let keyframeRatio: Float
        if frameQuality > 0 {
            keyframeRatio = max(0.1, min(1.0, keyframeQuality / frameQuality))
        } else {
            keyframeRatio = 0.72
        }
        let boostedKeyframeQuality = max(
            Self.mapperMinimumQuality,
            min(boostedFrameQuality, boostedFrameQuality * keyframeRatio)
        )

        return LowLatencyHighResolutionQualityBoost(
            frameQuality: boostedFrameQuality,
            keyframeQuality: boostedKeyframeQuality,
            applied: true,
            drop: effectiveQualityDrop
        )
    }

    func applyDerivedQuality(for outputSize: CGSize, logLabel: String?) async {
        // ProRes manages its own quality — no bitrate-driven quality mapping
        guard encoderConfig.codec != .proRes4444 else { return }

        await applyHostAdaptiveBudgetIfNeeded(for: outputSize, logLabel: logLabel)

        guard let targetBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: encoderConfig.bitrate
        ) else {
            return
        }

        let width = max(2, Int(outputSize.width))
        let height = max(2, Int(outputSize.height))
        let derived = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: targetBitrate,
            width: width,
            height: height,
            frameRate: currentFrameRate
        )
        let qualityBoost = applyLowLatencyHighResolutionCompressionBoost(
            frameQuality: derived.frameQuality,
            keyframeQuality: derived.keyframeQuality,
            width: width,
            height: height,
            targetBitrateBps: targetBitrate,
            frameRate: currentFrameRate
        )
        let cappedFrameQuality = min(qualityBoost.frameQuality, compressionQualityCeiling)
        let cappedKeyframeQuality = min(qualityBoost.keyframeQuality, cappedFrameQuality)

        guard encoderConfig.frameQuality != cappedFrameQuality ||
            encoderConfig.keyframeQuality != cappedKeyframeQuality else {
            return
        }

        encoderConfig.frameQuality = cappedFrameQuality
        encoderConfig.keyframeQuality = cappedKeyframeQuality
        steadyQualityCeiling = cappedFrameQuality
        qualityCeiling = resolvedQualityCeiling
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        activeQuality = max(qualityFloor, min(cappedFrameQuality, qualityCeiling))
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: min(cappedKeyframeQuality, qualityCeiling))

        await encoder?.updateQuality(activeQuality)

        if let logLabel {
            let mbps = Double(targetBitrate) / 1_000_000.0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let capText = compressionQualityCeiling.formatted(.number.precision(.fractionLength(2)))
            let bpp = MirageBitrateQualityMapper.bitsPerPixelPerFrame(
                targetBitrateBps: targetBitrate,
                width: width,
                height: height,
                frameRate: currentFrameRate
            )
            let bppText: String = if let bpp {
                bpp.formatted(.number.precision(.fractionLength(4)))
            } else {
                "n/a"
            }
            let scaleText = MirageBitrateQualityMapper
                .frameRateScale(frameRate: currentFrameRate, bpp: bpp)
                .formatted(.number.precision(.fractionLength(2)))
            let boostText: String
            if qualityBoost.applied {
                let dropText = qualityBoost.drop.formatted(.number.precision(.fractionLength(2)))
                boostText = ", llHighResBoostDrop \(dropText)"
            } else {
                boostText = ""
            }
            MirageLogger
                .stream(
                    "\(logLabel): target \(mbps.formatted(.number.precision(.fractionLength(0)))) Mbps, quality \(qualityText) (cap \(capText)), bpp \(bppText), fpsScale \(scaleText)\(boostText)"
                )
        }
    }

    private func mirageFormattedMegabitRate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000.0
        return "\(mbps.formatted(.number.precision(.fractionLength(1))))Mbps"
    }
}
#endif
