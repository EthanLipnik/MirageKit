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
    private static let highBitrateBoostMaxScale: Float = 1.22
    private static let standardCeiling: Float = 0.80
    private static let highBitrateCeiling: Float = 0.94

    static let frameQualityCeiling: Float = highBitrateCeiling
    private static let minimumFrameQuality: Double = 0.06
    private static let keyframeQualityMultiplier: Double = 0.72

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
            min(defaultFrameQuality, defaultFrameQuality * Float(keyframeQualityMultiplier))
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

        let boostScale = Double(highBitrateBoostScale(targetBitrateBps: targetBitrateBps))
        let mappedQuality = interpolateQuality(for: bpp) * frameRateCompressionScale(for: frameRate) * boostScale
        let dynamicCeiling = Double(qualityCeiling(targetBitrateBps: targetBitrateBps))
        let frameQuality = Float(max(minimumFrameQuality, min(dynamicCeiling, mappedQuality)))
        let keyframeQuality = Float(
            max(
                minimumFrameQuality,
                min(Double(frameQuality), Double(frameQuality) * keyframeQualityMultiplier)
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

    static func frameRateScale(frameRate: Int) -> Double {
        frameRateCompressionScale(for: frameRate)
    }

    private static func highBitrateProgress(targetBitrateBps: Int) -> Float {
        guard targetBitrateBps > highBitrateBoostStartBps else { return 0 }
        let range = max(1, highBitrateBoostFullBps - highBitrateBoostStartBps)
        let progress = Float(targetBitrateBps - highBitrateBoostStartBps) / Float(range)
        return max(0, min(1, progress))
    }

    private static func highBitrateBoostScale(targetBitrateBps: Int) -> Float {
        let progress = highBitrateProgress(targetBitrateBps: targetBitrateBps)
        return 1 + progress * (highBitrateBoostMaxScale - 1)
    }

    private static func qualityCeiling(targetBitrateBps: Int) -> Float {
        let progress = highBitrateProgress(targetBitrateBps: targetBitrateBps)
        return standardCeiling + progress * (highBitrateCeiling - standardCeiling)
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

    private static func frameRateCompressionScale(for frameRate: Int) -> Double {
        if frameRate >= 120 { return 0.85 }
        if frameRate >= 90 { return 0.90 }
        return 1.0
    }
}
