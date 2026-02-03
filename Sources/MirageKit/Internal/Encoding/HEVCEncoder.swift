//
//  HEVCEncoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if os(macOS)

/// Hardware-accelerated HEVC encoder using VideoToolbox
actor HEVCEncoder {
    var compressionSession: VTCompressionSession?
    let configuration: MirageEncoderConfiguration
    let latencyMode: MirageStreamLatencyMode
    var activePixelFormat: MiragePixelFormat
    var supportedPropertyKeys: Set<CFString> = []
    var didQuerySupportedProperties = false
    var loggedUnsupportedKeys: Set<CFString> = []
    var didLogPixelFormat = false
    var baseQuality: Float
    var qualityOverrideActive = false
    let performanceTracker = EncodePerformanceTracker()

    var isEncoding = false
    var frameNumber: UInt64 = 0
    var encodedFrameHandler: ((Data, Bool, CMTime) -> Void)?
    var frameCompletionHandler: (() -> Void)?
    var forceNextKeyframe = false
    var isUpdatingDimensions = false

    /// Current session dimensions (stored for reset)
    var currentWidth: Int = 0
    var currentHeight: Int = 0

    nonisolated(unsafe) var encoderInFlightLimit: Int
    nonisolated(unsafe) var encoderInFlightCount: Int = 0
    nonisolated(unsafe) let encoderInFlightLock = NSLock()

    /// Session version counter - incremented on each dimension change
    /// Used to discard frames from old sessions during transitions
    /// nonisolated(unsafe) because it's accessed from VT callback (different thread)
    /// and needs to be compared atomically
    nonisolated(unsafe) var sessionVersion: UInt64 = 0

    init(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode = .balanced,
        inFlightLimit: Int? = nil
    ) {
        self.configuration = configuration
        self.latencyMode = latencyMode
        activePixelFormat = configuration.pixelFormat
        let defaultLimit = configuration.targetFrameRate >= 120 ? 2 : 1
        encoderInFlightLimit = max(1, inFlightLimit ?? defaultLimit)
        baseQuality = configuration.frameQuality
    }

    var pixelFormatType: OSType {
        switch activePixelFormat {
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

    var profileLevel: CFString {
        switch activePixelFormat {
        case .bgr10a2,
             .p010:
            kVTProfileLevel_HEVC_Main10_AutoLevel
        case .bgra8,
             .nv12:
            kVTProfileLevel_HEVC_Main_AutoLevel
        }
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
    let handler: ((Data, Bool, CMTime) -> Void)?
    let encodeStartTime: CFAbsoluteTime
    let sessionVersion: UInt64
    let performanceTracker: EncodePerformanceTracker?
    let completion: (() -> Void)?
    /// Closure to check current session version (captures encoder reference)
    let getCurrentVersion: () -> UInt64

    init(
        frameNumber: UInt64,
        handler: ((Data, Bool, CMTime) -> Void)?,
        encodeStartTime: CFAbsoluteTime = 0,
        sessionVersion: UInt64 = 0,
        performanceTracker: EncodePerformanceTracker?,
        completion: (() -> Void)?,
        getCurrentVersion: @escaping () -> UInt64
    ) {
        self.frameNumber = frameNumber
        self.handler = handler
        self.encodeStartTime = encodeStartTime
        self.sessionVersion = sessionVersion
        self.performanceTracker = performanceTracker
        self.completion = completion
        self.getCurrentVersion = getCurrentVersion
    }

    /// Check if this frame's session is still current
    /// Returns false if a dimension change occurred since this frame was queued
    var isSessionCurrent: Bool { sessionVersion == getCurrentVersion() }
}

#endif
