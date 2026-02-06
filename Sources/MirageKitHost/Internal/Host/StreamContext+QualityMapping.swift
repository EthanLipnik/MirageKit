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
        let cappedFrameQuality = min(derived.frameQuality, compressionQualityCeiling)
        let cappedKeyframeQuality = min(derived.keyframeQuality, cappedFrameQuality)

        guard encoderConfig.frameQuality != cappedFrameQuality ||
            encoderConfig.keyframeQuality != cappedKeyframeQuality else {
            return
        }

        encoderConfig.frameQuality = cappedFrameQuality
        encoderConfig.keyframeQuality = cappedKeyframeQuality
        qualityCeiling = cappedFrameQuality
        qualityFloor = max(0.1, cappedFrameQuality * qualityFloorFactor)
        activeQuality = min(activeQuality, qualityCeiling)
        if activeQuality < qualityFloor { activeQuality = qualityFloor }
        keyframeQualityFloor = max(0.1, cappedKeyframeQuality * keyframeFloorFactor)

        await encoder?.updateQuality(activeQuality)

        if let logLabel {
            let mbps = Double(targetBitrate) / 1_000_000.0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let capText = compressionQualityCeiling.formatted(.number.precision(.fractionLength(2)))
            MirageLogger
                .stream(
                    "\(logLabel): target \(mbps.formatted(.number.precision(.fractionLength(0)))) Mbps, quality \(qualityText) (cap \(capText))"
                )
        }
    }
}
#endif
