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
    let frameQuality: Float
    let keyframeQuality: Float
    let pixelFormat: MiragePixelFormat
    let colorSpace: MirageColorSpace
    let latencyMode: MirageStreamLatencyMode
    let performanceMode: MirageStreamPerformanceMode
    let runtimeQualityAdjustmentEnabled: Bool
    let lowLatencyHighResolutionCompressionBoostEnabled: Bool
    let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
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

    func getVirtualDisplaySnapshot() -> SharedVirtualDisplayManager.DisplaySnapshot? {
        virtualDisplayContext
    }

    func getVirtualDisplayVisibleBounds() -> CGRect {
        virtualDisplayVisibleBounds
    }

    func getVirtualDisplayCaptureSourceRect() -> CGRect {
        virtualDisplayCaptureSourceRect
    }

    func getVirtualDisplayVisiblePixelResolution() -> CGSize {
        virtualDisplayVisiblePixelResolution
    }

    func getWindowID() -> WindowID {
        windowID
    }

    func updateWindowBinding(windowID: WindowID, ownerGeneration: UInt64?) {
        self.windowID = windowID
        if let ownerGeneration,
           let snapshot = virtualDisplayContext {
            virtualDisplayContext = SharedVirtualDisplayManager.DisplaySnapshot(
                displayID: snapshot.displayID,
                spaceID: snapshot.spaceID,
                resolution: snapshot.resolution,
                scaleFactor: snapshot.scaleFactor,
                refreshRate: snapshot.refreshRate,
                colorSpace: snapshot.colorSpace,
                generation: ownerGeneration,
                createdAt: snapshot.createdAt
            )
        }
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

    func getInFlightPolicy() -> (
        minInFlightFrames: Int,
        maxInFlightFrames: Int,
        maxInFlightFramesCap: Int,
        frameBufferDepth: Int
    ) {
        (
            minInFlightFrames: minInFlightFrames,
            maxInFlightFrames: maxInFlightFrames,
            maxInFlightFramesCap: maxInFlightFramesCap,
            frameBufferDepth: frameBufferDepth
        )
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
            frameQuality: encoderConfig.frameQuality,
            keyframeQuality: encoderConfig.keyframeQuality,
            pixelFormat: activePixelFormat,
            colorSpace: encoderConfig.colorSpace,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoostEnabled,
            capturePressureProfile: capturePressureProfile,
            captureQueueDepth: encoderConfig.captureQueueDepth,
            bitrate: encoderConfig.bitrate
        )
    }

    func getPerformanceMode() -> MirageStreamPerformanceMode {
        performanceMode
    }

    func getGameModeStage() -> GameModeStage {
        gameModeStage
    }

    func getGameModeStreamStartTime() -> CFAbsoluteTime {
        gameModeStreamStartTime
    }
}
#endif
