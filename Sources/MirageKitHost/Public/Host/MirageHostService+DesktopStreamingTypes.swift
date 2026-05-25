//
//  MirageHostService+DesktopStreamingTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Desktop Streaming

/// Public snapshot of the currently active desktop stream.
public struct MirageHostDesktopStreamState: Sendable {
    /// Active desktop stream identifier.
    public let streamID: StreamID
    /// Client that owns the desktop stream.
    public let client: MirageConnectedClient
    /// Whether the current client can lock its desktop cursor.
    public let cursorLockAvailable: Bool
}

enum DesktopMirroringRestoreContinuationDecision: Equatable {
    case continueRestore
    case abortStreamInactive
    case abortModeChanged
}

func desktopMirroringRestoreContinuationDecision(
    requestedStreamID: StreamID,
    activeDesktopStreamID: StreamID?,
    hasDesktopContext: Bool,
    desktopStreamMode: MirageDesktopStreamMode
)
-> DesktopMirroringRestoreContinuationDecision {
    guard requestedStreamID == activeDesktopStreamID, hasDesktopContext else {
        return .abortStreamInactive
    }
    guard desktopStreamMode == .unified else {
        return .abortModeChanged
    }
    return .continueRestore
}

func capturedDisplaySpaceSnapshot(
    displayIDs: [CGDirectDisplayID],
    currentSpaceProvider: (CGDirectDisplayID) -> CGSSpaceID
)
-> [CGDirectDisplayID: CGSSpaceID] {
    var snapshot: [CGDirectDisplayID: CGSSpaceID] = [:]
    for displayID in displayIDs {
        let spaceID = currentSpaceProvider(displayID)
        guard spaceID != 0 else { continue }
        snapshot[displayID] = spaceID
    }
    return snapshot
}

func pendingDisplaySpaceRestores(
    snapshot: [CGDirectDisplayID: CGSSpaceID],
    currentSpaceProvider: (CGDirectDisplayID) -> CGSSpaceID
)
-> [CGDirectDisplayID: CGSSpaceID] {
    snapshot.filter { displayID, expectedSpaceID in
        let currentSpaceID = currentSpaceProvider(displayID)
        guard currentSpaceID != 0 else { return false }
        return currentSpaceID != expectedSpaceID
    }
}

func aspectFitPixelSize(contentSize: CGSize, containerSize: CGSize) -> CGSize {
    guard contentSize.width > 0, contentSize.height > 0,
          containerSize.width > 0, containerSize.height > 0 else {
        return contentSize
    }
    let contentAspect = contentSize.width / contentSize.height
    let containerAspect = containerSize.width / containerSize.height
    if containerAspect > contentAspect {
        let height = containerSize.height
        return CGSize(width: height * contentAspect, height: height)
    }
    let width = containerSize.width
    return CGSize(width: width, height: width / contentAspect)
}

let desktopStartupCaptureReadinessWindow: Duration = .milliseconds(750)
let desktopLowestLatencyFixedQualityBitrateCapBps = 150_000_000

extension MirageHostService {
    /// Current desktop-stream state, or `nil` when no desktop stream is active.
    public var activeDesktopStream: MirageHostDesktopStreamState? {
        guard let desktopStreamID,
              let client = desktopStreamClientContext?.client else {
            return nil
        }

        return MirageHostDesktopStreamState(
            streamID: desktopStreamID,
            client: client,
            cursorLockAvailable: remoteClientDesktopCursorLockAvailable
        )
    }

    struct DesktopVirtualDisplayMirroringTargetUnstable: Error {}

    struct DesktopStreamStartedNotification {
        let streamID: StreamID
        let desktopSessionID: UUID
        let activeClientContext: ClientContext
        let streamContext: StreamContext
        let captureResolution: CGSize
        let captureSource: MirageDesktopCaptureSource
        let allowsClientResize: Bool
        let presentationResolution: CGSize
        let acceptedDisplayScaleFactor: CGFloat?
    }

    struct DesktopStreamActivation {
        let streamID: StreamID
        let clientContext: ClientContext
        let streamContext: StreamContext
        let requestedScaleFactor: CGFloat
        let audioConfiguration: MirageAudioConfiguration
        let mode: MirageDesktopStreamMode
        let startupRequestID: UUID
        let captureDisplay: SCDisplayWrapper
        let captureResolution: CGSize
    }

    struct DesktopStreamActivationResult {
        let activeClientContext: ClientContext
        let audioConfiguration: MirageAudioConfiguration
    }

    struct DesktopCaptureContext {
        let display: SCDisplayWrapper
        let resolution: CGSize
        let p3CoverageStatus: MirageDisplayP3CoverageStatus?
        let colorSpace: MirageColorSpace?
        let captureSource: MirageDesktopCaptureSource
        let allowsClientResize: Bool
        let presentationResolution: CGSize
        let virtualDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
        let usesDisplayRefreshCadence: Bool?
    }

    struct DesktopMainDisplayCaptureFallback {
        let display: SCDisplayWrapper
        let resolution: CGSize
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let scaleFactor: CGFloat
    }

    struct DesktopCaptureAcquisitionRequest {
        let clientContext: ClientContext
        let startupRequestID: UUID
        let mode: MirageDesktopStreamMode
        let displayResolution: CGSize
        let virtualDisplayResolution: CGSize
        let startupPlan: DesktopVirtualDisplayStartupPlan
        let startupAttempts: [DesktopVirtualDisplayStartupAttempt]
        let usesHostResolution: Bool
    }

    struct DesktopEncoderConfigurationRequest {
        let keyFrameInterval: Int?
        let colorDepth: MirageStreamColorDepth?
        let captureQueueDepth: Int?
        let bitrate: Int?
        let codec: MirageVideoCodec?
        let latencyMode: MirageStreamLatencyMode
        let hostBufferingPolicy: MirageHostBufferingPolicy
        let allowRuntimeQualityAdjustment: Bool?
        let upscalingMode: MirageUpscalingMode?
        let targetFrameRate: Int?
        let disableResolutionCap: Bool
    }

    struct DesktopStreamContextRequest {
        let streamID: StreamID
        let config: MirageEncoderConfiguration
        let streamScale: CGFloat
        let audioConfiguration: MirageAudioConfiguration
        let mediaMaxPacketSize: Int
        let allowRuntimeQualityAdjustment: Bool?
        let lowLatencyHighResolutionCompressionBoost: Bool
        let disableResolutionCap: Bool
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
        let latencyMode: MirageStreamLatencyMode
        let hostBufferingPolicy: MirageHostBufferingPolicy
        let transportPathKind: MirageNetworkPathKind
        let mediaPathProfile: MirageMediaPathProfile
        let enteredBitrate: Int?
        let bitrateAdaptationCeiling: Int?
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?
        let cursorPresentation: MirageDesktopCursorPresentation
        let desktopStartTime: CFAbsoluteTime
        let captureDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus?
        let virtualDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
        let usesDisplayRefreshCadence: Bool?
    }
}

#endif
