//
//  MirageAutomaticDesktopWorkloadController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/21/26.
//
//  Automatic desktop workload policy for transport-bound streams.
//

import CoreGraphics
import Foundation
import MirageKit

public enum MirageAdaptiveQualityPriority: String, Codable, CaseIterable, Sendable {
    case preserveResolutionAndBitrate
    case balanced
    case prioritizeSmoothness
}

/// Stateful policy that adjusts desktop stream cadence after sustained transport pressure.
public struct MirageAutomaticDesktopWorkloadController: Sendable {
    /// Decision returned after evaluating a metrics sample.
    public enum Action: Sendable, Equatable {
        /// Keep the current stream workload.
        case none

        /// Reconfigure the stream to a new target tier for the given diagnostic reason.
        case reconfigure(target: MirageAutomaticDesktopWorkloadTier, reason: String)
    }

    private static let requiredTransportPressureSamples = 4
    private static let requiredPromotionSamples = 6
    private static let reconfigurationCooldownSeconds: CFAbsoluteTime = 20

    private var transportPressureSampleCount = 0
    private var promotionSampleCount = 0
    private var lastReconfigurationAt: CFAbsoluteTime?

    /// Creates an automatic desktop workload controller.
    public init() {}

    /// Clears accumulated pressure and promotion counters.
    public mutating func reset() {
        resetSampleCounters()
        lastReconfigurationAt = nil
    }

    /// Consumes one metrics sample and returns a workload action when pressure is sustained.
    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        resizeCriticalSectionActive: Bool,
        minimumTargetFrameRate: Int = 30,
        maximumTargetFrameRate: Int = 60,
        minimumHealthyFrameRate: Int? = nil,
        adaptivePriority: MirageAdaptiveQualityPriority = .preserveResolutionAndBitrate,
        preferredMaximumTier: MirageAutomaticDesktopWorkloadTier? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        _ = adaptivePriority
        guard !resizeCriticalSectionActive else {
            resetPressureCounters()
            return .none
        }

        let health = MirageStreamPipelineHealth.evaluate(
            snapshot: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        guard let currentTier = health.currentTier else {
            resetSampleCounters()
            return .none
        }

        let transportPressureActive = !health.transportIsClean || health.bottleneckKind == .networkBound
        if transportPressureActive {
            promotionSampleCount = 0
            transportPressureSampleCount += 1
            guard transportPressureSampleCount >= Self.requiredTransportPressureSamples,
                  cooldownElapsed(now: now),
                  let targetTier = Self.lowerFrameRateTier(
                      currentTier: currentTier,
                      minimumTargetFrameRate: minimumTargetFrameRate
                  ) else {
                return .none
            }
            recordReconfiguration(now: now)
            let reason = "transport pressure, target fps \(currentTier.targetFrameRate)->\(targetTier.targetFrameRate)"
            return .reconfigure(target: targetTier, reason: reason)
        }

        resetPressureCounters()
        guard !health.isPipelineBound else {
            promotionSampleCount = 0
            return .none
        }
        promotionSampleCount += 1
        guard promotionSampleCount >= Self.requiredPromotionSamples,
              cooldownElapsed(now: now),
              var targetTier = Self.nextHigherTier(
                  after: currentTier,
                  maximumTargetFrameRate: maximumTargetFrameRate
              ) else {
            return .none
        }
        if let preferredMaximumTier, targetTier.pixelRate > preferredMaximumTier.pixelRate {
            targetTier = preferredMaximumTier
        }
        guard targetTier.encodedPixelSize == currentTier.encodedPixelSize,
              targetTier.targetFrameRate > currentTier.targetFrameRate else {
            promotionSampleCount = 0
            return .none
        }
        promotionSampleCount = 0
        lastReconfigurationAt = now
        return .reconfigure(target: targetTier, reason: "sustained clean transport")
    }

    /// Clears pressure-related sample counters while preserving promotion history.
    private mutating func resetPressureCounters() {
        transportPressureSampleCount = 0
    }

    /// Clears all accumulated workload sample counters.
    private mutating func resetSampleCounters() {
        resetPressureCounters()
        promotionSampleCount = 0
    }

    /// Records a downshift reconfiguration and clears pressure counters for the next sampling window.
    private mutating func recordReconfiguration(now: CFAbsoluteTime) {
        resetPressureCounters()
        lastReconfigurationAt = now
    }

    private func cooldownElapsed(now: CFAbsoluteTime) -> Bool {
        guard let lastReconfigurationAt else { return true }
        return now - lastReconfigurationAt >= Self.reconfigurationCooldownSeconds
    }

    private static func lowerFrameRateTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        minimumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let normalizedMinimumTargetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(minimumTargetFrameRate)
        guard currentTier.targetFrameRate > normalizedMinimumTargetFrameRate else { return nil }
        let lowerFrameRate = MirageAutomaticDesktopWorkloadTier.sameResolutionPromotionFrameRates
            .reversed()
            .first { $0 < currentTier.targetFrameRate && $0 >= normalizedMinimumTargetFrameRate }
            ?? normalizedMinimumTargetFrameRate
        guard lowerFrameRate < currentTier.targetFrameRate else { return nil }
        return MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: currentTier.encodedPixelSize,
            targetFrameRate: lowerFrameRate
        )
    }

    private static func nextHigherTier(
        after currentTier: MirageAutomaticDesktopWorkloadTier,
        maximumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let normalizedMaximumTargetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(maximumTargetFrameRate)
        if let sameResolutionTier = sameResolutionFrameRatePromotionTier(
            currentTier: currentTier,
            maximumTargetFrameRate: normalizedMaximumTargetFrameRate
        ) {
            return sameResolutionTier
        }

        let tiers = MirageAutomaticDesktopWorkloadTier.defaultDescendingTiers.filter {
            $0.targetFrameRate <= normalizedMaximumTargetFrameRate
        }
        guard let currentIndex = tiers.firstIndex(where: { $0 == currentTier }),
              currentIndex > tiers.startIndex else {
            return nil
        }
        return tiers[tiers.index(before: currentIndex)]
    }

    private static func sameResolutionFrameRatePromotionTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        maximumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let candidateFrameRates = MirageAutomaticDesktopWorkloadTier.sameResolutionPromotionFrameRates.filter {
            $0 > currentTier.targetFrameRate && $0 <= maximumTargetFrameRate
        }
        guard let frameRate = candidateFrameRates.first else { return nil }
        return MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: currentTier.encodedPixelSize,
            targetFrameRate: frameRate
        )
    }
}
