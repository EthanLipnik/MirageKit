//
//  StreamContext+Accessors.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream context accessors and handler registration.
//

import Foundation
import CoreGraphics

#if os(macOS)
extension StreamContext {
    func getDroppedFrameCount() -> UInt64 {
        return droppedFrameCount
    }

    func setMetricsUpdateHandler(_ handler: (@Sendable (StreamMetricsMessage) -> Void)?) {
        metricsUpdateHandler = handler
    }

    func setStreamScaleUpdateHandler(_ handler: (@Sendable (StreamID) -> Void)?) {
        streamScaleUpdateHandler = handler
    }

    func isUsingVirtualDisplay() -> Bool {
        return useVirtualDisplay && virtualDisplayContext != nil
    }

    func getVirtualDisplayID() -> CGDirectDisplayID? {
        return virtualDisplayContext?.displayID
    }

    func getSharedDisplayGeneration() -> UInt64 {
        sharedDisplayGeneration
    }

    func isReadyForSharedDisplayRebind() -> Bool {
        isRunning && useVirtualDisplay && virtualDisplayContext != nil && encoder != nil && packetSender != nil
    }

    nonisolated func getWindowID() -> WindowID {
        return windowID
    }

    func getDimensionToken() -> UInt16 {
        return dimensionToken
    }

    func getEncodedDimensions() -> (width: Int, height: Int) {
        let width = Int(currentEncodedSize.width)
        let height = Int(currentEncodedSize.height)
        return (width, height)
    }

    func getLastCapturedFrameTime() -> CFAbsoluteTime {
        lastCapturedFrameTime
    }

    func getTargetFrameRate() -> Int {
        encoderConfig.targetFrameRate
    }

    func getCodec() -> MirageVideoCodec {
        encoderConfig.codec
    }

    func getStreamScale() -> CGFloat {
        streamScale
    }

    func getQualityPreset() -> MirageQualityPreset? {
        qualityPreset
    }

    func getAdaptiveScaleEnabled() -> Bool {
        adaptiveScaleEnabled
    }

    func setAdaptiveScaleEnabled(_ enabled: Bool) {
        adaptiveScaleEnabled = enabled
        adaptiveScale = 1.0
        adaptiveScaleLowStreak = 0
        adaptiveScaleHighStreak = 0
        lastAdaptiveScaleChangeTime = 0
    }

    func getEncoderSettings() -> (
        keyFrameInterval: Int,
        frameQuality: Float,
        keyframeQuality: Float,
        pixelFormat: MiragePixelFormat,
        colorSpace: MirageColorSpace,
        captureQueueDepth: Int?,
        minBitrate: Int?,
        maxBitrate: Int?
    ) {
        (
            encoderConfig.keyFrameInterval,
            encoderConfig.frameQuality,
            encoderConfig.keyframeQuality,
            activePixelFormat,
            encoderConfig.colorSpace,
            encoderConfig.captureQueueDepth,
            encoderConfig.minBitrate,
            encoderConfig.maxBitrate
        )
    }
}
#endif
