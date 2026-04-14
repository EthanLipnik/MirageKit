//
//  VideoEncoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)

/// Hardware-accelerated video encoder using VideoToolbox (HEVC or ProRes)
actor VideoEncoder {
    enum StreamKind: String, Sendable {
        case window
        case desktop
    }

    struct RuntimeValidationSnapshot: Sendable {
        let pixelFormat: MiragePixelFormat
        let profileName: String?
        let usingHardwareEncoder: Bool?
        let encoderGPURegistryID: UInt64?
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
        let encodedChromaSampling: MirageStreamChromaSampling?
        let tenBitDisplayP3Validated: Bool
        let ultra444Validated: Bool
    }

    var compressionSession: VTCompressionSession?
    var configuration: MirageEncoderConfiguration
    let codec: MirageVideoCodec
    let latencyMode: MirageStreamLatencyMode
    let performanceMode: MirageStreamPerformanceMode
    let streamKind: StreamKind

    var isProRes: Bool { codec == .proRes4444 }
    var autoTypingBurstLowLatencyActive = false
    var activePixelFormat: MiragePixelFormat
    var activeProfileLevel: CFString?
    var lastEncodedChromaSampling: MirageStreamChromaSampling?
    var usingHardwareEncoder: Bool?
    var encoderGPURegistryID: UInt64?
    var hardwareStatusRefreshAttempts: Int = 0
    let maxHardwareStatusRefreshAttempts: Int = 4
    var supportedPropertyKeys: Set<CFString> = []
    var didQuerySupportedProperties = false
    var loggedUnsupportedKeys: Set<CFString> = []
    var didLogPixelFormat = false
    var baseQuality: Float
    var qualityOverrideActive = false
    var gameModeEmergencyQualityClampsEnabled = false
    let compressionQualityCeiling: Float = 0.94
    let performanceTracker = EncodePerformanceTracker()
    var maximizePowerEfficiencyEnabled: Bool

    var isEncoding = false
    var frameNumber: UInt64 = 0
    var encodedFrameHandler: (@Sendable (Data, Bool, CMTime) -> Void)?
    var frameCompletionHandler: (@Sendable () -> Void)?
    var forceNextKeyframe = false
    var isUpdatingDimensions = false

    /// Current session dimensions (stored for reset)
    var currentWidth: Int = 0
    var currentHeight: Int = 0

    nonisolated(unsafe) var encoderInFlightLimit: Int
    nonisolated(unsafe) var encoderInFlightCount: Int = 0
    nonisolated(unsafe) let encoderInFlightLock = NSLock()
    nonisolated(unsafe) var lastBitstreamFailureLogTime: CFAbsoluteTime = 0
    nonisolated(unsafe) let bitstreamFailureLogLock = NSLock()
    nonisolated(unsafe) var callbackFailureCount: UInt64 = 0
    nonisolated(unsafe) var lastCallbackFailureLogTime: CFAbsoluteTime = 0

    /// Current encoder spec tier (0 = default, higher = more permissive).
    /// Tier 0: RequireHW + LowLatencyRC
    /// Tier 1: RequireHW only (no low-latency rate control)
    /// Tier 2: EnableHW only (no require, no low-latency)
    var activeEncoderSpecTier: Int = 0
    static let maxEncoderSpecTier = 2

    /// Session version counter - incremented on each dimension change
    /// Used to discard frames from old sessions during transitions
    /// nonisolated(unsafe) because it's accessed from VT callback (different thread)
    /// and needs to be compared atomically
    nonisolated(unsafe) var sessionVersion: UInt64 = 0
    static let bitstreamFailureLogCooldown: CFAbsoluteTime = 1.0

    init(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        performanceMode: MirageStreamPerformanceMode = .standard,
        streamKind: StreamKind = .window,
        inFlightLimit: Int? = nil,
        maximizePowerEfficiencyEnabled: Bool = false
    ) {
        self.configuration = configuration
        self.codec = configuration.codec
        self.latencyMode = latencyMode
        self.performanceMode = performanceMode
        self.streamKind = streamKind
        self.maximizePowerEfficiencyEnabled = maximizePowerEfficiencyEnabled
        activePixelFormat = configuration.pixelFormat
        let defaultLimit = configuration.targetFrameRate >= 120 ? 2 : 1
        encoderInFlightLimit = max(1, inFlightLimit ?? defaultLimit)
        baseQuality = configuration.codec == .proRes4444
            ? 1.0
            : min(configuration.frameQuality, compressionQualityCeiling)
    }

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

    var requestedProfileLevels: [CFString] {
        Self.requestedProfileLevels(for: activePixelFormat)
    }

    static func requestedProfileLevels(for pixelFormat: MiragePixelFormat) -> [CFString] {
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

    static func shouldApplyQPClamps(
        for performanceMode: MirageStreamPerformanceMode,
        gameModeEmergencyQualityClampsEnabled: Bool
    ) -> Bool {
        _ = performanceMode
        _ = gameModeEmergencyQualityClampsEnabled
        // Keep QP clamps active in all modes. On some Macs VT ignores `Quality`,
        // so QP bounds are the only reliable way to enforce throughput targets.
        return true
    }

    // Create the compression session

    struct QualitySettings {
        let quality: Float
        let minQP: Int?
        let maxQP: Int?
    }

    // Pre-heat the encoder with dummy frames to eliminate warm-up latency
    // VideoToolbox hardware encoders need ~5-10 frames to reach steady-state performance
    // Without pre-heating, first real frames take 70-80ms instead of 3-4ms

    // Start encoding with a frame handler

    // Stop encoding

    // Encode a frame

    // Update quality dynamically (0.0 to 1.0)
    // Lower quality reduces frame size during throughput pressure.

    // Bitrate targets are enforced via VideoToolbox data rate limits.
    // Encoder quality and QP bounds control compression within that target.

    // Update encoder dimensions (requires session recreation)

    // Force a keyframe on next encode

    // Get the current average encode time (ms) from recent samples.

    // Flush all pending frames from the encoder pipeline and force next keyframe.
    // This ensures the next frame captured will be encoded as a keyframe immediately,
    // without waiting for any in-flight frames to complete first.

    // Reset the encoder session to recover from stuck state
    // This invalidates the current session and creates a new one
    // Forces a keyframe on the next encode

    // Extract VPS, SPS, PPS from format description and format with Annex B start codes
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
    let handler: (@Sendable (Data, Bool, CMTime) -> Void)?
    let encodeStartTime: CFAbsoluteTime
    let sessionVersion: UInt64
    let performanceTracker: EncodePerformanceTracker?
    let completion: (@Sendable () -> Void)?
    let isProRes: Bool
    /// Closure to check current session version (captures encoder reference)
    let getCurrentVersion: () -> UInt64

    init(
        frameNumber: UInt64,
        handler: (@Sendable (Data, Bool, CMTime) -> Void)?,
        encodeStartTime: CFAbsoluteTime = 0,
        sessionVersion: UInt64 = 0,
        performanceTracker: EncodePerformanceTracker?,
        completion: (@Sendable () -> Void)?,
        isProRes: Bool = false,
        getCurrentVersion: @escaping () -> UInt64
    ) {
        self.frameNumber = frameNumber
        self.handler = handler
        self.encodeStartTime = encodeStartTime
        self.sessionVersion = sessionVersion
        self.performanceTracker = performanceTracker
        self.completion = completion
        self.isProRes = isProRes
        self.getCurrentVersion = getCurrentVersion
    }

    /// Check if this frame's session is still current
    /// Returns false if a dimension change occurred since this frame was queued
    var isSessionCurrent: Bool { sessionVersion == getCurrentVersion() }
}

#endif
