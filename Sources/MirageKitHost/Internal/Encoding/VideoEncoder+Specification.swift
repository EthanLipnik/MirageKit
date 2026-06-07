//
//  VideoEncoder+Specification.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Video encoder specification policy helpers.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import VideoToolbox

#if os(macOS)
extension VideoEncoder {
    nonisolated static func encoderSpecification(
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        streamKind: StreamKind,
        codec: MirageMedia.MirageVideoCodec = .hevc,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        pixelFormat: MirageMedia.MiragePixelFormat? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
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
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        streamKind: StreamKind,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        pixelFormat: MirageMedia.MiragePixelFormat? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
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
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        pixelFormat: MirageMedia.MiragePixelFormat? = nil
    ) -> Bool {
        !standardLowLatencyUsesSunshineRateControl(
            streamKind: streamKind,
            colorDepth: colorDepth,
            pixelFormat: pixelFormat
        )
    }

    nonisolated static func shouldApplySuppressedStandardLowLatencyThroughputTuning(
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        streamKind: StreamKind,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        pixelFormat: MirageMedia.MiragePixelFormat? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
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
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        pixelFormat: MirageMedia.MiragePixelFormat? = nil
    ) -> Bool {
        streamKind == .desktop ||
            colorDepth == .ultra ||
            pixelFormat == .xf44 ||
            pixelFormat == .ayuv16
    }
}

#endif
