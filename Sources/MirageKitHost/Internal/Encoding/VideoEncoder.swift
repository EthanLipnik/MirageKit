//
//  VideoEncoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if os(macOS)

/// Hardware-accelerated video encoder using VideoToolbox (HEVC or ProRes)
actor VideoEncoder {
    /// Logical stream family using this encoder.
    enum StreamKind: String {
        /// Individual application window stream.
        case window

        /// Desktop capture stream.
        case desktop

        /// App-provided custom stream.
        case custom

        /// Composited app-atlas stream containing multiple windows.
        case appAtlas
    }

    /// Runtime VideoToolbox and color-pipeline state reported to clients for diagnostics.
    struct RuntimeValidationSnapshot {
        /// Pixel format requested for encoder input.
        let pixelFormat: MirageMedia.MiragePixelFormat

        /// VideoToolbox profile name observed for the active session.
        let profileName: String?

        /// Whether VideoToolbox reports hardware acceleration.
        let usingHardwareEncoder: Bool?

        /// Registry ID for the GPU backing the encoder, when reported.
        let encoderGPURegistryID: UInt64?

        /// Encoder color primaries attachment.
        let colorPrimaries: String?

        /// Encoder transfer-function attachment.
        let transferFunction: String?

        /// Encoder YCbCr matrix attachment.
        let yCbCrMatrix: String?

        /// Chroma sampling parsed from the encoded bitstream.
        let encodedChromaSampling: MirageMedia.MirageStreamChromaSampling?

        /// Whether 10-bit Display P3 output passed runtime validation.
        let tenBitDisplayP3Validated: Bool

        /// Whether Ultra 4:4:4 output passed runtime validation.
        let ultra444Validated: Bool
    }

    /// Timing captured for one VideoToolbox output callback.
    struct EncodedFrameTiming: Sendable, Equatable {
        let frameNumber: UInt64
        let encodeDurationMs: Double
        let captureToCallbackMs: Double
        let captureDirtyPercentage: Float
        let captureIsIdleFrame: Bool
    }

    var compressionSession: VTCompressionSession?
    var configuration: MirageEncoderConfiguration
    let codec: MirageMedia.MirageVideoCodec
    let latencyMode: MirageMedia.MirageStreamLatencyMode
    let streamKind: StreamKind
    let mediaPathProfile: MirageMedia.MirageMediaPathProfile

    var isProRes: Bool { codec == .proRes4444 }
    var activePixelFormat: MirageMedia.MiragePixelFormat
    var activeProfileLevel: CFString?
    var lastEncodedChromaSampling: MirageMedia.MirageStreamChromaSampling?
    var usingHardwareEncoder: Bool?
    var encoderGPURegistryID: UInt64?
    var hardwareStatusRefreshAttempts: Int = 0
    let maxHardwareStatusRefreshAttempts: Int = 4
    var supportedPropertyKeys: Set<CFString> = []
    var didQuerySupportedProperties = false
    var loggedUnsupportedKeys: Set<CFString> = []
    var appliedPropertyKeys: Set<CFString> = []
    var didLogPixelFormat = false
    var baseQuality: Float
    var qualityOverrideActive = false
    let compressionQualityCeiling: Float = 0.94
    let performanceTracker = EncodePerformanceTracker()
    let encodedOutputTelemetry = EncodedOutputTelemetryTracker()
    var maximizePowerEfficiencyEnabled: Bool

    var isEncoding = false
    var frameNumber: UInt64 = 0
    var encodedFrameHandler:
        (@Sendable (Data, Bool, CMTime, EncodedFrameTiming, @escaping @Sendable () -> Void) -> Void)?
    var frameCompletionHandler: (@Sendable () -> Void)?
    var forceNextKeyframe = false
    var isUpdatingDimensions = false

    /// Current session dimensions (stored for reset)
    var currentWidth: Int = 0
    var currentHeight: Int = 0

    nonisolated(unsafe) var encoderInFlightLimit: Int
    nonisolated(unsafe) var encoderInFlightCount: Int = 0
    let encoderInFlightLock = NSLock()
    nonisolated(unsafe) var lastBitstreamFailureLogTime: CFAbsoluteTime = 0
    let bitstreamFailureLogLock = NSLock()
    nonisolated(unsafe) var callbackFailureCount: UInt64 = 0
    nonisolated(unsafe) var lastCallbackFailureLogTime: CFAbsoluteTime = 0

    /// Current encoder spec tier (0 = default, higher = more permissive).
    /// Tier 0: RequireHW + LowLatencyRC
    /// Tier 1: RequireHW only (no low-latency rate control)
    /// Tier 2: EnableHW only (no require, no low-latency)
    var activeEncoderSpecTier: Int = 0
    static let maxEncoderSpecTier = 2

    /// Session generation checked by VideoToolbox callbacks during dimension transitions.
    /// `nonisolated(unsafe)` is required because callbacks arrive off the actor thread.
    nonisolated(unsafe) var sessionVersion: UInt64 = 0
    static let bitstreamFailureLogCooldown: CFAbsoluteTime = 1.0

    init(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency,
        streamKind: StreamKind = .window,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        inFlightLimit: Int? = nil,
        maximizePowerEfficiencyEnabled: Bool = false
    ) {
        self.configuration = configuration
        codec = configuration.codec
        self.latencyMode = latencyMode
        self.streamKind = streamKind
        self.mediaPathProfile = mediaPathProfile
        self.maximizePowerEfficiencyEnabled = maximizePowerEfficiencyEnabled
        activePixelFormat = configuration.pixelFormat
        let defaultLimit = configuration.targetFrameRate >= 120 ? 2 : 1
        encoderInFlightLimit = max(1, inFlightLimit ?? defaultLimit)
        baseQuality = configuration.codec == .proRes4444
            ? 1.0
            : min(configuration.frameQuality, compressionQualityCeiling)
    }

    /// Core Video pixel format used when creating the compression session.
    var pixelFormatType: OSType {
        switch activePixelFormat {
        case .xf44, .ayuv16:
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .p010:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgr10a2:
            kCVPixelFormatType_ARGB2101010LEPacked
        case .bgra8:
            kCVPixelFormatType_32BGRA
        case .nv12:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    /// HEVC profile candidates attempted for the active pixel format.
    var requestedProfileLevels: [CFString] {
        Self.requestedProfileLevels(for: activePixelFormat)
    }

    /// HEVC profile candidates ordered from most specific to most compatible.
    static func requestedProfileLevels(for pixelFormat: MirageMedia.MiragePixelFormat) -> [CFString] {
        switch pixelFormat {
        case .xf44, .ayuv16:
            []
        case .bgr10a2:
            [
                kVTProfileLevel_HEVC_Main42210_AutoLevel,
                kVTProfileLevel_HEVC_Main10_AutoLevel,
            ]
        case .p010:
            [kVTProfileLevel_HEVC_Main10_AutoLevel]
        case .bgra8,
             .nv12:
            [kVTProfileLevel_HEVC_Main_AutoLevel]
        }
    }

    /// VideoToolbox quality and quantizer bounds for one encoder update.
    struct QualitySettings {
        /// VideoToolbox quality scalar.
        let quality: Float

        /// Lower quantizer bound, when enforced.
        let minQP: Int?

        /// Upper quantizer bound, when enforced.
        let maxQP: Int?
    }

    // Bitrate targets are enforced via VideoToolbox data rate limits.
    // Encoder quality and QP bounds control compression within that target.
}

/// Thread-safe encode timing tracker for recent samples
final class EncodePerformanceTracker: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Double] = []
    let maxSamples: Int = 30
}

/// Info passed through the encode callback
final class EncodeInfo: @unchecked Sendable {
    let frameNumber: UInt64
    let handler:
        (@Sendable (Data, Bool, CMTime, VideoEncoder.EncodedFrameTiming, @escaping @Sendable () -> Void) -> Void)?
    let encodeStartTime: CFAbsoluteTime
    let sessionVersion: UInt64
    let captureTime: CFAbsoluteTime
    let captureDirtyPercentage: Float
    let captureIsIdleFrame: Bool
    let performanceTracker: EncodePerformanceTracker?
    let encodedOutputTelemetry: EncodedOutputTelemetryTracker?
    let completion: (@Sendable () -> Void)?
    let isProRes: Bool
    /// Retains the originating capture sample buffer until VT finishes with the frame.
    let retainedSampleBuffer: CMSampleBuffer?
    /// Returns the encoder's current compression-session generation.
    let currentSessionVersion: () -> UInt64

    init(
        frameNumber: UInt64,
        handler:
            (@Sendable (Data, Bool, CMTime, VideoEncoder.EncodedFrameTiming, @escaping @Sendable () -> Void) -> Void)?,
        encodeStartTime: CFAbsoluteTime = 0,
        sessionVersion: UInt64 = 0,
        captureTime: CFAbsoluteTime = 0,
        captureDirtyPercentage: Float = 100,
        captureIsIdleFrame: Bool = false,
        performanceTracker: EncodePerformanceTracker?,
        encodedOutputTelemetry: EncodedOutputTelemetryTracker?,
        completion: (@Sendable () -> Void)?,
        isProRes: Bool = false,
        retainedSampleBuffer: CMSampleBuffer? = nil,
        currentSessionVersion: @escaping () -> UInt64
    ) {
        self.frameNumber = frameNumber
        self.handler = handler
        self.encodeStartTime = encodeStartTime
        self.sessionVersion = sessionVersion
        self.captureTime = captureTime
        self.captureDirtyPercentage = captureDirtyPercentage
        self.captureIsIdleFrame = captureIsIdleFrame
        self.performanceTracker = performanceTracker
        self.encodedOutputTelemetry = encodedOutputTelemetry
        self.completion = completion
        self.isProRes = isProRes
        self.retainedSampleBuffer = retainedSampleBuffer
        self.currentSessionVersion = currentSessionVersion
    }
}

#endif
