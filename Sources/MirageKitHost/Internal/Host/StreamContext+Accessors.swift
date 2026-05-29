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
/// Actor-safe encoder settings needed by host service code outside `StreamContext`.
struct EncoderSettingsSnapshot: Sendable {
    /// Requested output bit depth for the active encoder session.
    let bitDepth: MirageVideoBitDepth

    /// Pixel format currently being fed into the encoder.
    let pixelFormat: MiragePixelFormat

    /// Color-space target associated with the encoder configuration.
    let colorSpace: MirageColorSpace

    /// Active encoder bitrate, or `nil` when the encoder uses its default rate.
    let bitrate: Int?
}

/// Immutable stream-start metadata sent to clients and reused by resize notifications.
struct StreamStartSnapshot: Sendable {
    /// Encoded output size for media frames.
    let encodedDimensions: (width: Int, height: Int)

    /// Target frame cadence advertised for this stream.
    let targetFrameRate: Int

    /// Video codec selected for this stream.
    let codec: MirageVideoCodec

    /// Token that lets clients reject frames from older encoder dimensions.
    let dimensionToken: UInt16

    /// Maximum media packet payload size negotiated for the stream.
    let mediaMaxPacketSize: Int
}

/// Effective media path policy for a stream.
struct StreamMediaPathSnapshot: Sendable {
    let transportPathKind: MirageNetworkPathKind
    let mediaPathProfile: MirageMediaPathProfile
}

/// Virtual-display geometry captured as one actor-isolated snapshot for stream-setting updates.
struct VirtualDisplayGeometrySnapshot: Sendable {
    /// Shared display backing the stream.
    let display: SharedVirtualDisplayManager.DisplaySnapshot

    /// Visible bounds on the virtual display in host logical coordinates.
    let visibleBounds: CGRect

    /// Rect where the captured content is presented on the virtual display.
    let capturePresentationRect: CGRect

    /// Source rect used to crop display capture into stream content.
    let captureSourceRect: CGRect

    /// Host window currently associated with this virtual-display stream.
    let windowID: WindowID
}

extension StreamContext {
    func setEncoderLowPowerEnabled(_ enabled: Bool) async {
        guard encoderLowPowerEnabled != enabled else { return }
        encoderLowPowerEnabled = enabled
        await encoder?.setMaximizePowerEfficiencyEnabled(enabled)
    }

    func setMetricsUpdateHandler(_ handler: (@Sendable (StreamMetricsMessage) -> Void)?) {
        metricsUpdateHandler = handler
    }

    func setCapturedAudioHandler(_ handler: (@Sendable (CapturedAudioBuffer) -> Void)?) async {
        onCapturedAudioBuffer = handler
        if let captureEngine {
            await captureEngine.setCapturedAudioHandler(handler)
        }
    }

    func setCaptureStallStageHandler(_ handler: (@Sendable (CaptureStreamOutput.StallStage) -> Void)?) async {
        captureStallStageHandler = handler
        if let captureEngine {
            await captureEngine.setCaptureStallStageHandler(handler)
        }
    }

    func setRequestedAudioChannelCount(_ channelCount: Int) {
        requestedAudioChannelCount = Self.clampedAudioCaptureChannelCount(channelCount)
    }

    func restartCaptureForAudioRecovery(reason: String) async {
        guard let captureEngine else { return }
        await captureEngine.restartCapture(reason: reason)
    }

    /// Returns the capture cadence currently in force for a requested target frame rate.
    func resolvedCaptureFrameRate(for targetFrameRate: Int) -> Int {
        if let override = captureFrameRateOverride { return override }
        return targetFrameRate
    }

    /// Refreshes the cached cadence from the active ScreenCaptureKit capture engine.
    func refreshCaptureCadence() async {
        guard let captureEngine else { return }
        let effectiveRate = await captureEngine.minimumFrameIntervalRate
        captureFrameRate = effectiveRate
    }

    var isUsingVirtualDisplay: Bool {
        useVirtualDisplay &&
            virtualDisplayContext != nil &&
            (captureMode == .display || !virtualDisplayVisibleBounds.isEmpty)
    }

    var virtualDisplayGeometrySnapshot: VirtualDisplayGeometrySnapshot? {
        guard let virtualDisplayContext else { return nil }
        return VirtualDisplayGeometrySnapshot(
            display: virtualDisplayContext,
            visibleBounds: virtualDisplayVisibleBounds,
            capturePresentationRect: virtualDisplayCapturePresentationRect,
            captureSourceRect: virtualDisplayCaptureSourceRect,
            windowID: windowID
        )
    }

    func configureDesktopVirtualDisplayCapture(
        snapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
        usesDisplayRefreshCadence: Bool?
    ) {
        virtualDisplayContext = snapshot
        desktopCaptureUsesDisplayRefreshCadenceOverride = usesDisplayRefreshCadence
        updateWindowCaptureVirtualDisplayState(snapshot)
    }

    func setDisplayP3CoverageStatusOverride(_ status: MirageDisplayP3CoverageStatus?) {
        displayP3CoverageStatusOverride = status
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
                displayP3CoverageStatus: snapshot.displayP3CoverageStatus,
                generation: ownerGeneration,
                createdAt: snapshot.createdAt
            )
        }
    }

    func updateVirtualDisplaySnapshotResolution(_ resolution: CGSize) {
        guard resolution.width > 0,
              resolution.height > 0,
              let snapshot = virtualDisplayContext,
              snapshot.resolution != resolution else {
            return
        }

        virtualDisplayContext = SharedVirtualDisplayManager.DisplaySnapshot(
            displayID: snapshot.displayID,
            spaceID: snapshot.spaceID,
            resolution: resolution,
            scaleFactor: snapshot.scaleFactor,
            refreshRate: snapshot.refreshRate,
            colorSpace: snapshot.colorSpace,
            displayP3CoverageStatus: snapshot.displayP3CoverageStatus,
            generation: snapshot.generation,
            createdAt: snapshot.createdAt
        )
    }

    var encodedDimensions: (width: Int, height: Int) {
        let width = Int(currentEncodedSize.width)
        let height = Int(currentEncodedSize.height)
        return (width, height)
    }

    var streamStartSnapshot: StreamStartSnapshot {
        StreamStartSnapshot(
            encodedDimensions: encodedDimensions,
            targetFrameRate: encoderConfig.targetFrameRate,
            codec: encoderConfig.codec,
            dimensionToken: dimensionToken,
            mediaMaxPacketSize: mediaMaxPacketSize
        )
    }

    var streamMediaPathSnapshot: StreamMediaPathSnapshot {
        StreamMediaPathSnapshot(
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    var encoderMaxDimensions: (width: Int?, height: Int?) {
        (encoderMaxWidth, encoderMaxHeight)
    }

    func updateDesktopResizeGeometryRequest(
        requestedStreamScale: CGFloat?,
        encoderMaxWidth: Int?,
        encoderMaxHeight: Int?
    ) {
        if let requestedStreamScale {
            self.requestedStreamScale = StreamContext.clampStreamScale(requestedStreamScale)
        }
        if let encoderMaxWidth, encoderMaxWidth > 0 {
            self.encoderMaxWidth = encoderMaxWidth
        }
        if let encoderMaxHeight, encoderMaxHeight > 0 {
            self.encoderMaxHeight = encoderMaxHeight
        }
    }

    var encoderSettings: EncoderSettingsSnapshot {
        EncoderSettingsSnapshot(
            bitDepth: encoderConfig.bitDepth,
            pixelFormat: activePixelFormat,
            colorSpace: encoderConfig.colorSpace,
            bitrate: encoderConfig.bitrate
        )
    }

    func logBitrateContract(event: String) {
        let enteredText = enteredTargetBitrate.map(String.init) ?? "nil"
        let requestedText = requestedTargetBitrate.map(String.init) ?? "nil"
        let currentText = (currentTargetBitrateBps ?? encoderConfig.bitrate).map(String.init) ?? "nil"
        let ceilingText = bitrateAdaptationCeiling.map(String.init) ?? "nil"
        let startupText = startupBitrate.map(String.init) ?? "nil"
        MirageLogger.metrics(
            "event=bitrate_contract stream=\(streamID) phase=\(event) entered=\(enteredText) requested=\(requestedText) current=\(currentText) startup=\(startupText) ceiling=\(ceilingText)"
        )
    }

}
#endif
