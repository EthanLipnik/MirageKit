//
//  VideoEncoder+Session.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
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
import Foundation
import VideoToolbox

#if os(macOS)
import ScreenCaptureKit

extension VideoEncoder {
    func applyProfileLevel(_ session: VTCompressionSession) {
        let key = kVTCompressionPropertyKey_ProfileLevel
        activeProfileLevel = nil
        if didQuerySupportedProperties, !supportedPropertyKeys.contains(key) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key)")
            }
            return
        }

        let candidates = requestedProfileLevels
        guard !candidates.isEmpty else {
            MirageLogger.encoder("Encoder profile: automatic")
            return
        }
        for (index, profile) in candidates.enumerated() {
            let status = VTSessionSetProperty(session, key: key, value: profile)
            guard status == noErr else {
                let keyName = key as String
                let profileName = hevcProfileName(for: profile)
                MirageLogger.error(
                    .encoder,
                    "VTSessionSetProperty \(keyName) failed for \(profileName): \(status)"
                )
                continue
            }

            activeProfileLevel = profile
            if index > 0, let preferredProfile = candidates.first {
                let preferred = hevcProfileName(for: preferredProfile)
                let fallback = hevcProfileName(for: profile)
                MirageLogger.encoder("Encoder profile fallback: \(preferred) -> \(fallback)")
            }
            return
        }
    }

    func applyQualitySettings(_ session: VTCompressionSession, quality: Float, log: Bool) {
        let settings = qualitySettings(for: quality)
        let qualityApplied = setProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: settings.quality)
        )
        var minQPApplied = false
        var maxQPApplied = false
        // Keep QP clamps active in all modes. On some Macs VT ignores `Quality`,
        // so QP bounds are the only reliable way to enforce throughput targets.
        if let minQP = settings.minQP {
            minQPApplied = setProperty(
                session,
                key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                value: NSNumber(value: minQP)
            )
        }
        if let maxQP = settings.maxQP {
            maxQPApplied = setProperty(
                session,
                key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                value: NSNumber(value: maxQP)
            )
        }
        guard log else { return }
        let qualityText = settings.quality.formatted(.number.precision(.fractionLength(2)))
        let qualityState = qualityApplied ? "applied" : "not-applied"
        if let minQP = settings.minQP, let maxQP = settings.maxQP {
            let qpState = (minQPApplied && maxQPApplied) ? "applied" : "not-applied"
            MirageLogger.encoder("Encoder quality: \(qualityText) (\(qualityState)), QP \(minQP)-\(maxQP) (\(qpState))")
        } else {
            MirageLogger.encoder("Encoder quality: \(qualityText) (\(qualityState))")
        }
    }

    private func applyBitrateSettings(_ session: VTCompressionSession) {
        guard let targetBitrate = configuration.bitrate, targetBitrate > 0 else {
            encodedOutputTelemetry.updateRateControl(
                requestedBitrateBps: nil,
                strategy: .none,
                rateLimit: nil
            )
            return
        }
        let rateLimit = Self.dataRateLimit(
            targetBitrateBps: targetBitrate,
            targetFrameRate: configuration.targetFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        _ = clearPropertyIfPresent(session, key: kVTCompressionPropertyKey_ConstantBitRate)
        let averageApplied = setProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: targetBitrate)
        )
        let rateLimits: [NSNumber] = [
            NSNumber(value: rateLimit.bytes),
            NSNumber(value: rateLimit.windowSeconds),
        ]
        let rateLimitApplied = setProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: rateLimits as CFArray
        )
        let strategy: MirageMedia.MirageEncoderRateControlStrategy = (averageApplied && rateLimitApplied)
            ? .averageBitRateDataRateLimits
            : .none
        encodedOutputTelemetry.updateRateControl(
            requestedBitrateBps: targetBitrate,
            strategy: strategy,
            rateLimit: rateLimitApplied ? rateLimit : nil
        )

        let limitMB = Double(rateLimit.bytes) / 1_000_000.0
        let limitText = limitMB.formatted(.number.precision(.fractionLength(2)))
        let windowText = rateLimit.windowSeconds.formatted(.number.precision(.fractionLength(2)))
        MirageLogger
            .encoder(
                "Encoder bitrate target: \(mirageFormattedMegabitRate(targetBitrate)) (strategy \(strategy.rawValue), rate limit \(limitText) MB/\(windowText)s)"
            )
    }

    private func applyLowLatencyBitrateSettings(
        _ session: VTCompressionSession,
        targetFrameRate: Int,
        status: inout SessionPolicyStatus
    ) -> LowLatencyBitrateResult {
        guard let targetBitrate = configuration.bitrate, targetBitrate > 0 else {
            encodedOutputTelemetry.updateRateControl(
                requestedBitrateBps: nil,
                strategy: .none,
                rateLimit: nil
            )
            return LowLatencyBitrateResult(strategy: .none, windowSeconds: nil)
        }

        _ = clearPropertyIfPresentTracked(
            session,
            key: kVTCompressionPropertyKey_ConstantBitRate,
            propertyName: "clearConstantBitRate",
            status: &status
        )
        let averageBitRateApplied = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: targetBitrate),
            propertyName: "averageBitRate",
            status: &status
        )
        let usesConstrainedDataRate = Self.lowLatencyUsesDataRateLimits(mediaPathProfile: mediaPathProfile)
        let strategy: LowLatencyBitrateStrategy
        let rateLimitForTelemetry: (bytes: Int, windowSeconds: Double)?
        if usesConstrainedDataRate {
            let rateLimit = Self.dataRateLimit(
                targetBitrateBps: targetBitrate,
                targetFrameRate: max(1, targetFrameRate),
                mediaPathProfile: mediaPathProfile
            )
            let rateLimits: [NSNumber] = [
                NSNumber(value: rateLimit.bytes),
                NSNumber(value: rateLimit.windowSeconds),
            ]
            let rateLimitApplied = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: rateLimits as CFArray,
                propertyName: "dataRateLimits",
                status: &status
            )
            if averageBitRateApplied, rateLimitApplied {
                strategy = .averageBitRateDataRateLimits
                rateLimitForTelemetry = rateLimit
            } else if averageBitRateApplied {
                strategy = .averageBitRateOnly
                rateLimitForTelemetry = nil
            } else {
                strategy = .none
                rateLimitForTelemetry = rateLimitApplied ? rateLimit : nil
            }
        } else {
            _ = clearPropertyIfPresentTracked(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                propertyName: "clearDataRateLimits",
                status: &status
            )
            strategy = averageBitRateApplied ? .averageBitRateOnly : .none
            rateLimitForTelemetry = nil
        }

        encodedOutputTelemetry.updateRateControl(
            requestedBitrateBps: targetBitrate,
            strategy: strategy.publicStrategy,
            rateLimit: rateLimitForTelemetry
        )

        if strategy == .averageBitRateDataRateLimits, let rateLimitForTelemetry {
            let limitMB = Double(rateLimitForTelemetry.bytes) / 1_000_000.0
            let limitText = limitMB.formatted(.number.precision(.fractionLength(2)))
            let windowText = rateLimitForTelemetry.windowSeconds.formatted(.number.precision(.fractionLength(4)))
            MirageLogger
                .encoder(
                    "Encoder bitrate target: \(mirageFormattedMegabitRate(targetBitrate)) (strategy \(strategy.rawValue), rate limit \(limitText) MB/\(windowText)s)"
                )
        } else {
            MirageLogger
                .encoder(
                    "Encoder bitrate target: \(mirageFormattedMegabitRate(targetBitrate)) (strategy \(strategy.rawValue))"
                )
        }
        return LowLatencyBitrateResult(strategy: strategy, windowSeconds: rateLimitForTelemetry?.windowSeconds)
    }

    func applyBitrateSettingsToActiveSession() {
        guard let session = compressionSession else { return }
        if !isProRes, Self.standardLowLatencyVTTuningEnabled(
            latencyMode: latencyMode,
            streamKind: streamKind,
            colorDepth: configuration.colorDepth,
            pixelFormat: activePixelFormat,
            mediaPathProfile: mediaPathProfile
        ) {
            var status = SessionPolicyStatus()
            _ = applyLowLatencyBitrateSettings(
                session,
                targetFrameRate: configuration.targetFrameRate,
                status: &status
            )
        } else {
            applyBitrateSettings(session)
        }
    }

    static func dataRateLimit(
        targetBitrateBps: Int,
        targetFrameRate: Int,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    ) -> (bytes: Int, windowSeconds: Double) {
        let clampedFrameRate = max(1, targetFrameRate)
        let windowSeconds: Double
        if mediaPathProfile.usesAwdlRadioPolicy {
            windowSeconds = MirageAwdlMediaController.videoToolboxDataRateWindowSeconds(
                targetFrameRate: clampedFrameRate
            )
        } else {
            windowSeconds = min(0.05, 2.0 / Double(clampedFrameRate))
        }
        let bytesPerSecond = max(1.0, Double(targetBitrateBps) / 8.0)
        let bytes = max(1, Int((bytesPerSecond * windowSeconds).rounded()))
        return (bytes: bytes, windowSeconds: windowSeconds)
    }

    static func lowLatencyUsesDataRateLimits(mediaPathProfile: MirageMedia.MirageMediaPathProfile) -> Bool {
        mediaPathProfile.usesAwdlRadioPolicy || mediaPathProfile == .localWiFi
    }

    func configureSession(
        _ session: VTCompressionSession,
        width: Int,
        height: Int
    ) throws {
        if isProRes {
            try configureProResSession(session, width: width, height: height)
            return
        }

        let resolvedLatencyMode = latencyMode
        let standardLowLatencyTuningEnabled = Self.standardLowLatencyVTTuningEnabled(
            latencyMode: resolvedLatencyMode,
            streamKind: streamKind,
            colorDepth: configuration.colorDepth,
            pixelFormat: activePixelFormat,
            mediaPathProfile: mediaPathProfile
        )
        let suppressedThroughputTuningEnabled = Self.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            latencyMode: resolvedLatencyMode,
            streamKind: streamKind,
            colorDepth: configuration.colorDepth,
            pixelFormat: activePixelFormat,
            mediaPathProfile: mediaPathProfile
        )
        var standardLowLatencyStatus = SessionPolicyStatus()

        // Real-time encoding.
        _ = setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Disable B-frames so both latency modes keep predictable frame dependencies.
        _ = setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Configure encoder buffering policy from the active latency profile.
        applySessionLatencySettings(session)

        // Frame rate.
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: configuration.targetFrameRate as CFNumber
        )

        if standardLowLatencyTuningEnabled || suppressedThroughputTuningEnabled {
            applyStandardLowLatencyThroughputSettings(
                session,
                usesSunshineRateControl: standardLowLatencyTuningEnabled,
                status: &standardLowLatencyStatus
            )
        } else {
            let powerPreferenceApplied = applyMaximizePowerEfficiency(session)
            MirageLogger.encoder(
                "event=encoder_power_preference maximizePowerEfficiency=\(maximizePowerEfficiencyEnabled)(\(powerPreferenceApplied))"
            )
        }

        // Keyframe interval
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: configuration.keyFrameInterval as CFNumber
        )
        let intervalSeconds = max(
            1.0,
            Double(configuration.keyFrameInterval) / Double(max(1, configuration.targetFrameRate))
        )
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: intervalSeconds as CFNumber
        )

        // Profile selection. ARGB2101010 prefers Main42210 and falls back to Main10.
        applyProfileLevel(session)

        // Prioritize readability over encoder speed on AWDL display paths.
        let prioritizeSpeedOverQuality = Self.prioritizeEncodingSpeedOverQuality(
            mediaPathProfile: mediaPathProfile
        )
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: prioritizeSpeedOverQuality ? kCFBooleanTrue : kCFBooleanFalse
        )
        MirageLogger.encoder("Encoder speed-over-quality preference: \(prioritizeSpeedOverQuality)")

        // Apply base quality setting - lower values reduce size for all frames
        let requestedQuality = configuration.frameQuality
        baseQuality = min(requestedQuality, compressionQualityCeiling)
        if requestedQuality > compressionQualityCeiling {
            let requestedText = requestedQuality.formatted(.number.precision(.fractionLength(2)))
            let capText = compressionQualityCeiling.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.encoder("Quality cap applied: requested \(requestedText), using \(capText)")
        }
        applyQualitySettings(session, quality: baseQuality, log: true)

        // Apply bitrate policy.
        if standardLowLatencyTuningEnabled {
            let lowLatencyTargetFrameRate = max(1, configuration.targetFrameRate)
            let bitrateResult = applyLowLatencyBitrateSettings(
                session,
                targetFrameRate: lowLatencyTargetFrameRate,
                status: &standardLowLatencyStatus
            )
            let windowText = if let windowSeconds = bitrateResult.windowSeconds {
                windowSeconds.formatted(.number.precision(.fractionLength(4)))
            } else {
                "n/a"
            }
            MirageLogger.encoder(
                "event=encoder_effective_policy mode=standardLowLatency strategy=\(bitrateResult.strategy.rawValue) " +
                    "targetFPS=\(lowLatencyTargetFrameRate) dataRateWindow=\(windowText)s"
            )
        } else {
            // Apply bitrate caps to keep encode time bounded for motion-heavy scenes.
            applyBitrateSettings(session)
        }
        if standardLowLatencyTuningEnabled || suppressedThroughputTuningEnabled {
            MirageLogger.encoder(
                "event=encoder_standard_low_latency_tuning applied=\(standardLowLatencyStatus.appliedText) " +
                    "suppressedRateControl=\(suppressedThroughputTuningEnabled) " +
                    "unsupported=\(standardLowLatencyStatus.unsupportedText) " +
                    "failed=\(standardLowLatencyStatus.failedText)"
            )
        }

        applyColorSpaceSettings(session)

        // Prepare for encoding
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func configureProResSession(
        _ session: VTCompressionSession,
        width: Int,
        height: Int
    ) throws {
        // Real-time encoding
        _ = setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // No B-frames
        _ = setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Frame rate
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: configuration.targetFrameRate as CFNumber
        )

        // Keyframe interval (ProRes is all-intra, but set for consistency)
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: configuration.keyFrameInterval as CFNumber
        )

        // Quality 1.0 for near-lossless ProRes
        baseQuality = 1.0
        _ = setProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: 1.0)
        )

        applyColorSpaceSettings(session)

        MirageLogger.encoder("ProRes 4444 session configured at \(width)x\(height)")

        // Prepare for encoding
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Applies VideoToolbox color metadata for the configured stream color space.
    private func applyColorSpaceSettings(_ session: VTCompressionSession) {
        switch configuration.colorSpace {
        case .displayP3:
            _ = setProperty(
                session,
                key: kVTCompressionPropertyKey_ColorPrimaries,
                value: kCMFormatDescriptionColorPrimaries_P3_D65
            )
            _ = setProperty(
                session,
                key: kVTCompressionPropertyKey_TransferFunction,
                value: kCMFormatDescriptionTransferFunction_sRGB
            )
            _ = setProperty(
                session,
                key: kVTCompressionPropertyKey_YCbCrMatrix,
                value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            )
        case .sRGB:
            break
        }
    }

    private func applyStandardLowLatencyThroughputSettings(
        _ session: VTCompressionSession,
        usesSunshineRateControl: Bool,
        status: inout SessionPolicyStatus
    ) {
        _ = applyMaximizePowerEfficiencyTracked(session, status: &status)
        _ = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_ReferenceBufferCount,
            value: NSNumber(value: 1),
            propertyName: "referenceBufferCount",
            status: &status
        )
        guard usesSunshineRateControl else { return }
        _ = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_AllowOpenGOP,
            value: kCFBooleanFalse,
            propertyName: "allowOpenGOP",
            status: &status
        )
        _ = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_AllowTemporalCompression,
            value: kCFBooleanTrue,
            propertyName: "allowTemporalCompression",
            status: &status
        )
    }
}

#endif
