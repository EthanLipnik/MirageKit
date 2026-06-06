//
//  MirageDesktopStartupMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Desktop startup request message definitions.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageMedia

/// Client-to-host request to start a desktop stream.
///
/// The request can start unified desktop mirroring or a secondary virtual display.
package struct StartDesktopStreamMessage: Codable {
    /// Request-scoped identifier used to cancel or reject stale startup work.
    package let startupRequestID: UUID

    /// Client display scale factor.
    package let scaleFactor: CGFloat?

    /// Client display width in points.
    package let displayWidth: Int

    /// Client display height in points.
    package let displayHeight: Int

    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int

    /// Client-requested keyframe interval in frames.
    package var keyFrameInterval: Int?

    /// Client-requested ScreenCaptureKit queue depth.
    package var captureQueueDepth: Int?

    /// Client-requested stream color depth preset.
    package var colorDepth: MirageMedia.MirageStreamColorDepth?

    /// Desktop stream mode.
    package var mode: MirageMedia.MirageDesktopStreamMode?

    /// Desktop cursor presentation requested by the client.
    package var cursorPresentation: MirageDesktopCursorPresentation?

    /// Client-entered bitrate budget before any desktop geometry scaling.
    package var enteredBitrate: Int?

    /// Client-requested target bitrate in bits per second.
    package var bitrate: Int?

    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageMedia.MirageStreamLatencyMode?

    /// Client-requested host-side capture-to-encode buffering policy.
    package var hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy?

    /// Client-requested host-side capture and encode buffer depth.
    package var hostBufferDepth: MirageMedia.MirageHostBufferDepth?

    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?

    /// Client-requested quality reduction when host encoding falls behind.
    package var allowEncoderCatchUpQualityAdjustment: Bool?

    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?

    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?

    /// Client-requested post-capture stream scale.
    package let streamScale: CGFloat?

    /// Client audio streaming configuration.
    package let audioConfiguration: MirageMedia.MirageAudioConfiguration?

    /// UDP port the client is listening on for video data.
    package let dataPort: UInt16?

    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    package var bitrateAdaptationCeiling: Int?

    /// Maximum host encoder compression-quality value for this stream.
    package var compressionQualityCeiling: Float?

    /// Maximum encoded width in pixels for host-computed stream scaling.
    package var encoderMaxWidth: Int?

    /// Maximum encoded height in pixels for host-computed stream scaling.
    package var encoderMaxHeight: Int?

    /// Requested media packet size for this stream.
    package var mediaMaxPacketSize: Int?

    /// Client-observed control path kind at stream start.
    package var clientTransportPathKind: MirageCore.MirageNetworkPathKind?

    /// Client-observed media profile at stream start.
    package var clientMediaPathProfile: MirageMedia.MirageMediaPathProfile?

    /// Diagnostic client control-path signature at stream start.
    package var clientPathSignature: String?

    /// Client-selected policy path kind for stream budgeting.
    package var clientPolicyPathKind: MirageCore.MirageNetworkPathKind?

    /// Client-selected media policy profile for stream budgeting.
    package var clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile?

    /// Client-requested MetalFX upscaling mode.
    package var upscalingMode: MirageMedia.MirageUpscalingMode?

    /// Client-requested video codec.
    package var codec: MirageMedia.MirageVideoCodec?

    /// When true, the host should use its current display resolution instead of the client-provided dimensions.
    package var useHostResolution: Bool?

    /// Client geometry contract identity for startup-size acceptance and stale-start rejection.
    package var desktopGeometryContractID: UUID?

    /// Diagnostic scene identity associated with the client drawable that produced this startup geometry.
    package var desktopGeometrySceneIdentity: String?

    /// Client-requested display pixel width for the startup geometry contract.
    package var desktopGeometryDisplayPixelWidth: Int?

    /// Client-requested display pixel height for the startup geometry contract.
    package var desktopGeometryDisplayPixelHeight: Int?

    /// Client-requested encoded pixel width for the startup geometry contract.
    package var desktopGeometryEncodedPixelWidth: Int?

    /// Client-requested encoded pixel height for the startup geometry contract.
    package var desktopGeometryEncodedPixelHeight: Int?

    /// Client-requested refresh target for the startup geometry contract.
    package var desktopGeometryRefreshTargetHz: Int?

    /// Creates a desktop-stream startup request.
    package init(
        startupRequestID: UUID = UUID(),
        scaleFactor: CGFloat?,
        displayWidth: Int,
        displayHeight: Int,
        targetFrameRate: Int,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        mode: MirageMedia.MirageDesktopStreamMode? = nil,
        cursorPresentation: MirageDesktopCursorPresentation? = nil,
        enteredBitrate: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageMedia.MirageStreamLatencyMode? = nil,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy? = nil,
        hostBufferDepth: MirageMedia.MirageHostBufferDepth? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        allowEncoderCatchUpQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageMedia.MirageAudioConfiguration? = nil,
        dataPort: UInt16? = nil,
        useHostResolution: Bool? = nil,
        compressionQualityCeiling: Float? = nil,
        mediaMaxPacketSize: Int? = nil,
        clientTransportPathKind: MirageCore.MirageNetworkPathKind? = nil,
        clientMediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil,
        clientPathSignature: String? = nil,
        clientPolicyPathKind: MirageCore.MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil,
        desktopGeometryContractID: UUID? = nil,
        desktopGeometrySceneIdentity: String? = nil,
        desktopGeometryDisplayPixelWidth: Int? = nil,
        desktopGeometryDisplayPixelHeight: Int? = nil,
        desktopGeometryEncodedPixelWidth: Int? = nil,
        desktopGeometryEncodedPixelHeight: Int? = nil,
        desktopGeometryRefreshTargetHz: Int? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.colorDepth = colorDepth
        self.mode = mode
        self.cursorPresentation = cursorPresentation
        self.enteredBitrate = enteredBitrate
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.hostBufferingPolicy = hostBufferingPolicy
        self.hostBufferDepth = hostBufferDepth
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.allowEncoderCatchUpQualityAdjustment = allowEncoderCatchUpQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.dataPort = dataPort
        self.useHostResolution = useHostResolution
        self.compressionQualityCeiling = compressionQualityCeiling
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.clientTransportPathKind = clientTransportPathKind
        self.clientMediaPathProfile = clientMediaPathProfile
        self.clientPathSignature = clientPathSignature
        self.clientPolicyPathKind = clientPolicyPathKind
        self.clientPolicyMediaPathProfile = clientPolicyMediaPathProfile
        self.desktopGeometryContractID = desktopGeometryContractID
        self.desktopGeometrySceneIdentity = desktopGeometrySceneIdentity
        self.desktopGeometryDisplayPixelWidth = desktopGeometryDisplayPixelWidth
        self.desktopGeometryDisplayPixelHeight = desktopGeometryDisplayPixelHeight
        self.desktopGeometryEncodedPixelWidth = desktopGeometryEncodedPixelWidth
        self.desktopGeometryEncodedPixelHeight = desktopGeometryEncodedPixelHeight
        self.desktopGeometryRefreshTargetHz = desktopGeometryRefreshTargetHz
    }

    /// Creates a copy of an existing desktop-start request with a new startup identity.
    package init(
        copying request: StartDesktopStreamMessage,
        startupRequestID: UUID = UUID(),
        targetFrameRate: Int? = nil
    ) {
        self.init(
            startupRequestID: startupRequestID,
            scaleFactor: request.scaleFactor,
            displayWidth: request.displayWidth,
            displayHeight: request.displayHeight,
            targetFrameRate: targetFrameRate ?? request.targetFrameRate,
            keyFrameInterval: request.keyFrameInterval,
            captureQueueDepth: request.captureQueueDepth,
            colorDepth: request.colorDepth,
            mode: request.mode,
            cursorPresentation: request.cursorPresentation,
            enteredBitrate: request.enteredBitrate,
            bitrate: request.bitrate,
            latencyMode: request.latencyMode,
            hostBufferingPolicy: request.hostBufferingPolicy,
            hostBufferDepth: request.hostBufferDepth,
            allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
            allowEncoderCatchUpQualityAdjustment: request.allowEncoderCatchUpQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: request.disableResolutionCap,
            streamScale: request.streamScale,
            audioConfiguration: request.audioConfiguration,
            dataPort: request.dataPort,
            useHostResolution: request.useHostResolution,
            compressionQualityCeiling: request.compressionQualityCeiling,
            mediaMaxPacketSize: request.mediaMaxPacketSize,
            clientTransportPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile,
            desktopGeometryContractID: request.desktopGeometryContractID,
            desktopGeometrySceneIdentity: request.desktopGeometrySceneIdentity,
            desktopGeometryDisplayPixelWidth: request.desktopGeometryDisplayPixelWidth,
            desktopGeometryDisplayPixelHeight: request.desktopGeometryDisplayPixelHeight,
            desktopGeometryEncodedPixelWidth: request.desktopGeometryEncodedPixelWidth,
            desktopGeometryEncodedPixelHeight: request.desktopGeometryEncodedPixelHeight,
            desktopGeometryRefreshTargetHz: request.desktopGeometryRefreshTargetHz
        )
        bitrateAdaptationCeiling = request.bitrateAdaptationCeiling
        encoderMaxWidth = request.encoderMaxWidth
        encoderMaxHeight = request.encoderMaxHeight
        upscalingMode = request.upscalingMode
        codec = request.codec
    }

    package var resolvedHostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy {
        hostBufferingPolicy ?? .freshestFrame
    }

    package var resolvedHostBufferDepth: MirageMedia.MirageHostBufferDepth {
        hostBufferDepth ?? .standard
    }
}
