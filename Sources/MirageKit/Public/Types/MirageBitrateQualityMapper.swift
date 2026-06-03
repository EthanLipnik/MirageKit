//
//  MirageBitrateQualityMapper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Maps target bitrate to derived encoder quality settings.
//

import Foundation

/// Converts requested stream bitrate into encoder quality targets and related bitrate diagnostics.
public enum MirageBitrateQualityMapper {
    private static let highBitrateBoostStartBps = 400_000_000
    private static let highBitrateBoostFullBps = 700_000_000
    private static let highBitrateProgressExponent: Float = 0.55
    private static let highBitrateBoostMaxScale: Float = 1.22
    private static let standardCeiling: Float = 0.80
    private static let highBitrateCeiling: Float = 0.94

    private static let minimumFrameQuality: Double = 0.06
    private static let defaultKeyframeQualityMultiplier: Double = 0.72
    private static let minimumKeyframeQualityMultiplier: Double = 0.58
    private static let maximumKeyframeQualityMultiplier: Double = 0.92
    private static let unconstrainedBPPThreshold: Double = 0.16
    private static let constrainedBPPThreshold: Double = 0.03
    private static let maximumQualityReferenceFrameRate = 60

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

    /// Returns a usable target bitrate, discarding missing or non-positive values.
    public static func normalizedTargetBitrate(bitrate: Int?) -> Int? {
        guard let bitrate, bitrate > 0 else { return nil }
        return bitrate
    }

    /// Derives frame and keyframe quality values for the requested bitrate and stream geometry.
    ///
    /// The mapping uses bits-per-pixel-per-frame as the baseline signal and relaxes the ceiling at
    /// very high bitrates. High refresh rates above 60 Hz are treated as presentation opportunities,
    /// not as a per-frame quality budget.
    public static func derivedQualities(
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
            frameRate: qualityReferenceFrameRate(for: frameRate)
        ) else {
            return (frameQuality: defaultFrameQuality, keyframeQuality: defaultKeyframeQuality)
        }

        let pressure = compressionPressure(for: bpp)
        let boostScale = Double(highBitrateBoostScale(targetBitrateBps: targetBitrateBps))
        let mappedQuality = interpolateQuality(for: bpp) * boostScale
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

    /// Finds the lowest bitrate that can produce at least the requested frame quality.
    ///
    /// Returns `nil` when the stream geometry is invalid or the requested quality is not reachable
    /// under `maxBitrateBps`.
    public static func targetBitrateBps(
        forFrameQuality desiredFrameQuality: Float,
        width: Int,
        height: Int,
        frameRate: Int,
        maxBitrateBps: Int = 1_000_000_000
    ) -> Int? {
        guard width > 0, height > 0, frameRate > 0, maxBitrateBps > 0 else { return nil }

        let clampedTargetQuality = max(
            Float(minimumFrameQuality),
            min(highBitrateCeiling, desiredFrameQuality)
        )
        let maximumDerivedQuality = derivedQualities(
            targetBitrateBps: maxBitrateBps,
            width: width,
            height: height,
            frameRate: frameRate
        ).frameQuality
        guard maximumDerivedQuality >= clampedTargetQuality else { return nil }

        var low = 1
        var high = maxBitrateBps
        var best: Int?
        while low <= high {
            let mid = low + (high - low) / 2
            let derivedFrameQuality = derivedQualities(
                targetBitrateBps: mid,
                width: width,
                height: height,
                frameRate: frameRate
            ).frameQuality

            if derivedFrameQuality >= clampedTargetQuality {
                best = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        return best
    }

    /// Calculates the bits-per-pixel-per-frame budget for a target bitrate and stream geometry.
    public static func bitsPerPixelPerFrame(
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

    /// Returns the frame cadence used for bitrate-to-quality mapping.
    package static func qualityReferenceFrameRate(for frameRate: Int) -> Int {
        min(max(1, frameRate), maximumQualityReferenceFrameRate)
    }

    /// Returns the quality scale applied for the supplied display cadence.
    public static func frameRateScale(frameRate: Int, bpp: Double? = nil) -> Double {
        1.0
    }

    /// Returns normalized compression pressure, where `1` is constrained and `0` is unconstrained.
    public static func compressionPressure(for bpp: Double) -> Double {
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
                let interpolationProgress = (bpp - low.bpp) / (high.bpp - low.bpp)
                return low.quality + (high.quality - low.quality) * interpolationProgress
            }
        }

        return last.quality
    }

}
