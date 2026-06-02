//
//  VideoEncoder+Specification.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Video encoder specification policy helpers.
//

import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
extension VideoEncoder {
    nonisolated static func encoderSpecification(
        latencyMode: MirageStreamLatencyMode,
        streamKind: StreamKind,
        codec: MirageVideoCodec = .hevc,
        colorDepth: MirageStreamColorDepth? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) -> [CFString: Any] {
        if codec == .proRes4444 {
            return [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ]
        }

        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if standardLowLatencyVTTuningEnabled(
            latencyMode: latencyMode,
            streamKind: streamKind,
            colorDepth: colorDepth,
            pixelFormat: pixelFormat,
            mediaPathProfile: mediaPathProfile
        ) {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        return spec
    }

    nonisolated static func standardLowLatencyVTTuningEnabled(
        latencyMode: MirageStreamLatencyMode,
        streamKind: StreamKind,
        colorDepth: MirageStreamColorDepth? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) -> Bool {
        guard !mediaPathProfile.usesAwdlRadioPolicy else { return false }
        guard latencyMode == .lowestLatency || latencyMode == .balanced else { return false }
        return standardLowLatencyUsesSunshineRateControl(
            streamKind: streamKind,
            colorDepth: colorDepth,
            pixelFormat: pixelFormat
        )
    }

    nonisolated static func shouldSuppressStandardLowLatencyRateControl(
        streamKind: StreamKind,
        colorDepth: MirageStreamColorDepth? = nil,
        pixelFormat: MiragePixelFormat? = nil
    ) -> Bool {
        !standardLowLatencyUsesSunshineRateControl(
            streamKind: streamKind,
            colorDepth: colorDepth,
            pixelFormat: pixelFormat
        )
    }

    nonisolated static func shouldApplySuppressedStandardLowLatencyThroughputTuning(
        latencyMode: MirageStreamLatencyMode,
        streamKind: StreamKind,
        colorDepth: MirageStreamColorDepth? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) -> Bool {
        guard !mediaPathProfile.usesAwdlRadioPolicy else { return false }
        return (latencyMode == .lowestLatency || latencyMode == .balanced) &&
            shouldSuppressStandardLowLatencyRateControl(
                streamKind: streamKind,
                colorDepth: colorDepth,
                pixelFormat: pixelFormat
            )
    }

    nonisolated static func standardLowLatencyUsesSunshineRateControl(
        streamKind: StreamKind,
        colorDepth: MirageStreamColorDepth? = nil,
        pixelFormat: MiragePixelFormat? = nil
    ) -> Bool {
        streamKind == .desktop ||
            colorDepth == .ultra ||
            pixelFormat == .xf44 ||
            pixelFormat == .ayuv16
    }
}

#endif
