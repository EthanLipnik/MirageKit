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
import MirageKit

#if os(macOS)
struct EncoderSettingsSnapshot: Sendable {
    let keyFrameInterval: Int
    let bitDepth: MirageVideoBitDepth
    let pixelFormat: MiragePixelFormat
    let colorSpace: MirageColorSpace
    let latencyMode: MirageStreamLatencyMode
    let captureQueueDepth: Int?
    let bitrate: Int?
}

extension StreamContext {
    func getDroppedFrameCount() -> UInt64 {
        droppedFrameCount
    }

    func setMetricsUpdateHandler(_ handler: (@Sendable (StreamMetricsMessage) -> Void)?) {
        metricsUpdateHandler = handler
    }

    func setCapturedAudioHandler(_ handler: (@Sendable (CapturedAudioBuffer) -> Void)?) {
        onCapturedAudioBuffer = handler
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

    func isResolutionCapDisabled() -> Bool {
        disableResolutionCap
    }

    func getEncoderSettings() -> EncoderSettingsSnapshot {
        EncoderSettingsSnapshot(
            keyFrameInterval: encoderConfig.keyFrameInterval,
            bitDepth: encoderConfig.bitDepth,
            pixelFormat: activePixelFormat,
            colorSpace: encoderConfig.colorSpace,
            latencyMode: latencyMode,
            captureQueueDepth: encoderConfig.captureQueueDepth,
            bitrate: encoderConfig.bitrate
        )
    }
}
#endif
