//
//  HEVCEncoder+Session.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension HEVCEncoder {
    func resolvedSessionLatencyMode() -> MirageStreamLatencyMode {
        if latencyMode == .auto, autoTypingBurstLowLatencyActive {
            return .lowestLatency
        }
        return latencyMode
    }

    func frameDelayCount(for mode: MirageStreamLatencyMode) -> Int {
        switch mode {
        case .smoothest:
            2
        case .auto:
            2
        case .lowestLatency:
            0
        }
    }

    func applySessionLatencySettings(_ session: VTCompressionSession, logReason: String? = nil) {
        let mode = resolvedSessionLatencyMode()
        let frameDelayCount = frameDelayCount(for: mode)
        let applied = setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: frameDelayCount)
        )
        guard let logReason else { return }
        let applyText = applied ? "applied" : "not-applied"
        MirageLogger
            .encoder(
                "Encoder latency profile: \(mode.displayName) (\(logReason), maxFrameDelay=\(frameDelayCount), \(applyText))"
            )
    }

    func createSession(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary

        let baseSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: baseSpec as CFDictionary,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        if status != noErr, activePixelFormat == .p010 {
            activePixelFormat = .nv12
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
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: baseSpec as CFDictionary,
                imageBufferAttributes: fallbackAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            if status == noErr { MirageLogger.encoder("P010 unsupported; using NV12") }
        }

        guard status == noErr, let session else { throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }

        loadSupportedProperties(session)
        try configureSession(session)
        logHardwareStatus(session)
        compressionSession = session

        // Store dimensions for reset
        currentWidth = width
        currentHeight = height

        let formatLabel = switch activePixelFormat {
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
    }

    private func qualitySettings(for quality: Float) -> QualitySettings {
        let clamped = max(0.02, min(compressionQualityCeiling, quality))
        let useQP = clamped < 0.98
        guard useQP else { return QualitySettings(quality: clamped, minQP: nil, maxQP: nil) }
        let rawMin = 10.0 + (1.0 - Double(clamped)) * 36.0
        let clampedMin = max(10, min(46, Int(rawMin.rounded())))
        let maxQP = min(51, clampedMin + 12)
        return QualitySettings(quality: clamped, minQP: clampedMin, maxQP: maxQP)
    }

    private func loadSupportedProperties(_ session: VTCompressionSession) {
        var propertyDictionary: CFDictionary?
        let status = VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &propertyDictionary
        )
        didQuerySupportedProperties = (status == noErr)
        guard status == noErr, let dict = propertyDictionary as? [CFString: Any] else {
            supportedPropertyKeys = []
            loggedUnsupportedKeys = []
            MirageLogger.encoder("Encoder property support lookup failed: \(status)")
            return
        }
        supportedPropertyKeys = Set(dict.keys)
        loggedUnsupportedKeys = []
    }

    private func logHardwareStatus(_ session: VTCompressionSession) {
        var hw: CFTypeRef?
        let hwStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hw
        )
        if hwStatus == noErr, let value = hw, let boolValue = value as? Bool { MirageLogger.encoder("Using hardware encoder: \(boolValue)") } else {
            MirageLogger.encoder("Using hardware encoder: (unknown, status \(hwStatus))")
        }

        var gpu: CFTypeRef?
        let gpuStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingGPURegistryID,
            allocator: kCFAllocatorDefault,
            valueOut: &gpu
        )
        if gpuStatus == noErr, let value = gpu, let registry = value as? NSNumber { MirageLogger.encoder("Encoder GPU registry ID: \(registry)") } else if gpuStatus == noErr {
            MirageLogger.encoder("Encoder GPU registry ID: nil (built-in encoder or software)")
        }
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

    @discardableResult
    func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) -> Bool {
        if didQuerySupportedProperties, !supportedPropertyKeys.contains(key) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key)")
            }
            return false
        }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            MirageLogger.error(.encoder, "VTSessionSetProperty \(key) failed: \(status)")
            return false
        }
        return true
    }

    func hevcProfileName(for profile: CFString) -> String {
        if CFEqual(profile, kVTProfileLevel_HEVC_Main42210_AutoLevel) {
            return "HEVC Main42210 (4:2:2)"
        }
        if CFEqual(profile, kVTProfileLevel_HEVC_Main10_AutoLevel) {
            return "HEVC Main10 (4:2:0)"
        }
        if CFEqual(profile, kVTProfileLevel_HEVC_Main_AutoLevel) {
            return "HEVC Main (4:2:0)"
        }
        return profile as String
    }

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
            if index > 0 {
                let preferred = hevcProfileName(for: candidates[0])
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
            return
        }
        let rateLimit = Self.dataRateLimit(
            targetBitrateBps: targetBitrate,
            targetFrameRate: configuration.targetFrameRate
        )
        setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: targetBitrate))
        let rateLimits: [NSNumber] = [
            NSNumber(value: rateLimit.bytes),
            NSNumber(value: rateLimit.windowSeconds),
        ]
        setProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimits as CFArray)

        let mbps = Double(targetBitrate) / 1_000_000.0
        let bitrateText = mbps.formatted(.number.precision(.fractionLength(1)))
        let limitMB = Double(rateLimit.bytes) / 1_000_000.0
        let limitText = limitMB.formatted(.number.precision(.fractionLength(2)))
        let windowText = rateLimit.windowSeconds.formatted(.number.precision(.fractionLength(2)))
        MirageLogger
            .encoder(
                "Encoder bitrate target: \(bitrateText) Mbps (rate limit \(limitText) MB/\(windowText)s)"
            )
    }

    func applyBitrateSettingsToActiveSession() {
        guard let session = compressionSession else { return }
        applyBitrateSettings(session)
    }

    static func dataRateLimit(targetBitrateBps: Int, targetFrameRate: Int) -> (bytes: Int, windowSeconds: Double) {
        let windowSeconds: Double = targetFrameRate >= 120 ? 0.25 : 0.5
        let bytesPerSecond = max(1.0, Double(targetBitrateBps) / 8.0)
        let bytes = max(1, Int((bytesPerSecond * windowSeconds).rounded()))
        return (bytes: bytes, windowSeconds: windowSeconds)
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding
        setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Disable B-frames for predictable latency (smoothest relies on buffering only).
        setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Configure encoder buffering policy from the active latency profile.
        applySessionLatencySettings(session)

        // Frame rate
        setProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: configuration.targetFrameRate as CFNumber
        )

        // Keyframe interval
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: configuration.keyFrameInterval as CFNumber
        )
        let intervalSeconds = max(
            1.0,
            Double(configuration.keyFrameInterval) / Double(max(1, configuration.targetFrameRate))
        )
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: intervalSeconds as CFNumber
        )

        // Profile selection. ARGB2101010 prefers Main42210 and falls back to Main10.
        applyProfileLevel(session)

        // Prioritize encoding speed over quality for lower latency
        setProperty(
            session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue
        )
        MirageLogger.encoder("Prioritizing encoding speed over quality")

        // Apply base quality setting - lower values reduce size for all frames
        let requestedQuality = configuration.frameQuality
        baseQuality = min(requestedQuality, compressionQualityCeiling)
        if requestedQuality > compressionQualityCeiling {
            let requestedText = requestedQuality.formatted(.number.precision(.fractionLength(2)))
            let capText = compressionQualityCeiling.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.encoder("Quality cap applied: requested \(requestedText), using \(capText)")
        }
        applyQualitySettings(session, quality: baseQuality, log: true)

        // Apply bitrate caps to keep encode time bounded for motion-heavy scenes
        applyBitrateSettings(session)

        // Note: kVTCompressionPropertyKey_ConstantBitRate is not supported by all HEVC encoders
        // The encoder will use its default rate control mode (typically VBR), which is fine
        // since we already have MaxFrameDelayCount=0 and RealTime=true for low latency

        // Color space configuration
        switch configuration.colorSpace {
        case .displayP3:
            // P3 uses P3-D65 primaries with sRGB transfer function and 709 YCbCr matrix
            setProperty(
                session,
                key: kVTCompressionPropertyKey_ColorPrimaries,
                value: kCMFormatDescriptionColorPrimaries_P3_D65
            )
            setProperty(
                session,
                key: kVTCompressionPropertyKey_TransferFunction,
                value: kCMFormatDescriptionTransferFunction_sRGB
            )
            setProperty(
                session,
                key: kVTCompressionPropertyKey_YCbCrMatrix,
                value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            )

        // TODO: HDR support - requires proper virtual display EDR configuration
        // case .hdr:
        //     // HDR uses Rec. 2020 primaries with PQ (SMPTE ST 2084) transfer function
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_ColorPrimaries,
        //         value: kCVImageBufferColorPrimaries_ITU_R_2020
        //     )
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_TransferFunction,
        //         value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        //     )
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_YCbCrMatrix,
        //         value: kCVImageBufferYCbCrMatrix_ITU_R_2020
        //     )
        //     MirageLogger.encoder("HDR encoding enabled: Rec. 2020 + PQ transfer function")

        case .sRGB:
            // sRGB uses standard Rec. 709 primaries
            break
        }

        // Prepare for encoding
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
}

#endif
