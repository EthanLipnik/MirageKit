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
    static let frameQualityCeiling: Float = 0.80

    private struct Point {
        let bpp: Double
        let quality: Double
    }

    private static let points: [Point] = [
        Point(bpp: 0.02, quality: 0.15),
        Point(bpp: 0.05, quality: 0.35),
        Point(bpp: 0.08, quality: 0.60),
        Point(bpp: 0.12, quality: 0.80),
        Point(bpp: 0.18, quality: 0.92),
        Point(bpp: 0.25, quality: 1.0),
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
        let defaultFrameQuality = min(Float(0.80), frameQualityCeiling)
        let defaultKeyframeQuality = max(0.1, min(defaultFrameQuality, defaultFrameQuality * 0.85))
        guard targetBitrateBps > 0, width > 0, height > 0, frameRate > 0 else {
            return (frameQuality: defaultFrameQuality, keyframeQuality: defaultKeyframeQuality)
        }

        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        guard pixelsPerSecond > 0 else {
            return (frameQuality: defaultFrameQuality, keyframeQuality: defaultKeyframeQuality)
        }

        let bpp = Double(targetBitrateBps) / pixelsPerSecond
        let mappedQuality = interpolateQuality(for: bpp)
        let frameQuality = Float(max(0.1, min(Double(frameQualityCeiling), mappedQuality)))
        let keyframeQuality = Float(max(0.1, min(frameQuality, frameQuality * 0.85)))
        return (frameQuality, keyframeQuality)
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
}
