//
//  MirageBitrateQualityMapper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Maps target bitrate to derived encoder quality settings.
//

import Foundation
import MirageKit

enum MirageBitrateQualityMapper {
    private static let highBitrateBoostStartBps = 400_000_000
    private static let highBitrateBoostFullBps = 700_000_000
    private static let highBitrateProgressExponent: Float = 0.55
    private static let highBitrateBoostMaxScale: Float = 1.22
    private static let standardCeiling: Float = 0.80
    private static let highBitrateCeiling: Float = 0.94

    static let frameQualityCeiling: Float = highBitrateCeiling
    private static let minimumFrameQuality: Double = 0.06
    private static let defaultKeyframeQualityMultiplier: Double = 0.72
    private static let minimumKeyframeQualityMultiplier: Double = 0.58
    private static let maximumKeyframeQualityMultiplier: Double = 0.92
    private static let unconstrainedBPPThreshold: Double = 0.16
    private static let constrainedBPPThreshold: Double = 0.03
    private static let highRefreshBaseScale120: Double = 0.85
    private static let highRefreshBaseScale90: Double = 0.90
    private static let highRefreshRelaxedScale120: Double = 0.95
    private static let highRefreshRelaxedScale90: Double = 0.97

    private struct Point {
        let bpp: Double
        let quality: Double
    }

    private static let points: [Point] = [
        Point(bpp: 0.015, quality: 0.08),
        Point(bpp: 0.03, quality: 0.14),
        Point(bpp: 0.05, quality: 0.23),
        Point(bpp: 0.08, quality: 0.36),
        Point(bpp: 0.12, quality: 0.50),
        Point(bpp: 0.18, quality: 0.66),
        Point(bpp: 0.25, quality: 0.80),
    ]

    static func normalizedTargetBitrate(bitrate: Int?) -> Int? {
        guard let bitrate, bitrate > 0 else { return nil }
        return bitrate
    }

    static func derivedQualities(
        targetBitrateBps: Int,
        width: Int,
        height: Int,
        frameRate: Int
    ) -> (frameQuality: Float, keyframeQuality: Float) {
        let defaultFrameQuality = standardCeiling
        let defaultKeyframeQuality = max(
            Float(minimumFrameQuality),
            min(defaultFrameQuality, defaultFrameQuality * Float(defaultKeyframeQualityMultiplier))
        )
        guard targetBitrateBps > 0, width > 0, height > 0, frameRate > 0 else {
            return (frameQuality: defaultFrameQuality, keyframeQuality: defaultKeyframeQuality)
        }

        guard let bpp = bitsPerPixelPerFrame(
            targetBitrateBps: targetBitrateBps,
            width: width,
            height: height,
            frameRate: frameRate
        ) else {
            return (frameQuality: defaultFrameQuality, keyframeQuality: defaultKeyframeQuality)
        }

        let pressure = compressionPressure(for: bpp)
        let boostScale = Double(highBitrateBoostScale(targetBitrateBps: targetBitrateBps))
        let mappedQuality = interpolateQuality(for: bpp) *
            frameRateCompressionScale(for: frameRate, compressionPressure: pressure) *
            boostScale
        let dynamicCeiling = Double(qualityCeiling(targetBitrateBps: targetBitrateBps))
        let frameQuality = Float(max(minimumFrameQuality, min(dynamicCeiling, mappedQuality)))
        let keyframeMultiplier = keyframeQualityMultiplier(
            compressionPressure: pressure,
            targetBitrateBps: targetBitrateBps
        )
        let keyframeQuality = Float(
            max(
                minimumFrameQuality,
                min(Double(frameQuality), Double(frameQuality) * keyframeMultiplier)
            )
        )
        return (frameQuality, keyframeQuality)
    }

    static func bitsPerPixelPerFrame(
        targetBitrateBps: Int,
        width: Int,
        height: Int,
        frameRate: Int
    ) -> Double? {
        guard targetBitrateBps > 0, width > 0, height > 0, frameRate > 0 else { return nil }
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        guard pixelsPerSecond > 0 else { return nil }
        return Double(targetBitrateBps) / pixelsPerSecond
    }

    static func frameRateScale(frameRate: Int, bpp: Double? = nil) -> Double {
        let pressure = bpp.map { compressionPressure(for: $0) } ?? 1.0
        return frameRateCompressionScale(for: frameRate, compressionPressure: pressure)
    }

    static func compressionPressure(for bpp: Double) -> Double {
        guard bpp > constrainedBPPThreshold else { return 1.0 }
        guard bpp < unconstrainedBPPThreshold else { return 0.0 }
        let range = max(0.0001, unconstrainedBPPThreshold - constrainedBPPThreshold)
        let raw = (unconstrainedBPPThreshold - bpp) / range
        let clamped = max(0.0, min(1.0, raw))
        return pow(clamped, 0.85)
    }

    private static func highBitrateProgressRaw(targetBitrateBps: Int) -> Float {
        guard targetBitrateBps > highBitrateBoostStartBps else { return 0 }
        let range = max(1, highBitrateBoostFullBps - highBitrateBoostStartBps)
        let progress = Float(targetBitrateBps - highBitrateBoostStartBps) / Float(range)
        return max(0, min(1, progress))
    }

    private static func highBitrateProgress(targetBitrateBps: Int) -> Float {
        let rawProgress = highBitrateProgressRaw(targetBitrateBps: targetBitrateBps)
        return Float(pow(Double(rawProgress), Double(highBitrateProgressExponent)))
    }

    private static func highBitrateBoostScale(targetBitrateBps: Int) -> Float {
        let progress = highBitrateProgress(targetBitrateBps: targetBitrateBps)
        return 1 + progress * (highBitrateBoostMaxScale - 1)
    }

    private static func qualityCeiling(targetBitrateBps: Int) -> Float {
        let progress = highBitrateProgress(targetBitrateBps: targetBitrateBps)
        return standardCeiling + progress * (highBitrateCeiling - standardCeiling)
    }

    private static func keyframeQualityMultiplier(
        compressionPressure: Double,
        targetBitrateBps: Int
    ) -> Double {
        let clampedPressure = max(0.0, min(1.0, compressionPressure))
        let highBitrateHeadroom = Double(highBitrateProgress(targetBitrateBps: targetBitrateBps))
        let unconstrainedMultiplier = min(
            maximumKeyframeQualityMultiplier,
            0.86 + highBitrateHeadroom * 0.06
        )
        let multiplier = unconstrainedMultiplier -
            clampedPressure * (unconstrainedMultiplier - minimumKeyframeQualityMultiplier)
        return max(minimumKeyframeQualityMultiplier, min(maximumKeyframeQualityMultiplier, multiplier))
    }

    private static func interpolateQuality(for bpp: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0.8 }
        if bpp <= first.bpp { return first.quality }
        if bpp >= last.bpp { return last.quality }

        for index in 0 ..< points.count - 1 {
            let low = points[index]
            let high = points[index + 1]
            if bpp >= low.bpp, bpp <= high.bpp {
                let t = (bpp - low.bpp) / (high.bpp - low.bpp)
                return low.quality + (high.quality - low.quality) * t
            }
        }

        return last.quality
    }

    private static func frameRateCompressionScale(
        for frameRate: Int,
        compressionPressure: Double
    ) -> Double {
        let clampedPressure = max(0.0, min(1.0, compressionPressure))
        if frameRate >= 120 {
            return highRefreshBaseScale120 +
                (highRefreshRelaxedScale120 - highRefreshBaseScale120) *
                (1.0 - clampedPressure)
        }
        if frameRate >= 90 {
            return highRefreshBaseScale90 +
                (highRefreshRelaxedScale90 - highRefreshBaseScale90) *
                (1.0 - clampedPressure)
        }
        return 1.0
    }
}
