//
//  MirageClientService+EncoderOverrides.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Encoder override helpers for stream requests.
//

import Foundation
import MirageKit

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
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
            let mbps = Double(bitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
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
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
            let mbps = Double(bitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
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
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
            let mbps = Double(bitrate) / 1_000_000.0
            MirageLogger
                .client("Requesting bitrate: \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
    }
}
