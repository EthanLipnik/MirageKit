//
//  MirageClientService+EncoderOverrides.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Encoder override helpers for stream requests.
//

import Foundation

@MainActor
extension MirageClientService {
    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting minimum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting maximum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }

    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout SelectAppMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting minimum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting maximum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }

    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartDesktopStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let pixelFormat = overrides.pixelFormat {
            request.pixelFormat = pixelFormat
            MirageLogger.client("Requesting pixel format: \(pixelFormat.displayName)")
        }
        if let colorSpace = overrides.colorSpace {
            request.colorSpace = colorSpace
            MirageLogger.client("Requesting color space: \(colorSpace.displayName)")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let minBitrate = overrides.minBitrate, minBitrate > 0 {
            request.minBitrate = minBitrate
            let mbps = Double(minBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting minimum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let maxBitrate = overrides.maxBitrate, maxBitrate > 0 {
            request.maxBitrate = maxBitrate
            let mbps = Double(maxBitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting maximum bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }
}
