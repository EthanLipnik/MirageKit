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
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let colorDepth = overrides.colorDepth {
            request.colorDepth = colorDepth
            MirageLogger.client("Requesting color depth: \(colorDepth.displayName)")
        }
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
            MirageLogger.client("Requesting bitrate: \(mirageFormattedMegabitRate(bitrate))")
        }
        if let latencyMode = overrides.latencyMode {
            request.latencyMode = latencyMode
            MirageLogger.client("Requesting latency mode: \(latencyMode.displayName)")
        }
        if let hostBufferingPolicy = overrides.hostBufferingPolicy {
            request.hostBufferingPolicy = hostBufferingPolicy
            MirageLogger.client("Requesting host buffering policy: \(hostBufferingPolicy.rawValue)")
        }
        if let allowRuntimeQualityAdjustment = overrides.allowRuntimeQualityAdjustment {
            request.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
            MirageLogger
                .client(
                    "Requesting runtime quality adjustment: \(allowRuntimeQualityAdjustment ? "enabled" : "disabled")"
                )
        }
        if let lowLatencyHighResolutionCompressionBoost = overrides.lowLatencyHighResolutionCompressionBoost {
            request.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
            MirageLogger
                .client(
                    "Requesting low-latency high-res compression boost: \(lowLatencyHighResolutionCompressionBoost ? "enabled" : "disabled")"
                )
        }
        if overrides.disableResolutionCap {
            request.disableResolutionCap = true
            MirageLogger.client("Requesting uncapped resolution pipeline")
        }
        if let bitrateAdaptationCeiling = overrides.bitrateAdaptationCeiling, bitrateAdaptationCeiling > 0 {
            request.bitrateAdaptationCeiling = bitrateAdaptationCeiling
            MirageLogger
                .client("Requesting bitrate adaptation ceiling: \(mirageFormattedMegabitRate(bitrateAdaptationCeiling))")
        }
        if let encoderMaxWidth = overrides.encoderMaxWidth, encoderMaxWidth > 0 {
            request.encoderMaxWidth = encoderMaxWidth
        }
        if let encoderMaxHeight = overrides.encoderMaxHeight, encoderMaxHeight > 0 {
            request.encoderMaxHeight = encoderMaxHeight
        }
        if let codec = overrides.codec {
            request.codec = codec
            MirageLogger.client("Requesting codec: \(codec.rawValue)")
        }
    }

    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout SelectAppMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let colorDepth = overrides.colorDepth {
            request.colorDepth = colorDepth
            MirageLogger.client("Requesting color depth: \(colorDepth.displayName)")
        }
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
            MirageLogger.client("Requesting bitrate: \(mirageFormattedMegabitRate(bitrate))")
        }
        if let latencyMode = overrides.latencyMode {
            request.latencyMode = latencyMode
            MirageLogger.client("Requesting latency mode: \(latencyMode.displayName)")
        }
        if let hostBufferingPolicy = overrides.hostBufferingPolicy {
            request.hostBufferingPolicy = hostBufferingPolicy
            MirageLogger.client("Requesting host buffering policy: \(hostBufferingPolicy.rawValue)")
        }
        if let allowRuntimeQualityAdjustment = overrides.allowRuntimeQualityAdjustment {
            request.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
            MirageLogger
                .client(
                    "Requesting runtime quality adjustment: \(allowRuntimeQualityAdjustment ? "enabled" : "disabled")"
                )
        }
        if let lowLatencyHighResolutionCompressionBoost = overrides.lowLatencyHighResolutionCompressionBoost {
            request.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
            MirageLogger
                .client(
                    "Requesting low-latency high-res compression boost: \(lowLatencyHighResolutionCompressionBoost ? "enabled" : "disabled")"
                )
        }
        if overrides.disableResolutionCap {
            request.disableResolutionCap = true
            MirageLogger.client("Requesting uncapped resolution pipeline")
        }
        if let bitrateAdaptationCeiling = overrides.bitrateAdaptationCeiling, bitrateAdaptationCeiling > 0 {
            request.bitrateAdaptationCeiling = bitrateAdaptationCeiling
            MirageLogger
                .client("Requesting bitrate adaptation ceiling: \(mirageFormattedMegabitRate(bitrateAdaptationCeiling))")
        }
        if let encoderMaxWidth = overrides.encoderMaxWidth, encoderMaxWidth > 0 {
            request.encoderMaxWidth = encoderMaxWidth
        }
        if let encoderMaxHeight = overrides.encoderMaxHeight, encoderMaxHeight > 0 {
            request.encoderMaxHeight = encoderMaxHeight
        }
        if let codec = overrides.codec {
            request.codec = codec
            MirageLogger.client("Requesting codec: \(codec.rawValue)")
        }
    }

    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartDesktopStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
            MirageLogger.client("Requesting keyframe interval: \(keyFrameInterval) frames")
        }
        if let captureQueueDepth = overrides.captureQueueDepth, captureQueueDepth > 0 {
            request.captureQueueDepth = captureQueueDepth
            MirageLogger.client("Requesting capture queue depth: \(captureQueueDepth)")
        }
        if let colorDepth = overrides.colorDepth {
            request.colorDepth = colorDepth
            MirageLogger.client("Requesting color depth: \(colorDepth.displayName)")
        }
        if let enteredBitrate = overrides.enteredBitrate, enteredBitrate > 0 {
            request.enteredBitrate = enteredBitrate
        }
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
        }
        if let latencyMode = overrides.latencyMode {
            request.latencyMode = latencyMode
            MirageLogger.client("Requesting latency mode: \(latencyMode.displayName)")
        }
        if let hostBufferingPolicy = overrides.hostBufferingPolicy {
            request.hostBufferingPolicy = hostBufferingPolicy
            MirageLogger.client("Requesting host buffering policy: \(hostBufferingPolicy.rawValue)")
        }
        if let allowRuntimeQualityAdjustment = overrides.allowRuntimeQualityAdjustment {
            request.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
            MirageLogger
                .client(
                    "Requesting runtime quality adjustment: \(allowRuntimeQualityAdjustment ? "enabled" : "disabled")"
                )
        }
        if let allowEncoderCatchUpQualityAdjustment = overrides.allowEncoderCatchUpQualityAdjustment {
            request.allowEncoderCatchUpQualityAdjustment = allowEncoderCatchUpQualityAdjustment
            MirageLogger.client(
                "Requesting encoder catch-up quality adjustment: " +
                    "\(allowEncoderCatchUpQualityAdjustment ? "enabled" : "disabled")"
            )
        }
        if let lowLatencyHighResolutionCompressionBoost = overrides.lowLatencyHighResolutionCompressionBoost {
            request.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
            MirageLogger
                .client(
                    "Requesting low-latency high-res compression boost: \(lowLatencyHighResolutionCompressionBoost ? "enabled" : "disabled")"
                )
        }
        if overrides.disableResolutionCap {
            request.disableResolutionCap = true
            MirageLogger.client("Requesting uncapped resolution pipeline")
        }
        if let bitrateAdaptationCeiling = overrides.bitrateAdaptationCeiling, bitrateAdaptationCeiling > 0 {
            request.bitrateAdaptationCeiling = bitrateAdaptationCeiling
            MirageLogger
                .client("Requesting bitrate adaptation ceiling: \(mirageFormattedMegabitRate(bitrateAdaptationCeiling))")
        }
        if let encoderMaxWidth = overrides.encoderMaxWidth, encoderMaxWidth > 0 {
            request.encoderMaxWidth = encoderMaxWidth
        }
        if let encoderMaxHeight = overrides.encoderMaxHeight, encoderMaxHeight > 0 {
            request.encoderMaxHeight = encoderMaxHeight
        }
        if let codec = overrides.codec {
            request.codec = codec
            MirageLogger.client("Requesting codec: \(codec.rawValue)")
        }
    }

    func applyEncoderOverrides(_ overrides: MirageEncoderOverrides, to request: inout StartCustomStreamMessage) {
        if let keyFrameInterval = overrides.keyFrameInterval, keyFrameInterval > 0 {
            request.keyFrameInterval = keyFrameInterval
        }
        if let bitrate = overrides.bitrate, bitrate > 0 {
            request.bitrate = bitrate
        }
        if let latencyMode = overrides.latencyMode {
            request.latencyMode = latencyMode
        }
        if let hostBufferingPolicy = overrides.hostBufferingPolicy {
            request.hostBufferingPolicy = hostBufferingPolicy
        }
        if let allowRuntimeQualityAdjustment = overrides.allowRuntimeQualityAdjustment {
            request.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        }
        if let lowLatencyHighResolutionCompressionBoost = overrides.lowLatencyHighResolutionCompressionBoost {
            request.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        }
        if overrides.disableResolutionCap {
            request.disableResolutionCap = true
        }
        if let bitrateAdaptationCeiling = overrides.bitrateAdaptationCeiling, bitrateAdaptationCeiling > 0 {
            request.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        }
        if let encoderMaxWidth = overrides.encoderMaxWidth, encoderMaxWidth > 0 {
            request.encoderMaxWidth = encoderMaxWidth
        }
        if let encoderMaxHeight = overrides.encoderMaxHeight, encoderMaxHeight > 0 {
            request.encoderMaxHeight = encoderMaxHeight
        }
        if let upscalingMode = overrides.upscalingMode {
            request.upscalingMode = upscalingMode
        }
        if let codec = overrides.codec {
            request.codec = codec
        }
    }
}
