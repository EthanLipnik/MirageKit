//
//  WindowCaptureEngine+StreamConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(macOS)
import CoreGraphics
import ScreenCaptureKit

extension WindowCaptureEngine {
    /// Applies the capture dimensions that match the active window or display capture mode.
    func applyResolutionSettings(to streamConfig: SCStreamConfiguration) {
        switch captureMode {
        case .window:
            streamConfig.captureResolution = .best
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        case .display:
            if displayUsesExplicitResolution {
                streamConfig.width = currentWidth
                streamConfig.height = currentHeight
            } else {
                streamConfig.captureResolution = .best
            }
        case nil:
            streamConfig.captureResolution = .best
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }
    }

    /// Applies ScreenCaptureKit audio capture fields while preserving the current session defaults.
    func applyAudioSettings(
        to streamConfig: SCStreamConfiguration,
        enabled: Bool? = nil,
        channelCount: Int? = nil
    ) {
        let audioEnabled = enabled ?? isAudioCaptureConfigured
        streamConfig.capturesAudio = audioEnabled
        guard audioEnabled else { return }
        let resolvedChannelCount = channelCount ?? captureSessionConfig?.audioChannelCount
        if let resolvedChannelCount {
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = resolvedChannelCount
        }
    }

    /// Builds a ScreenCaptureKit stream configuration for an in-place capture update.
    func makeStreamConfigurationForUpdate(
        width: Int? = nil,
        height: Int? = nil,
        useBestCaptureResolution: Bool = false,
        showsCursor: Bool,
        sourceRect: CGRect?,
        destinationRect: CGRect? = nil
    ) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        if let width, let height {
            streamConfig.width = width
            streamConfig.height = height
        } else {
            applyResolutionSettings(to: streamConfig)
        }
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = showsCursor
        streamConfig.queueDepth = sckQueueDepth
        applyAudioSettings(to: streamConfig)
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: sourceRect,
            destinationRect: destinationRect
        )
        return streamConfig
    }
}
#endif
