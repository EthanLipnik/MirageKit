//
//  StreamContext+QualityMapping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Bitrate-driven quality mapping helpers.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    private struct LowLatencyHighResolutionQualityBoost {
        let frameQuality: Float
        let keyframeQuality: Float
        let applied: Bool
        let drop: Float
    }

    private static let lowLatencyHighResolutionBoostStartPixels: Double = 4_096_000 // ~2560x1600
    private static let lowLatencyHighResolutionBoostFullPixels: Double = 10_500_000 // ~5K and above
    private static let lowLatencyHighResolutionBoostMinDrop: Float = 0.06
    private static let lowLatencyHighResolutionBoostMaxDrop: Float = 0.18
    private static let lowLatencyHighResolutionBoostMinimumPressureScale: Float = 0.45
    private static let mapperMinimumQuality: Float = 0.03
    private static let awdlInteractiveFrameQualityFloor: Float = 0.16
    private static let awdlInteractiveKeyframeQualityFloor: Float = 0.14
    private static let qualityRefreshEpsilon: Float = 0.0001
    // Clarity-first policy for automatic streams: pressure trades frame rate
    // before it trades readability, so runtime cuts and recovery keyframes hold
    // a readable encode quality. Bitrate caps remain the hard constraint.
    private static let automaticClarityQualityFloorMinimum: Float = 0.42
    private static let automaticClarityKeyframeQualityFloorMinimum: Float = 0.38

    private struct DerivedQualityTargets {
        let frameQuality: Float
        let keyframeQuality: Float
        let bpp: Double?
        let frameRateScale: Double
        let qualityReferenceFrameRate: Int
        let boostDrop: Float?
    }

    func clearTransientRuntimePressureForReconfiguration() {
        realtimeRuntimeQualityCeiling = nil
        realtimeRuntimeBitrateCeilingBps = nil
        realtimePressureState = .observing
        realtimePressureReason = HostAdaptivePFrameController.Reason.healthy.rawValue
    }

    private func applyHostAdaptiveBudgetIfNeeded(
        for outputSize: CGSize,
        logLabel: String?
    ) async {
        guard !hostAdaptiveBudgetApplied else { return }

        guard let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            HostAdaptiveStreamBudgetPolicy.Request(
                requestedBitrateBps: requestedTargetBitrate ?? encoderConfig.bitrate,
                requestedCeilingBps: bitrateAdaptationCeiling,
                enteredBitrateBps: explicitEnteredTargetBitrate,
                runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
                encoderCatchUpQualityAdjustmentEnabled: encoderCatchUpQualityAdjustmentEnabled,
                codec: encoderConfig.codec,
                outputSize: outputSize,
                frameRate: currentFrameRate,
                transportPathKind: transportPathKind,
                mediaPathProfile: mediaPathProfile
            )
        ) else {
            return
        }
        hostAdaptiveBudgetApplied = true

        let previousBitrate = encoderConfig.bitrate
        let previousCeiling = bitrateAdaptationCeiling
        encoderConfig.bitrate = decision.encoderStartupBitrateBps
        currentTargetBitrateBps = decision.startupBitrateBps
        startupBitrate = decision.startupBitrateBps
        bitrateAdaptationCeiling = decision.maximumCeilingBps
        realtimeRuntimeBitrateCeilingBps = decision.startupBitrateBps
        realtimeMinimumBitrateFloorBps = decision.minimumBitrateFloorBps
        encoderThroughputMinimumBitrateFloorBps = decision.encoderThroughputMinimumBitrateFloorBps
        realtimeSenderPacingBitrateBps = decision.startupBitrateBps
        await packetSender?.setTargetBitrateBps(decision.startupBitrateBps)
        if encoder != nil, previousBitrate != decision.encoderStartupBitrateBps {
            await encoder?.updateBitrate(decision.encoderStartupBitrateBps)
            scheduleRateControlRetuneValidation(
                previousBitrate: previousBitrate,
                targetBitrate: decision.encoderStartupBitrateBps
            )
        }

        let prefix = logLabel.map { "\($0): " } ?? ""
        let previousBitrateText = previousBitrate.map(mirageFormattedMegabitRate) ?? "auto"
        let previousCeilingText = previousCeiling.map(mirageFormattedMegabitRate) ?? "none"
        let encoderStartupText = decision.encoderStartupBitrateBps == decision.startupBitrateBps
            ? ""
            : " encoderStartup \(mirageFormattedMegabitRate(decision.encoderStartupBitrateBps))"
        MirageLogger.stream(
            "\(prefix)host adaptive budget \(decision.reason): " +
                "startup \(mirageFormattedMegabitRate(decision.startupBitrateBps)) " +
                "ceiling \(mirageFormattedMegabitRate(decision.maximumCeilingBps)) " +
                "floor \(mirageFormattedMegabitRate(decision.minimumBitrateFloorBps))" +
                "\(encoderStartupText) " +
                "(client target \(previousBitrateText), ceiling \(previousCeilingText))"
        )
    }

    /// Returns the runtime quality floor for the active bitrate policy.
    func resolvedRuntimeQualityFloor(for qualityCeiling: Float) -> Float {
        let ceiling = max(0.0, min(compressionQualityCeiling, qualityCeiling))
        let hasBitrateCap = (encoderConfig.bitrate ?? 0) > 0
        let floorFactor: Float = if let pressureRatio = runtimeBitratePressureRatio() {
            max(0.08, min(bitrateCappedQualityFloorFactor, pressureRatio * 0.90))
        } else {
            hasBitrateCap ? bitrateCappedQualityFloorFactor : qualityFloorFactor
        }
        let minimumFloor = hasBitrateCap ? bitrateCappedQualityFloorMinimum : uncappedQualityFloorMinimum
        if mediaPathProfile.usesAwdlRadioPolicy {
            let floor = ceiling > 0 ? max(minimumFloor, ceiling * floorFactor) : 0
            return awdlBoundedInteractiveFrameQuality(floor)
        }
        guard ceiling > 0 else { return 0 }
        let floor = max(
            max(minimumFloor, ceiling * floorFactor),
            automaticClarityFloor(minimum: Self.automaticClarityQualityFloorMinimum)
        )
        return min(ceiling, floor)
    }

    private func automaticClarityFloor(minimum: Float) -> Float {
        guard runtimeQualityAdjustmentEnabled,
              !mediaPathProfile.usesAwdlRadioPolicy else {
            return 0
        }
        return minimum
    }

    private func localRuntimeQualityFloor(for reason: String) -> Float {
        guard runtimeQualityAdjustmentEnabled,
              mediaPathProfile.usesLocalBulkTransportPolicy,
              encoderConfig.codec != .proRes4444 else {
            return 0
        }
        let contract = currentStreamQualityContract()
        if HostAdaptiveFrameCoordinator.pressureReasonIsMotionComplexity(reason) {
            return contract.localMotionQualityFloor
        }
        switch reason {
        case HostAdaptivePFrameController.Reason.healthy.rawValue,
             HostAdaptivePFrameController.Reason.startup.rawValue:
            return 0
        default:
            return contract.localReadabilityQualityFloor
        }
    }

    /// Returns the runtime keyframe quality floor for the active bitrate policy.
    func resolvedRuntimeKeyframeQualityFloor(for qualityCeiling: Float) -> Float {
        let ceiling = max(0.0, min(compressionQualityCeiling, qualityCeiling))
        let hasBitrateCap = (encoderConfig.bitrate ?? 0) > 0
        let floorFactor: Float = if let pressureRatio = runtimeBitratePressureRatio() {
            max(0.05, min(bitrateCappedKeyframeFloorFactor, pressureRatio * 0.75))
        } else {
            hasBitrateCap ? bitrateCappedKeyframeFloorFactor : keyframeFloorFactor
        }
        let minimumFloor = hasBitrateCap ? bitrateCappedKeyframeFloorMinimum : uncappedQualityFloorMinimum
        if mediaPathProfile.usesAwdlRadioPolicy {
            let floor = ceiling > 0 ? max(minimumFloor, ceiling * floorFactor) : 0
            return awdlBoundedInteractiveKeyframeQuality(
                floor,
                frameQuality: resolvedRuntimeQualityCeiling(for: ceiling)
            )
        }
        guard ceiling > 0 else { return 0 }
        let floor = max(
            max(minimumFloor, ceiling * floorFactor),
            automaticClarityFloor(minimum: Self.automaticClarityKeyframeQualityFloorMinimum)
        )
        return min(ceiling, floor)
    }

    func resolvedRuntimeQualityCeiling(for proposedCeiling: Float) -> Float {
        let configuredCeiling = max(0.0, min(compressionQualityCeiling, steadyQualityCeiling))
        let ceiling = max(0.0, min(configuredCeiling, proposedCeiling))
        guard mediaPathProfile.usesAwdlRadioPolicy else { return ceiling }
        guard ceiling > 0 || configuredCeiling > 0 || compressionQualityCeiling > 0 else { return 0 }
        return awdlBoundedInteractiveFrameQuality(ceiling)
    }

    func resolvedRuntimeKeyframeQualityCeiling(for proposedCeiling: Float) -> Float {
        let configuredCeiling = max(0.0, min(compressionQualityCeiling, steadyQualityCeiling))
        let ceiling = max(0.0, min(configuredCeiling, proposedCeiling))
        guard mediaPathProfile.usesAwdlRadioPolicy else { return ceiling }
        guard ceiling > 0 || configuredCeiling > 0 || compressionQualityCeiling > 0 else { return 0 }
        return awdlBoundedInteractiveKeyframeQuality(ceiling, frameQuality: resolvedRuntimeQualityCeiling(for: ceiling))
    }

    private func awdlBoundedInteractiveFrameQuality(_ quality: Float) -> Float {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return quality }
        guard compressionQualityCeiling > 0 else { return 0 }
        return min(compressionQualityCeiling, max(Self.awdlInteractiveFrameQualityFloor, quality))
    }

    private func awdlBoundedInteractiveKeyframeQuality(_ quality: Float, frameQuality: Float) -> Float {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return min(quality, frameQuality) }
        guard compressionQualityCeiling > 0 else { return 0 }
        let bounded = min(compressionQualityCeiling, max(Self.awdlInteractiveKeyframeQualityFloor, quality))
        return min(max(0, frameQuality), bounded)
    }

    private func runtimeBitratePressureRatio() -> Float? {
        let currentBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? 0
        let baselineBitrate = enteredTargetBitrate ??
            requestedTargetBitrate ??
            startupBitrate ??
            encoderConfig.bitrate ??
            0
        guard currentBitrate > 0, baselineBitrate > 0 else { return nil }
        let ratio = Float(currentBitrate) / Float(baselineBitrate)
        guard ratio < 0.95 else { return nil }
        return max(0.01, min(1.0, ratio))
    }

    private func applyLowLatencyHighResolutionCompressionBoost(
        frameQuality: Float,
        keyframeQuality: Float,
        width: Int,
        height: Int,
        targetBitrateBps: Int,
        frameRate: Int
    ) -> LowLatencyHighResolutionQualityBoost {
        guard lowLatencyHighResolutionCompressionBoostEnabled,
              !mediaPathProfile.usesAwdlRadioPolicy,
              latencyMode == .lowestLatency || latencyMode == .balanced else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let pixelCount = Double(width * height)
        guard pixelCount > Self.lowLatencyHighResolutionBoostStartPixels else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let range = max(
            1.0,
            Self.lowLatencyHighResolutionBoostFullPixels - Self.lowLatencyHighResolutionBoostStartPixels
        )
        let progress = max(0.0, min(1.0, (pixelCount - Self.lowLatencyHighResolutionBoostStartPixels) / range))
        let easedProgress = pow(progress, 0.70)
        let qualityDrop = Self.lowLatencyHighResolutionBoostMinDrop +
            Float(easedProgress) *
            (Self.lowLatencyHighResolutionBoostMaxDrop - Self.lowLatencyHighResolutionBoostMinDrop)
        let bitratePressureScale: Float = if let bpp = MirageBitrateQualityMapper.bitsPerPixelPerFrame(
            targetBitrateBps: targetBitrateBps,
            width: width,
            height: height,
            frameRate: MirageBitrateQualityMapper.qualityReferenceFrameRate(for: frameRate)
        ) {
            max(
                Self.lowLatencyHighResolutionBoostMinimumPressureScale,
                Float(MirageBitrateQualityMapper.compressionPressure(for: bpp))
            )
        } else {
            1.0
        }
        let effectiveQualityDrop = qualityDrop * bitratePressureScale
        guard effectiveQualityDrop > 0.0001 else {
            return LowLatencyHighResolutionQualityBoost(
                frameQuality: frameQuality,
                keyframeQuality: keyframeQuality,
                applied: false,
                drop: 0
            )
        }

        let boostedFrameQuality = max(Self.mapperMinimumQuality, frameQuality - effectiveQualityDrop)
        let keyframeRatio: Float
        if frameQuality > 0 {
            keyframeRatio = max(0.1, min(1.0, keyframeQuality / frameQuality))
        } else {
            keyframeRatio = 0.72
        }
        let boostedKeyframeQuality = max(
            Self.mapperMinimumQuality,
            min(boostedFrameQuality, boostedFrameQuality * keyframeRatio)
        )

        return LowLatencyHighResolutionQualityBoost(
            frameQuality: boostedFrameQuality,
            keyframeQuality: boostedKeyframeQuality,
            applied: true,
            drop: effectiveQualityDrop
        )
    }

    private func derivedQualityTargets(
        targetBitrateBps: Int,
        outputSize: CGSize
    ) -> DerivedQualityTargets {
        let width = max(2, Int(outputSize.width))
        let height = max(2, Int(outputSize.height))
        let qualityReferenceFrameRate = MirageBitrateQualityMapper.qualityReferenceFrameRate(
            for: currentFrameRate
        )
        let derived = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: targetBitrateBps,
            width: width,
            height: height,
            frameRate: currentFrameRate
        )
        let qualityBoost = applyLowLatencyHighResolutionCompressionBoost(
            frameQuality: derived.frameQuality,
            keyframeQuality: derived.keyframeQuality,
            width: width,
            height: height,
            targetBitrateBps: targetBitrateBps,
            frameRate: currentFrameRate
        )
        let cappedFrameQuality = awdlBoundedInteractiveFrameQuality(
            min(qualityBoost.frameQuality, compressionQualityCeiling)
        )
        let cappedKeyframeQuality = awdlBoundedInteractiveKeyframeQuality(
            min(qualityBoost.keyframeQuality, cappedFrameQuality),
            frameQuality: cappedFrameQuality
        )
        let bpp = MirageBitrateQualityMapper.bitsPerPixelPerFrame(
            targetBitrateBps: targetBitrateBps,
            width: width,
            height: height,
            frameRate: qualityReferenceFrameRate
        )
        return DerivedQualityTargets(
            frameQuality: cappedFrameQuality,
            keyframeQuality: cappedKeyframeQuality,
            bpp: bpp,
            frameRateScale: MirageBitrateQualityMapper.frameRateScale(frameRate: currentFrameRate, bpp: bpp),
            qualityReferenceFrameRate: qualityReferenceFrameRate,
            boostDrop: qualityBoost.applied ? qualityBoost.drop : nil
        )
    }

    func refreshRuntimeQualityTargets(
        for targetBitrateBps: Int,
        reason: String,
        allowsActiveQualityRaise: Bool? = nil,
        clearsRuntimeQualityCeiling: Bool? = nil
    ) async {
        guard encoderConfig.codec != .proRes4444 else { return }
        guard currentEncodedSize.width > 0, currentEncodedSize.height > 0 else { return }
        let targets = derivedQualityTargets(
            targetBitrateBps: targetBitrateBps,
            outputSize: currentEncodedSize
        )
        let defaultRaisesActiveQuality = Self.runtimeQualityRefreshShouldRaiseActiveQuality(reason: reason)
        let shouldRaiseActiveQuality = allowsActiveQualityRaise ?? defaultRaisesActiveQuality
        let shouldClearRuntimeQualityCeiling = clearsRuntimeQualityCeiling ?? defaultRaisesActiveQuality
        let previousFrameQuality = encoderConfig.frameQuality
        let previousKeyframeQuality = encoderConfig.keyframeQuality
        let previousConfiguredQualityCeiling = configuredQualityCeiling
        let previousSteadyQualityCeiling = steadyQualityCeiling
        let previousQualityCeiling = qualityCeiling
        let previousQualityFloor = qualityFloor
        let previousKeyframeQualityFloor = keyframeQualityFloor
        let refreshedFrameQuality = shouldClearRuntimeQualityCeiling
            ? max(previousFrameQuality, targets.frameQuality)
            : targets.frameQuality
        let refreshedKeyframeQuality = shouldClearRuntimeQualityCeiling
            ? max(previousKeyframeQuality, targets.keyframeQuality)
            : targets.keyframeQuality
        let localFloor = localRuntimeQualityFloor(for: reason)
        let shouldRefreshConfiguredQualityCeiling = refreshedFrameQuality > configuredQualityCeiling ||
            reason == HostAdaptivePFrameController.Reason.startup.rawValue
        if shouldClearRuntimeQualityCeiling {
            realtimeRuntimeQualityCeiling = nil
        }
        encoderConfig.frameQuality = refreshedFrameQuality
        encoderConfig.keyframeQuality = min(refreshedFrameQuality, refreshedKeyframeQuality)
        if shouldRefreshConfiguredQualityCeiling {
            configuredQualityCeiling = refreshedFrameQuality
        }
        steadyQualityCeiling = refreshedFrameQuality
        let proposedRuntimeQualityCeiling = if shouldClearRuntimeQualityCeiling,
                                               !mediaPathProfile.usesAwdlRadioPolicy {
            max(qualityCeiling, configuredQualityCeiling, refreshedFrameQuality)
        } else {
            refreshedFrameQuality
        }
        qualityCeiling = min(resolvedQualityCeiling, max(proposedRuntimeQualityCeiling, localFloor))
        qualityFloor = min(
            qualityCeiling,
            max(resolvedRuntimeQualityFloor(for: qualityCeiling), localFloor)
        )
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: min(targets.keyframeQuality, qualityCeiling)
        )

        let previousActiveQuality = activeQuality
        let boundedTargetQuality = max(qualityFloor, min(refreshedFrameQuality, qualityCeiling))
        let shouldLowerActiveQuality = !shouldClearRuntimeQualityCeiling ||
            mediaPathProfile.usesAwdlRadioPolicy
        if (shouldLowerActiveQuality && activeQuality > boundedTargetQuality) ||
            (shouldRaiseActiveQuality && activeQuality < boundedTargetQuality) ||
            (mediaPathProfile.usesAwdlRadioPolicy && activeQuality < qualityFloor) {
            activeQuality = boundedTargetQuality
        }
        if Self.qualityValuesDiffer(previousActiveQuality, activeQuality) {
            await encoder?.updateQuality(activeQuality)
        }

        guard Self.qualityValuesDiffer(previousFrameQuality, encoderConfig.frameQuality) ||
            Self.qualityValuesDiffer(previousKeyframeQuality, encoderConfig.keyframeQuality) ||
            Self.qualityValuesDiffer(previousConfiguredQualityCeiling, configuredQualityCeiling) ||
            Self.qualityValuesDiffer(previousSteadyQualityCeiling, steadyQualityCeiling) ||
            Self.qualityValuesDiffer(previousQualityCeiling, qualityCeiling) ||
            Self.qualityValuesDiffer(previousQualityFloor, qualityFloor) ||
            Self.qualityValuesDiffer(previousKeyframeQualityFloor, keyframeQualityFloor) ||
            Self.qualityValuesDiffer(previousActiveQuality, activeQuality) else {
            return
        }

        let targetMbps = Double(targetBitrateBps) / 1_000_000.0
        let previousText = previousSteadyQualityCeiling.formatted(.number.precision(.fractionLength(2)))
        let steadyText = steadyQualityCeiling.formatted(.number.precision(.fractionLength(2)))
        let activeText = activeQuality.formatted(.number.precision(.fractionLength(2)))
        let previousActiveText = previousActiveQuality.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.metrics(
            "Runtime quality target refreshed for stream \(streamID): " +
                "target=\(targetMbps.formatted(.number.precision(.fractionLength(0))))Mbps " +
                "steady=\(previousText)->\(steadyText) active=\(previousActiveText)->\(activeText) " +
                "reason=\(reason)"
        )
    }

    func applyDerivedQuality(for outputSize: CGSize, logLabel: String?) async {
        // ProRes manages its own quality — no bitrate-driven quality mapping
        guard encoderConfig.codec != .proRes4444 else { return }

        await applyHostAdaptiveBudgetIfNeeded(for: outputSize, logLabel: logLabel)

        guard let targetBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: encoderConfig.bitrate
        ) else {
            return
        }

        let targets = derivedQualityTargets(targetBitrateBps: targetBitrate, outputSize: outputSize)

        let previousFrameQuality = encoderConfig.frameQuality
        let previousKeyframeQuality = encoderConfig.keyframeQuality
        let previousConfiguredQualityCeiling = configuredQualityCeiling
        let previousSteadyQualityCeiling = steadyQualityCeiling
        let previousQualityCeiling = qualityCeiling
        let previousQualityFloor = qualityFloor
        let previousKeyframeQualityFloor = keyframeQualityFloor
        let previousActiveQuality = activeQuality
        encoderConfig.frameQuality = targets.frameQuality
        encoderConfig.keyframeQuality = targets.keyframeQuality
        configuredQualityCeiling = targets.frameQuality
        steadyQualityCeiling = targets.frameQuality
        qualityCeiling = resolvedQualityCeiling
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        activeQuality = max(qualityFloor, min(targets.frameQuality, qualityCeiling))
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: min(targets.keyframeQuality, qualityCeiling))

        if Self.qualityValuesDiffer(previousActiveQuality, activeQuality) {
            await encoder?.updateQuality(activeQuality)
        }

        guard Self.qualityValuesDiffer(previousFrameQuality, encoderConfig.frameQuality) ||
            Self.qualityValuesDiffer(previousKeyframeQuality, encoderConfig.keyframeQuality) ||
            Self.qualityValuesDiffer(previousConfiguredQualityCeiling, configuredQualityCeiling) ||
            Self.qualityValuesDiffer(previousSteadyQualityCeiling, steadyQualityCeiling) ||
            Self.qualityValuesDiffer(previousQualityCeiling, qualityCeiling) ||
            Self.qualityValuesDiffer(previousQualityFloor, qualityFloor) ||
            Self.qualityValuesDiffer(previousKeyframeQualityFloor, keyframeQualityFloor) ||
            Self.qualityValuesDiffer(previousActiveQuality, activeQuality) else {
            return
        }

        if let logLabel {
            let mbps = Double(targetBitrate) / 1_000_000.0
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            let capText = compressionQualityCeiling.formatted(.number.precision(.fractionLength(2)))
            let bpp = targets.bpp
            let bppText: String = if let bpp {
                bpp.formatted(.number.precision(.fractionLength(4)))
            } else {
                "n/a"
            }
            let scaleText = targets.frameRateScale.formatted(.number.precision(.fractionLength(2)))
            let referenceFrameRate = targets.qualityReferenceFrameRate
            let boostText: String
            if let boostDrop = targets.boostDrop {
                let dropText = boostDrop.formatted(.number.precision(.fractionLength(2)))
                boostText = ", llHighResBoostDrop \(dropText)"
            } else {
                boostText = ""
            }
            MirageLogger
                .stream(
                    "\(logLabel): target \(mbps.formatted(.number.precision(.fractionLength(0)))) Mbps, quality \(qualityText) (cap \(capText)), bpp \(bppText), fps=\(currentFrameRate), qualityRefFPS=\(referenceFrameRate), fpsScale \(scaleText)\(boostText)"
                )
        }
    }

    private func mirageFormattedMegabitRate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000.0
        return "\(mbps.formatted(.number.precision(.fractionLength(1))))Mbps"
    }

    private static func runtimeQualityRefreshShouldRaiseActiveQuality(reason: String) -> Bool {
        reason == HostAdaptivePFrameController.Reason.healthy.rawValue ||
            reason == HostAdaptivePFrameController.Reason.startup.rawValue
    }

    private static func qualityValuesDiffer(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) > qualityRefreshEpsilon
    }
}
#endif
