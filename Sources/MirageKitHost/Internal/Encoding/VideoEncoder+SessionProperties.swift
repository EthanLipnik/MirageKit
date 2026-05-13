//
//  VideoEncoder+SessionProperties.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  VideoToolbox session creation and property helpers.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
extension VideoEncoder {
    /// Outcome from applying one VideoToolbox compression-session property.
    enum PropertyApplyOutcome: String {
        /// VideoToolbox accepted the property.
        case applied

        /// VideoToolbox reported the property is unsupported for this session.
        case unsupported

        /// VideoToolbox rejected the property for another reason.
        case failed
    }

    /// Accumulates VideoToolbox property-application results for diagnostics.
    struct SessionPolicyStatus {
        /// Property labels that were accepted.
        var applied: [String] = []

        /// Property labels that VideoToolbox reported as unsupported.
        var unsupported: [String] = []

        /// Property labels that failed unexpectedly.
        var failed: [String] = []

        mutating func record(_ property: String, outcome: PropertyApplyOutcome) {
            switch outcome {
            case .applied:
                applied.append(property)
            case .unsupported:
                unsupported.append(property)
            case .failed:
                failed.append(property)
            }
        }

        private func joined(_ values: [String]) -> String {
            if values.isEmpty { return "none" }
            return values.sorted().joined(separator: ",")
        }

        /// Comma-separated applied property labels.
        var appliedText: String { joined(applied) }

        /// Comma-separated unsupported property labels.
        var unsupportedText: String { joined(unsupported) }

        /// Comma-separated failed property labels.
        var failedText: String { joined(failed) }
    }

    /// Rate-control policy selected for low-latency HEVC/H.264 sessions.
    enum LowLatencyBitrateStrategy: String {
        /// Use VideoToolbox constant-bit-rate mode.
        case constantBitRate

        /// Use average bitrate only.
        case averageBitRateOnly

        /// Use average bitrate plus data-rate limits.
        case averageBitRateDataRateLimits

        /// Do not apply a low-latency bitrate override.
        case none
    }

    /// Applied low-latency bitrate strategy and optional data-rate window.
    struct LowLatencyBitrateResult {
        /// Selected VideoToolbox bitrate strategy.
        let strategy: LowLatencyBitrateStrategy

        /// Data-rate-limit window in seconds when that strategy is active.
        let windowSeconds: Double?
    }

    func frameDelayCount(for mode: MirageStreamLatencyMode) -> Int {
        switch mode {
        case .smoothest:
            2
        case .lowestLatency:
            0
        }
    }

    func applySessionLatencySettings(_ session: VTCompressionSession, logReason: String? = nil) {
        let mode = latencyMode
        let resolvedFrameDelayCount = frameDelayCount(for: mode)
        let applied = setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: resolvedFrameDelayCount)
        )
        guard let logReason else { return }
        let applyText = applied ? "applied" : "not-applied"
        MirageLogger
            .encoder(
                "Encoder latency profile: \(mode.displayName) (\(logReason), maxFrameDelay=\(resolvedFrameDelayCount), \(applyText))"
            )
    }

    func createSession(width: Int, height: Int) throws {
        // Enforce 16-byte alignment for HEVC hardware encoder compatibility.
        let width = max(16, width & ~15)
        let height = max(16, height & ~15)

        var session: VTCompressionSession?

        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary

        let codecType: CMVideoCodecType = switch codec {
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        case .proRes4444: kCMVideoCodecType_AppleProRes4444
        }

        let baseSpec = encoderSpecificationForCurrentTier

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: baseSpec as CFDictionary,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        while status != noErr {
            let fallbackPixelFormat: MiragePixelFormat? = switch activePixelFormat {
            case .xf44, .ayuv16:
                .p010
            case .p010,
                 .bgr10a2:
                .nv12
            case .bgra8,
                 .nv12:
                nil
            }
            guard let fallbackPixelFormat else { break }

            let previousPixelFormat = activePixelFormat
            activePixelFormat = fallbackPixelFormat
            let fallbackAttributes: CFDictionary = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary

            session = nil
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: codecType,
                encoderSpecification: baseSpec as CFDictionary,
                imageBufferAttributes: fallbackAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )

            if status == noErr {
                MirageLogger.encoder(
                    "\(previousPixelFormat.displayName) unsupported; using \(fallbackPixelFormat.displayName)"
                )
            }
        }

        guard status == noErr, let session else { throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }

        hardwareStatusRefreshAttempts = 0
        loadSupportedProperties(session)
        try configureSession(session, width: width, height: height)
        logHardwareStatus(session, reason: "session_create")
        compressionSession = session

        // Store dimensions for reset
        currentWidth = width
        currentHeight = height

        let formatLabel = switch activePixelFormat {
        case .xf44:
            "xf44"
        case .ayuv16:
            "AYUV16"
        case .p010:
            "P010"
        case .bgr10a2:
            "ARGB2101010"
        case .bgra8:
            "BGRA"
        case .nv12:
            "NV12"
        }
        MirageLogger.encoder("Encoder input format: \(formatLabel)")
        if let activeProfileLevel {
            MirageLogger.encoder("Encoder profile: \(hevcProfileName(for: activeProfileLevel))")
        }
        if latencyMode == .lowestLatency {
            if Self.shouldSuppressStandardLowLatencyRateControl(
                streamKind: streamKind,
                colorDepth: configuration.colorDepth,
                pixelFormat: activePixelFormat
            ) {
                MirageLogger.encoder(
                    "Encoder spec: standard low-latency rate control suppressed for \(streamKind.rawValue) \(width)x\(height)"
                )
            } else if Self.standardLowLatencyVTTuningEnabled(
                latencyMode: latencyMode,
                streamKind: streamKind,
                colorDepth: configuration.colorDepth,
                pixelFormat: activePixelFormat
            ) {
                MirageLogger.encoder(
                    "Encoder spec: standard low-latency rate control requested for \(streamKind.rawValue) \(width)x\(height)"
                )
            }
        }
    }

    /// Runs preheat and, if it fails, falls back pixel format and encoder spec tiers.
    /// Returns `true` if a working configuration was found.
    func preheatWithFallback() async throws -> Bool {
        let originalPixelFormat = activePixelFormat

        // Try each encoder spec tier (0 = default, 1 = no low-latency RC, 2 = no require HW)
        while activeEncoderSpecTier <= Self.maxEncoderSpecTier {
            // Try current pixel format first, then walk the format fallback chain
            if try await preheat() { return true }

            while true {
                let fallbackFormat: MiragePixelFormat? = switch activePixelFormat {
                case .xf44, .ayuv16: .p010
                case .p010, .bgr10a2: .nv12
                case .bgra8, .nv12: nil
                }
                guard let fallbackFormat else { break }

                let previousFormat = activePixelFormat
                activePixelFormat = fallbackFormat

                if let session = compressionSession {
                    VTCompressionSessionInvalidate(session)
                    compressionSession = nil
                }

                MirageLogger.encoder(
                    "Preheat fallback: \(previousFormat.displayName) → \(fallbackFormat.displayName) at \(currentWidth)x\(currentHeight) (spec tier \(activeEncoderSpecTier): \(encoderSpecTierLabel))"
                )

                do {
                    try createSession(width: currentWidth, height: currentHeight)
                } catch {
                    MirageLogger.error(.encoder, "Session creation failed for \(fallbackFormat.displayName): \(error)")
                    continue
                }

                if try await preheat() {
                    MirageLogger.encoder(
                        "Preheat succeeded after fallback to \(fallbackFormat.displayName) (spec tier \(activeEncoderSpecTier): \(encoderSpecTierLabel))"
                    )
                    return true
                }
            }

            // All pixel formats failed at this spec tier — try next tier
            activeEncoderSpecTier += 1
            guard activeEncoderSpecTier <= Self.maxEncoderSpecTier else { break }

            // Reset pixel format to original for next tier
            activePixelFormat = originalPixelFormat

            if let session = compressionSession {
                VTCompressionSessionInvalidate(session)
                compressionSession = nil
            }

            MirageLogger.encoder(
                "Preheat spec fallback: advancing to tier \(activeEncoderSpecTier) (\(encoderSpecTierLabel)) at \(currentWidth)x\(currentHeight)"
            )

            do {
                try createSession(width: currentWidth, height: currentHeight)
            } catch {
                MirageLogger.error(.encoder, "Session creation failed at spec tier \(activeEncoderSpecTier): \(error)")
                continue
            }
        }

        MirageLogger.error(.encoder, "Preheat failed on all pixel formats and encoder spec tiers")
        return false
    }

    /// Returns the encoder specification for the given tier.
    /// Tier 0: RequireHW + optional LowLatencyRC (current default)
    /// Tier 1: RequireHW only (no low-latency rate control)
    /// Tier 2: EnableHW only (no require, no low-latency)
    var encoderSpecificationForCurrentTier: [CFString: Any] {
        switch activeEncoderSpecTier {
        case 0:
            // Default: full spec with potential low-latency rate control
            return Self.encoderSpecification(
                latencyMode: latencyMode,
                streamKind: streamKind,
                codec: codec,
                colorDepth: configuration.colorDepth,
                pixelFormat: activePixelFormat
            )
        case 1:
            // Drop low-latency rate control, keep hardware requirement
            if codec == .proRes4444 {
                return [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            }
            return [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
        default:
            // Drop hardware requirement entirely
            return [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ]
        }
    }

    private static let encoderSpecTierLabels = [
        "hw-required+lowLatency",
        "hw-required",
        "hw-preferred",
    ]

    var encoderSpecTierLabel: String {
        Self.encoderSpecTierLabels[min(activeEncoderSpecTier, Self.encoderSpecTierLabels.count - 1)]
    }

    func qualitySettings(for quality: Float) -> QualitySettings {
        let clamped = max(0.02, min(compressionQualityCeiling, quality))
        let useQP = clamped < 0.98
        guard useQP else { return QualitySettings(quality: clamped, minQP: nil, maxQP: nil) }
        let rawMin = 10.0 + (1.0 - Double(clamped)) * 36.0
        let clampedMin = max(10, min(46, Int(rawMin.rounded())))
        let maxQP = min(51, clampedMin + 12)
        return QualitySettings(quality: clamped, minQP: clampedMin, maxQP: maxQP)
    }

    static func fourCCString(_ value: OSType) -> String {
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF) ?? UnicodeScalar(32),
            UnicodeScalar((value >> 16) & 0xFF) ?? UnicodeScalar(32),
            UnicodeScalar((value >> 8) & 0xFF) ?? UnicodeScalar(32),
            UnicodeScalar(value & 0xFF) ?? UnicodeScalar(32),
        ]
        return String(scalars.map { Character($0) })
    }
}

#endif
