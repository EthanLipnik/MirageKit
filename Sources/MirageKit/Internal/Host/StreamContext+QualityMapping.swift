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

#if os(macOS)
extension StreamContext {
    func applyDerivedQuality(for outputSize: CGSize, logLabel: String?) async {
        guard let targetBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            minBitrate: encoderConfig.minBitrate,
            maxBitrate: encoderConfig.maxBitrate
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

        guard encoderConfig.frameQuality != derived.frameQuality ||
            encoderConfig.keyframeQuality != derived.keyframeQuality else {
            return
        }

        encoderConfig.frameQuality = derived.frameQuality
        encoderConfig.keyframeQuality = derived.keyframeQuality
        qualityCeiling = derived.frameQuality
        qualityFloor = max(0.1, derived.frameQuality * qualityFloorFactor)
        activeQuality = derived.frameQuality
        keyframeQualityFloor = max(0.1, derived.keyframeQuality * keyframeFloorFactor)

        await encoder?.updateQuality(derived.frameQuality)

        if let logLabel {
            let mbps = Double(targetBitrate) / 1_000_000.0
            let qualityText = derived.frameQuality.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.stream("\(logLabel): target \(mbps.formatted(.number.precision(.fractionLength(0)))) Mbps, quality \(qualityText)")
        }
    }
}
#endif
