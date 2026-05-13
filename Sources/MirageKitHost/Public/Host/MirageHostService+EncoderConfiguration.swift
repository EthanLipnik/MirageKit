//
//  MirageHostService+EncoderConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

#if os(macOS)

@MainActor
public extension MirageHostService {
    /// Resolves per-stream encoder settings from request overrides and host defaults.
    func resolveEncoderConfiguration(
        keyFrameInterval: Int?,
        targetFrameRate: Int?,
        colorDepth: MirageStreamColorDepth?,
        captureQueueDepth: Int?,
        bitrate: Int?,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil
    ) -> MirageEncoderConfiguration {
        var effectiveEncoderConfig = encoderConfig
        let requestedColorDepth = colorDepth
        let resolvedCodec = effectiveVideoCodec(for: codec)
        let resolvedColorDepth = effectiveColorDepth(for: requestedColorDepth, codec: resolvedCodec)

        if keyFrameInterval != nil || resolvedColorDepth != nil || captureQueueDepth != nil || bitrate != nil {
            effectiveEncoderConfig = encoderConfig.withOverrides(
                keyFrameInterval: keyFrameInterval,
                colorDepth: resolvedColorDepth,
                captureQueueDepth: captureQueueDepth,
                bitrate: bitrate
            )
            if let interval = keyFrameInterval { MirageLogger.host("Using client-requested keyframe interval: \(interval) frames") }
            if let requestedColorDepth, let resolvedColorDepth, requestedColorDepth != resolvedColorDepth {
                MirageLogger.host(
                    "Color depth request downgraded: requested=\(requestedColorDepth.displayName), effective=\(resolvedColorDepth.displayName)"
                )
            } else if let resolvedColorDepth {
                MirageLogger.host("Using client-requested color depth: \(resolvedColorDepth.displayName)")
            }
            if let captureQueueDepth { MirageLogger.host("Using client-requested capture queue depth: \(captureQueueDepth)") }
            if let bitrate { MirageLogger.host("Using client-requested bitrate: \(bitrate)") }
        }

        if let resolvedCodec {
            effectiveEncoderConfig.codec = resolvedCodec
        }

        // MetalFX is incompatible with ProRes pixel formats.
        if let upscalingMode, upscalingMode != .off, codec != .proRes4444 {
            effectiveEncoderConfig.applyUpscalingPixelFormat()
            MirageLogger.host("Applying BGRA pixel format for MetalFX \(upscalingMode.displayName) upscaling")
        }

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: effectiveEncoderConfig.bitrate
        ) {
            effectiveEncoderConfig.bitrate = normalized
        }

        if let targetFrameRate {
            effectiveEncoderConfig = effectiveEncoderConfig.withTargetFrameRate(targetFrameRate)
            MirageLogger.host("Using target frame rate: \(targetFrameRate)fps")
        }

        return effectiveEncoderConfig
    }
}

#endif
