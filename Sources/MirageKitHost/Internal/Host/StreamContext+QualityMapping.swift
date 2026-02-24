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
    private static let lowLatencyHighResolutionBoostMinDrop: Float = 0.22
    private static let lowLatencyHighResolutionBoostMaxDrop: Float = 0.56
    private static let mapperMinimumQuality: Float = 0.05
    private static let gameModeQualityCap4K60: Float = 0.66
    private static let gameModeQualityCap5MP60: Float = 0.72
    private static let gameModeQualityCap3MP60: Float = 0.78
    private static let gameModeQualityCapBase60: Float = 0.84
    private static let gameModeHighRefreshCapPenalty: Float = 0.08

    private func applyLowLatencyHighResolutionCompressionBoost(
        frameQuality: Float,
        keyframeQuality: Float,
        width: Int,
        height: Int
    ) -> LowLatencyHighResolutionQualityBoost {
        guard lowLatencyHighResolutionCompressionBoostEnabled,
              latencyMode == .lowestLatency,
              performanceMode != .game else {
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

        let boostedFrameQuality = max(Self.mapperMinimumQuality, frameQuality - qualityDrop)
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
            drop: qualityDrop
        )
    }

    private func gameModeThroughputQualityCap(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> Float? {
        guard performanceMode == .game else { return nil }

        let pixelCount = Double(width * height)
        let baseCap: Float
        if pixelCount >= 8_000_000 {
            baseCap = Self.gameModeQualityCap4K60
        } else if pixelCount >= 5_000_000 {
            baseCap = Self.gameModeQualityCap5MP60
        } else if pixelCount >= 3_000_000 {
            baseCap = Self.gameModeQualityCap3MP60
        } else {
            baseCap = Self.gameModeQualityCapBase60
        }

        let refreshAdjustedCap: Float
        if frameRate >= 120 {
            refreshAdjustedCap = baseCap - Self.gameModeHighRefreshCapPenalty
        } else if frameRate >= 90 {
            refreshAdjustedCap = baseCap - (Self.gameModeHighRefreshCapPenalty * 0.5)
        } else {
            refreshAdjustedCap = baseCap
        }

        return max(Self.mapperMinimumQuality, min(compressionQualityCeiling, refreshAdjustedCap))
    }

    func applyDerivedQuality(for outputSize: CGSize, logLabel: String?) async {
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
            height: height
        )
        let throughputCap = gameModeThroughputQualityCap(
            width: width,
            height: height,
            frameRate: currentFrameRate
        )
        let throughputCappedFrameQuality = if let throughputCap {
            min(qualityBoost.frameQuality, throughputCap)
        } else {
            qualityBoost.frameQuality
        }
        let cappedFrameQuality = min(throughputCappedFrameQuality, compressionQualityCeiling)
        let cappedKeyframeQuality = min(qualityBoost.keyframeQuality, cappedFrameQuality)

        guard encoderConfig.frameQuality != cappedFrameQuality ||
            encoderConfig.keyframeQuality != cappedKeyframeQuality else {
            return
        }

        encoderConfig.frameQuality = cappedFrameQuality
        encoderConfig.keyframeQuality = cappedKeyframeQuality
        steadyQualityCeiling = cappedFrameQuality
        qualityCeiling = resolvedQualityCeiling()
        qualityFloor = resolvedRuntimeQualityFloor(for: cappedFrameQuality)
        activeQuality = max(qualityFloor, min(cappedFrameQuality, qualityCeiling))
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: cappedKeyframeQuality)

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
                .frameRateScale(frameRate: currentFrameRate)
                .formatted(.number.precision(.fractionLength(2)))
            let boostText: String
            if qualityBoost.applied {
                let dropText = qualityBoost.drop.formatted(.number.precision(.fractionLength(2)))
                boostText = ", llHighResBoostDrop \(dropText)"
            } else {
                boostText = ""
            }
            let throughputCapText: String
            if let throughputCap {
                let capText = throughputCap.formatted(.number.precision(.fractionLength(2)))
                throughputCapText = ", gameModeCap \(capText)"
            } else {
                throughputCapText = ""
            }
            MirageLogger
                .stream(
                    "\(logLabel): target \(mbps.formatted(.number.precision(.fractionLength(0)))) Mbps, quality \(qualityText) (cap \(capText)), bpp \(bppText), fpsScale \(scaleText)\(boostText)\(throughputCapText)"
                )
        }
    }
}
#endif
