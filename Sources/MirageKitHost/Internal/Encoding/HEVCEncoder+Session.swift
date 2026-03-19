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
    nonisolated static func encoderSpecification(
        for performanceMode: MirageStreamPerformanceMode,
        latencyMode: MirageStreamLatencyMode
    ) -> [CFString: Any] {
        encoderSpecification(
            for: performanceMode,
            latencyMode: latencyMode,
            width: 0,
            height: 0,
            streamKind: .window
        )
    }

    nonisolated static func encoderSpecification(
        for performanceMode: MirageStreamPerformanceMode,
        latencyMode: MirageStreamLatencyMode,
        width: Int,
        height: Int,
        streamKind: StreamKind
    ) -> [CFString: Any] {
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if performanceMode == .game || standardLowLatencyVTTuningEnabled(
            performanceMode: performanceMode,
            latencyMode: latencyMode,
            width: width,
            height: height,
            streamKind: streamKind
        ) {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        return spec
    }

    nonisolated static func standardLowLatencyVTTuningEnabled(
        performanceMode: MirageStreamPerformanceMode,
        latencyMode: MirageStreamLatencyMode
    ) -> Bool {
        standardLowLatencyVTTuningEnabled(
            performanceMode: performanceMode,
            latencyMode: latencyMode,
            width: 0,
            height: 0,
            streamKind: .window
        )
    }

    nonisolated static func standardLowLatencyVTTuningEnabled(
        performanceMode: MirageStreamPerformanceMode,
        latencyMode: MirageStreamLatencyMode,
        width _: Int,
        height _: Int,
        streamKind: StreamKind
    ) -> Bool {
        guard performanceMode == .standard, latencyMode == .lowestLatency else { return false }
        return !shouldSuppressStandardDesktopLowLatencyTuning(
            streamKind: streamKind
        )
    }

    nonisolated static func shouldSuppressStandardDesktopLowLatencyTuning(
        streamKind: StreamKind
    ) -> Bool {
        streamKind == .desktop
    }

    nonisolated static func shouldApplySuppressedStandardLowLatencyThroughputTuning(
        performanceMode: MirageStreamPerformanceMode,
        latencyMode: MirageStreamLatencyMode,
        width _: Int,
        height _: Int,
        streamKind: StreamKind
    ) -> Bool {
        performanceMode == .standard &&
            latencyMode == .lowestLatency &&
            shouldSuppressStandardDesktopLowLatencyTuning(
                streamKind: streamKind
            )
    }

    private struct GameModeRateControlPolicy {
        let realTime = true
        let allowFrameReordering = false
        let referenceBufferCount = 1
        let expectedFrameRate: Int
        let dataRateWindowSeconds: Double
        let allowTemporalCompression = true

        init(targetFrameRate: Int) {
            let clampedFrameRate = max(1, targetFrameRate)
            expectedFrameRate = clampedFrameRate
            dataRateWindowSeconds = 1.0 / Double(clampedFrameRate)
        }
    }

    private enum PropertyApplyOutcome: String {
        case applied
        case unsupported
        case failed

        var appliedBool: Bool { self == .applied }
    }

    private struct SessionPolicyStatus {
        var applied: [String] = []
        var unsupported: [String] = []
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

        var appliedText: String { joined(applied) }
        var unsupportedText: String { joined(unsupported) }
        var failedText: String { joined(failed) }
    }

    private enum GameModeBitrateStrategy: String {
        case constantBitRate
        case averageBitRateOnly
        case averageBitRateDataRateLimits
        case none
    }

    private struct GameModeBitrateResult {
        let strategy: GameModeBitrateStrategy
        let windowSeconds: Double?
    }

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

        let baseSpec = Self.encoderSpecification(
            for: performanceMode,
            latencyMode: resolvedSessionLatencyMode(),
            width: width,
            height: height,
            streamKind: streamKind
        )

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
                codecType: kCMVideoCodecType_HEVC,
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
        if performanceMode == .game {
            MirageLogger.encoder("Encoder spec: game mode low-latency rate control requested")
        } else if resolvedSessionLatencyMode() == .lowestLatency {
            if Self.shouldSuppressStandardDesktopLowLatencyTuning(
                streamKind: streamKind
            ) {
                MirageLogger.encoder(
                    "Encoder spec: standard low-latency rate control suppressed for desktop \(width)x\(height)"
                )
            } else if Self.standardLowLatencyVTTuningEnabled(
                performanceMode: performanceMode,
                latencyMode: resolvedSessionLatencyMode(),
                width: width,
                height: height,
                streamKind: streamKind
            ) {
                MirageLogger.encoder(
                    "Encoder spec: standard low-latency rate control requested for \(streamKind.rawValue) \(width)x\(height)"
                )
            }
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

    func refreshHardwareStatusIfNeeded(reason: String) {
        guard hardwareStatusRefreshAttempts < maxHardwareStatusRefreshAttempts else { return }
        guard usingHardwareEncoder == nil || encoderGPURegistryID == nil else { return }
        guard let session = compressionSession else { return }
        logHardwareStatus(session, reason: reason)
    }

    private func logHardwareStatus(_ session: VTCompressionSession, reason: String) {
        hardwareStatusRefreshAttempts += 1
        usingHardwareEncoder = nil
        encoderGPURegistryID = nil

        var hw: Unmanaged<CFTypeRef>?
        let hwStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hw
        )
        if hwStatus == noErr,
           let value = hw?.takeRetainedValue(),
           let boolValue = value as? Bool {
            usingHardwareEncoder = boolValue
        }

        var gpu: Unmanaged<CFTypeRef>?
        let gpuStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingGPURegistryID,
            allocator: kCFAllocatorDefault,
            valueOut: &gpu
        )
        if gpuStatus == noErr,
           let value = gpu?.takeRetainedValue(),
           let registry = value as? NSNumber {
            encoderGPURegistryID = registry.uint64Value
        }

        let usingHardwareText: String = if let usingHardwareEncoder {
            String(usingHardwareEncoder)
        } else {
            "unknown(status=\(hwStatus))"
        }
        let gpuText: String = if let encoderGPURegistryID {
            String(encoderGPURegistryID)
        } else if gpuStatus == noErr {
            "nil"
        } else {
            "unknown(status=\(gpuStatus))"
        }
        let healthText: String = if usingHardwareEncoder == true {
            "active"
        } else if usingHardwareEncoder == false {
            "software_fallback"
        } else {
            "unknown"
        }

        MirageLogger.encoder(
            "event=hardware_encoder_status reason=\(reason) usingHardware=\(usingHardwareText) " +
                "status=\(healthText) gpuRegistryID=\(gpuText) requiredBySpec=true"
        )
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
        setPropertyOutcome(session, key: key, value: value).appliedBool
    }

    @discardableResult
    private func setPropertyOutcome(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef
    ) -> PropertyApplyOutcome {
        if didQuerySupportedProperties, !supportedPropertyKeys.contains(key) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key)")
            }
            return .unsupported
        }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if key == kVTCompressionPropertyKey_MaxFrameDelayCount,
           Self.unsupportedEncoderPropertyStatuses.contains(status) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key) (status \(status))")
            }
            return .unsupported
        }
        guard status == noErr else {
            MirageLogger.error(.encoder, "VTSessionSetProperty \(key) failed: \(status)")
            return .failed
        }
        return .applied
    }

    private nonisolated static let unsupportedEncoderPropertyStatuses: Set<OSStatus> = [
        -12900,
    ]

    @discardableResult
    private func setPropertyTracked(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef,
        propertyName: String,
        status: inout SessionPolicyStatus
    ) -> Bool {
        let outcome = setPropertyOutcome(session, key: key, value: value)
        status.record(propertyName, outcome: outcome)
        return outcome.appliedBool
    }

    private var maximizePowerEfficiencyValue: CFTypeRef {
        maximizePowerEfficiencyEnabled ? kCFBooleanTrue : kCFBooleanFalse
    }

    @discardableResult
    func applyMaximizePowerEfficiency(_ session: VTCompressionSession) -> Bool {
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaximizePowerEfficiency,
            value: maximizePowerEfficiencyValue
        )
    }

    @discardableResult
    private func applyMaximizePowerEfficiencyTracked(
        _ session: VTCompressionSession,
        status: inout SessionPolicyStatus
    ) -> Bool {
        setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_MaximizePowerEfficiency,
            value: maximizePowerEfficiencyValue,
            propertyName: "maximizePowerEfficiency",
            status: &status
        )
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
        let shouldApplyQPClamps = Self.shouldApplyQPClamps(
            for: performanceMode,
            gameModeEmergencyQualityClampsEnabled: gameModeEmergencyQualityClampsEnabled
        )
        var minQPApplied = false
        var maxQPApplied = false
        if shouldApplyQPClamps, let minQP = settings.minQP {
            minQPApplied = setProperty(
                session,
                key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                value: NSNumber(value: minQP)
            )
        }
        if shouldApplyQPClamps, let maxQP = settings.maxQP {
            maxQPApplied = setProperty(
                session,
                key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                value: NSNumber(value: maxQP)
            )
        }
        if !shouldApplyQPClamps {
            clearGameModeQPClamps(session)
        }

        guard log else { return }
        let qualityText = settings.quality.formatted(.number.precision(.fractionLength(2)))
        let qualityState = qualityApplied ? "applied" : "not-applied"
        if !shouldApplyQPClamps {
            MirageLogger.encoder("Encoder quality: \(qualityText) (\(qualityState)), QP clamps disabled")
        } else if let minQP = settings.minQP, let maxQP = settings.maxQP {
            let qpState = (minQPApplied && maxQPApplied) ? "applied" : "not-applied"
            MirageLogger.encoder("Encoder quality: \(qualityText) (\(qualityState)), QP \(minQP)-\(maxQP) (\(qpState))")
        } else {
            MirageLogger.encoder("Encoder quality: \(qualityText) (\(qualityState))")
        }
    }

    func clearGameModeQPClamps(_ session: VTCompressionSession) {
        // Use neutral bounds to effectively disable QP clamping in game-mode baseline.
        setProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: NSNumber(value: 0))
        setProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: 51))
    }

    private func applyBitrateSettings(_ session: VTCompressionSession) {
        guard let targetBitrate = configuration.bitrate, targetBitrate > 0 else {
            return
        }
        let rateLimit = Self.dataRateLimit(
            targetBitrateBps: targetBitrate,
            targetFrameRate: configuration.targetFrameRate,
            performanceMode: .standard
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

    private func applyGameModeBitrateSettings(
        _ session: VTCompressionSession,
        policy: GameModeRateControlPolicy,
        status: inout SessionPolicyStatus
    ) -> GameModeBitrateResult {
        guard let targetBitrate = configuration.bitrate, targetBitrate > 0 else {
            return GameModeBitrateResult(strategy: .none, windowSeconds: nil)
        }

        let targetFrameRate = max(1, policy.expectedFrameRate)
        let constantBitRateApplied = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_ConstantBitRate,
            value: NSNumber(value: targetBitrate),
            propertyName: "constantBitRate",
            status: &status
        )

        let strategy: GameModeBitrateStrategy
        let windowSeconds: Double?
        if constantBitRateApplied {
            strategy = .constantBitRate
            windowSeconds = nil
        } else {
            let averageBitRateApplied = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: targetBitrate),
                propertyName: "averageBitRate",
                status: &status
            )
            if averageBitRateApplied {
                // Sunshine-style VT defaults rely on bitrate + realtime + speed priority,
                // without forcing an ultra-tight DataRateLimits window.
                strategy = .averageBitRateOnly
                windowSeconds = nil
            } else {
                let rateLimit = Self.dataRateLimit(
                    targetBitrateBps: targetBitrate,
                    targetFrameRate: targetFrameRate,
                    performanceMode: .game
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
                strategy = rateLimitApplied ? .averageBitRateDataRateLimits : .none
                windowSeconds = rateLimitApplied ? rateLimit.windowSeconds : nil
            }
        }

        let mbps = Double(targetBitrate) / 1_000_000.0
        let bitrateText = mbps.formatted(.number.precision(.fractionLength(1)))
        if strategy == .averageBitRateDataRateLimits, let windowSeconds {
            let rateLimit = Self.dataRateLimit(
                targetBitrateBps: targetBitrate,
                targetFrameRate: targetFrameRate,
                performanceMode: .game
            )
            let limitMB = Double(rateLimit.bytes) / 1_000_000.0
            let limitText = limitMB.formatted(.number.precision(.fractionLength(2)))
            let windowText = windowSeconds.formatted(.number.precision(.fractionLength(4)))
            MirageLogger
                .encoder(
                    "Encoder bitrate target: \(bitrateText) Mbps (strategy \(strategy.rawValue), rate limit \(limitText) MB/\(windowText)s)"
                )
        } else {
            MirageLogger.encoder("Encoder bitrate target: \(bitrateText) Mbps (strategy \(strategy.rawValue))")
        }
        return GameModeBitrateResult(strategy: strategy, windowSeconds: windowSeconds)
    }

    func applyBitrateSettingsToActiveSession() {
        guard let session = compressionSession else { return }
        if performanceMode == .game {
            let policy = GameModeRateControlPolicy(targetFrameRate: configuration.targetFrameRate)
            var status = SessionPolicyStatus()
            _ = applyGameModeBitrateSettings(session, policy: policy, status: &status)
        } else {
            applyBitrateSettings(session)
        }
    }

    static func dataRateLimit(
        targetBitrateBps: Int,
        targetFrameRate: Int,
        performanceMode: MirageStreamPerformanceMode = .standard
    ) -> (bytes: Int, windowSeconds: Double) {
        let clampedFrameRate = max(1, targetFrameRate)
        let windowSeconds: Double = if performanceMode == .game {
            1.0 / Double(clampedFrameRate)
        } else {
            clampedFrameRate >= 120 ? 0.25 : 0.5
        }
        let bytesPerSecond = max(1.0, Double(targetBitrateBps) / 8.0)
        let bytes = max(1, Int((bytesPerSecond * windowSeconds).rounded()))
        return (bytes: bytes, windowSeconds: windowSeconds)
    }

    private func configureSession(
        _ session: VTCompressionSession,
        width: Int,
        height: Int
    ) throws {
        let resolvedLatencyMode = resolvedSessionLatencyMode()
        let standardLowLatencyTuningEnabled = Self.standardLowLatencyVTTuningEnabled(
            performanceMode: performanceMode,
            latencyMode: resolvedLatencyMode,
            width: width,
            height: height,
            streamKind: streamKind
        )
        let suppressedStandardLowLatencyThroughputTuningEnabled = Self.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: performanceMode,
            latencyMode: resolvedLatencyMode,
            width: width,
            height: height,
            streamKind: streamKind
        )
        let gameModePolicy = performanceMode == .game ? GameModeRateControlPolicy(
            targetFrameRate: configuration.targetFrameRate
        ) : nil
        var gameModeStatus = SessionPolicyStatus()
        var standardLowLatencyStatus = SessionPolicyStatus()

        if let gameModePolicy {
            _ = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_RealTime,
                value: gameModePolicy.realTime ? kCFBooleanTrue : kCFBooleanFalse,
                propertyName: "realTime",
                status: &gameModeStatus
            )
            _ = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: gameModePolicy.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse,
                propertyName: "allowFrameReordering",
                status: &gameModeStatus
            )
            let frameDelay = frameDelayCount(for: resolvedLatencyMode)
            _ = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: NSNumber(value: frameDelay),
                propertyName: "maxFrameDelayCount",
                status: &gameModeStatus
            )
            _ = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: gameModePolicy.expectedFrameRate as CFNumber,
                propertyName: "expectedFrameRate",
                status: &gameModeStatus
            )
        } else {
            // Real-time encoding.
            setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

            // Disable B-frames for predictable latency (smoothest relies on buffering only).
            setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

            // Configure encoder buffering policy from the active latency profile.
            applySessionLatencySettings(session)

            // Frame rate.
            setProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: configuration.targetFrameRate as CFNumber
            )

            if standardLowLatencyTuningEnabled || suppressedStandardLowLatencyThroughputTuningEnabled {
                applyStandardLowLatencyThroughputSettings(
                    session,
                    status: &standardLowLatencyStatus
                )
            } else {
                let powerPreferenceApplied = applyMaximizePowerEfficiency(session)
                MirageLogger.encoder(
                    "event=encoder_power_preference maximizePowerEfficiency=\(maximizePowerEfficiencyEnabled)(\(powerPreferenceApplied))"
                )
            }
        }

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

        // Prioritize encoding speed over quality for lower latency.
        if gameModePolicy != nil {
            _ = setPropertyTracked(
                session,
                key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: kCFBooleanTrue,
                propertyName: "prioritizeEncodingSpeedOverQuality",
                status: &gameModeStatus
            )
        } else {
            setProperty(
                session,
                key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: kCFBooleanTrue
            )
        }
        MirageLogger.encoder("Prioritizing encoding speed over quality")
        if let gameModePolicy {
            applyGameModeThroughputSettings(session, policy: gameModePolicy, status: &gameModeStatus)
        }

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
        if let gameModePolicy {
            let bitrateResult = applyGameModeBitrateSettings(session, policy: gameModePolicy, status: &gameModeStatus)
            let windowText = if let windowSeconds = bitrateResult.windowSeconds {
                windowSeconds.formatted(.number.precision(.fractionLength(4)))
            } else {
                "n/a"
            }
            MirageLogger.encoder(
                "event=encoder_effective_policy mode=game strategy=\(bitrateResult.strategy.rawValue) " +
                    "targetFPS=\(gameModePolicy.expectedFrameRate) dataRateWindow=\(windowText)s " +
                    "applied=\(gameModeStatus.appliedText) unsupported=\(gameModeStatus.unsupportedText) " +
                    "failed=\(gameModeStatus.failedText)"
            )
        } else {
            // Apply bitrate caps to keep encode time bounded for motion-heavy scenes.
            applyBitrateSettings(session)
            if standardLowLatencyTuningEnabled || suppressedStandardLowLatencyThroughputTuningEnabled {
                MirageLogger.encoder(
                    "event=encoder_standard_low_latency_tuning applied=\(standardLowLatencyStatus.appliedText) " +
                        "suppressedRateControl=\(suppressedStandardLowLatencyThroughputTuningEnabled) " +
                        "unsupported=\(standardLowLatencyStatus.unsupportedText) " +
                        "failed=\(standardLowLatencyStatus.failedText)"
                )
            }
        }

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

        case .sRGB:
            // sRGB uses standard Rec. 709 primaries
            break
        }

        // Prepare for encoding
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func applyStandardLowLatencyThroughputSettings(
        _ session: VTCompressionSession,
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
    }

    private func applyGameModeThroughputSettings(
        _ session: VTCompressionSession,
        policy: GameModeRateControlPolicy,
        status: inout SessionPolicyStatus
    ) {
        // Keep HEVC on the highest-throughput path for sustained high-resolution encoding.
        let powerPreferenceApplied = applyMaximizePowerEfficiencyTracked(session, status: &status)
        let referenceBuffersApplied = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_ReferenceBufferCount,
            value: NSNumber(value: policy.referenceBufferCount),
            propertyName: "referenceBufferCount",
            status: &status
        )
        let openGOPApplied = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_AllowOpenGOP,
            value: kCFBooleanFalse,
            propertyName: "allowOpenGOP",
            status: &status
        )
        let temporalCompressionApplied = setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_AllowTemporalCompression,
            value: policy.allowTemporalCompression ? kCFBooleanTrue : kCFBooleanFalse,
            propertyName: "allowTemporalCompression",
            status: &status
        )

        MirageLogger.encoder(
            "event=encoder_game_mode_tuning maximizePowerEfficiency=\(maximizePowerEfficiencyEnabled)(\(powerPreferenceApplied)) " +
                "referenceBuffers=\(policy.referenceBufferCount)(\(referenceBuffersApplied)) allowOpenGOP=false(\(openGOPApplied)) " +
                "allowTemporalCompression=\(policy.allowTemporalCompression)(\(temporalCompressionApplied))"
        )
    }
}

#endif
