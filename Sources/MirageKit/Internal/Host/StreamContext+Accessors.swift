//
//  StreamContext+Accessors.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream context accessors and handler registration.
//

import CoreGraphics
import Foundation

#if os(macOS)
struct EncoderSettingsSnapshot: Sendable {
    let keyFrameInterval: Int
    let pixelFormat: MiragePixelFormat
    let colorSpace: MirageColorSpace
    let captureQueueDepth: Int?
    let minBitrate: Int?
    let maxBitrate: Int?
}

extension StreamContext {
    func getDroppedFrameCount() -> UInt64 {
        droppedFrameCount
    }

    func setMetricsUpdateHandler(_ handler: (@Sendable (StreamMetricsMessage) -> Void)?) {
        metricsUpdateHandler = handler
    }

    func isUsingVirtualDisplay() -> Bool {
        useVirtualDisplay && virtualDisplayContext != nil
    }

    func getVirtualDisplayID() -> CGDirectDisplayID? {
        virtualDisplayContext?.displayID
    }

    func getSharedDisplayGeneration() -> UInt64 {
        sharedDisplayGeneration
    }

    func isReadyForSharedDisplayRebind() -> Bool {
        isRunning && useVirtualDisplay && virtualDisplayContext != nil && encoder != nil && packetSender != nil
    }

    nonisolated func getWindowID() -> WindowID {
        windowID
    }

    func getDimensionToken() -> UInt16 {
        dimensionToken
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

    func getEncoderSettings() -> EncoderSettingsSnapshot {
        EncoderSettingsSnapshot(
            keyFrameInterval: encoderConfig.keyFrameInterval,
            pixelFormat: activePixelFormat,
            colorSpace: encoderConfig.colorSpace,
            captureQueueDepth: encoderConfig.captureQueueDepth,
            minBitrate: encoderConfig.minBitrate,
            maxBitrate: encoderConfig.maxBitrate
        )
    }
}
#endif
