//
//  MirageAutomaticDesktopWorkloadController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/21/26.
//
//  Automatic desktop workload policy for pipeline-bound streams.
//

import CoreGraphics
import Foundation
import MirageKit

public enum MirageAdaptiveQualityPriority: String, Codable, CaseIterable, Sendable {
    case preserveResolutionAndBitrate
    case balanced
    case prioritizeSmoothness
}

/// Stateful policy that adjusts desktop stream workload after sustained clean pipeline pressure.
public struct MirageAutomaticDesktopWorkloadController: Sendable {
    /// Decision returned after evaluating a metrics sample.
    public enum Action: Sendable, Equatable {
        /// Keep the current stream workload.
        case none

        /// Reconfigure the stream to a new target tier for the given diagnostic reason.
        case reconfigure(target: MirageAutomaticDesktopWorkloadTier, reason: String)
    }

    private static let requiredPipelinePressureSamples = 8
    private static let requiredPresentationCollapseSamples = 3
    private static let requiredPromotionSamples = 6
    private static let reconfigurationCooldownSeconds: CFAbsoluteTime = 20
    private static let observedPixelRateSafetyFactor = 0.85

    private var pipelinePressureSampleCount = 0
    private var presentationCollapseSampleCount = 0
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
        guard health.transportIsClean,
              let currentTier = health.currentTier else {
            resetSampleCounters()
            return .none
        }

        if health.sourceCadenceDeficient {
            resetSampleCounters()
            return .none
        }

        if health.isClientPipelineBound {
            guard let observedPixelRate = health.observedPixelRate else {
                resetSampleCounters()
                return .none
            }

            promotionSampleCount = 0
            if Self.isSevereClientPresentationCollapse(snapshot: snapshot, currentTier: currentTier) {
                presentationCollapseSampleCount += 1
            } else {
                presentationCollapseSampleCount = 0
            }
            pipelinePressureSampleCount += 1
            let requiredSamples = presentationCollapseSampleCount >= Self.requiredPresentationCollapseSamples
                ? Self.requiredPresentationCollapseSamples
                : Self.requiredPipelinePressureSamples
            guard pipelinePressureSampleCount >= requiredSamples,
                  cooldownElapsed(now: now),
                  var targetTier = Self.clientPipelineTargetTier(
                      currentTier: currentTier,
                      pipelinePixelRate: observedPixelRate,
                      minimumTargetFrameRate: minimumTargetFrameRate,
                      maximumTargetFrameRate: maximumTargetFrameRate
                  ) else {
                return .none
            }
            if let preferredMaximumTier, targetTier.pixelRate > preferredMaximumTier.pixelRate {
                targetTier = preferredMaximumTier
            }

            recordReconfiguration(now: now)
            let reasonPrefix = requiredSamples == Self.requiredPresentationCollapseSamples
                ? "client presentation collapse"
                : health.bottleneckKind.rawValue
            let reason = "\(reasonPrefix), client presented \(Int(observedPixelRate)) px/s"
            return .reconfigure(target: targetTier, reason: reason)
        }

        if !health.isPipelineBound {
            resetPressureCounters()
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
            promotionSampleCount = 0
            lastReconfigurationAt = now
            return .reconfigure(target: targetTier, reason: "sustained clean transport and host cadence")
        }

        guard let hostPipelinePixelRate = health.hostPipelinePixelRate else {
            resetSampleCounters()
            return .none
        }

        promotionSampleCount = 0
        presentationCollapseSampleCount = 0
        pipelinePressureSampleCount += 1
        guard pipelinePressureSampleCount >= Self.requiredPipelinePressureSamples else {
            return .none
        }
        guard cooldownElapsed(now: now) else {
            return .none
        }
        guard var targetTier = Self.targetTier(
            currentTier: currentTier,
            pipelinePixelRate: hostPipelinePixelRate,
            minimumTargetFrameRate: minimumTargetFrameRate,
            maximumTargetFrameRate: maximumTargetFrameRate
        ) else {
            return .none
        }
        if let preferredMaximumTier, targetTier.pixelRate > preferredMaximumTier.pixelRate {
            targetTier = preferredMaximumTier
        }

        recordReconfiguration(now: now)
        let reason = "\(health.bottleneckKind.rawValue), host pipeline \(Int(hostPipelinePixelRate)) px/s"
        return .reconfigure(target: targetTier, reason: reason)
    }

    /// Clears pressure-related sample counters while preserving promotion history.
    private mutating func resetPressureCounters() {
        pipelinePressureSampleCount = 0
        presentationCollapseSampleCount = 0
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

    private static func targetTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        pipelinePixelRate: Double,
        minimumTargetFrameRate: Int,
        maximumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let sustainablePixelRate = pipelinePixelRate * observedPixelRateSafetyFactor
        let normalizedMinimumTargetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(minimumTargetFrameRate)
        let normalizedMaximumTargetFrameRate = max(
            normalizedMinimumTargetFrameRate,
            MirageRenderModePolicy.normalizedTargetFPS(maximumTargetFrameRate)
        )
        if currentTier.targetFrameRate > 60,
           currentTier.targetFrameRate > normalizedMinimumTargetFrameRate,
           let frameRatePreservingTier = reducedResolutionTierPreservingFrameRate(
               currentTier: currentTier,
               pipelinePixelRate: pipelinePixelRate
           ) {
            return frameRatePreservingTier
        }

        let tiers = MirageAutomaticDesktopWorkloadTier.defaultDescendingTiers.filter {
            $0.targetFrameRate >= normalizedMinimumTargetFrameRate &&
                $0.targetFrameRate <= normalizedMaximumTargetFrameRate
        }
        let sameFrameRateTier = tiers.first { tier in
            tier.targetFrameRate == currentTier.targetFrameRate &&
                tier.pixelRate < currentTier.pixelRate &&
                tier.pixelRate <= sustainablePixelRate
        }
        let eligibleTier = sameFrameRateTier ?? tiers.first { tier in
            tier.pixelRate <= sustainablePixelRate
        } ?? tiers.last

        guard let eligibleTier else { return nil }
        guard eligibleTier.pixelRate < currentTier.pixelRate else { return nil }
        return eligibleTier
    }

    private static func clientPipelineTargetTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        pipelinePixelRate: Double,
        minimumTargetFrameRate: Int,
        maximumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let normalizedMinimumTargetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(minimumTargetFrameRate)
        let normalizedMaximumTargetFrameRate = max(
            normalizedMinimumTargetFrameRate,
            MirageRenderModePolicy.normalizedTargetFPS(maximumTargetFrameRate)
        )
        guard currentTier.targetFrameRate >= normalizedMinimumTargetFrameRate,
              currentTier.targetFrameRate <= normalizedMaximumTargetFrameRate else {
            return targetTier(
                currentTier: currentTier,
                pipelinePixelRate: pipelinePixelRate,
                minimumTargetFrameRate: normalizedMinimumTargetFrameRate,
                maximumTargetFrameRate: normalizedMaximumTargetFrameRate
            )
        }

        let currentPixels = currentTier.encodedPixelCount
        let targetPixels = targetPixelsPreservingFrameRate(
            currentTier: currentTier,
            pipelinePixelRate: pipelinePixelRate
        )
        guard targetPixels < currentPixels * 0.97 else { return nil }

        let scale = max(0.35, sqrt(max(1.0, targetPixels) / currentPixels))
        let targetSize = CGSize(
            width: currentTier.encodedPixelSize.width * scale,
            height: currentTier.encodedPixelSize.height * scale
        )
        let targetTier = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: targetSize,
            targetFrameRate: currentTier.targetFrameRate
        )
        guard targetTier.pixelRate < currentTier.pixelRate else { return nil }
        return targetTier
    }

    private static func reducedResolutionTierPreservingFrameRate(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        pipelinePixelRate: Double
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let currentPixels = currentTier.encodedPixelCount
        let targetPixels = targetPixelsPreservingFrameRate(
            currentTier: currentTier,
            pipelinePixelRate: pipelinePixelRate
        )
        guard targetPixels < currentPixels * 0.97 else { return nil }
        let scale = max(0.35, sqrt(max(1.0, targetPixels) / currentPixels))
        let targetTier = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: CGSize(
                width: currentTier.encodedPixelSize.width * scale,
                height: currentTier.encodedPixelSize.height * scale
            ),
            targetFrameRate: currentTier.targetFrameRate
        )
        guard targetTier.pixelRate < currentTier.pixelRate else { return nil }
        return targetTier
    }

    private static func targetPixelsPreservingFrameRate(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        pipelinePixelRate: Double
    ) -> Double {
        let sustainablePixelRate = pipelinePixelRate * observedPixelRateSafetyFactor
        return sustainablePixelRate / Double(max(1, currentTier.targetFrameRate))
    }

    private static func isSevereClientPresentationCollapse(
        snapshot: MirageClientMetricsSnapshot?,
        currentTier: MirageAutomaticDesktopWorkloadTier
    )
    -> Bool {
        guard let snapshot else { return false }
        guard currentTier.targetFrameRate >= 90 else { return false }
        guard snapshot.bottleneckKind == .presentationBound ||
            snapshot.bottleneckKind == .decodeBound ||
            snapshot.bottleneckKind == .mixed else {
            return false
        }

        let targetFPS = Double(max(1, currentTier.targetFrameRate))
        let hostCadence = minimumPositive(
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS
        ) ?? 0
        let clientCadence = minimumPositive(
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
            snapshot.clientPresentedFPS > 0 ? snapshot.clientPresentedFPS : nil,
            snapshot.clientLayerAcceptedFPS > 0 ? snapshot.clientLayerAcceptedFPS : nil
        ) ?? 0
        guard hostCadence >= targetFPS * 0.85 else { return false }
        guard snapshot.decodedFPS >= targetFPS * 0.60 else { return false }
        guard clientCadence > 0, clientCadence <= targetFPS * 0.72 else { return false }

        let frameBudgetMs = 1000.0 / targetFPS
        return snapshot.clientPendingFrameAgeMs >= max(28.0, frameBudgetMs * 3.0) ||
            snapshot.clientOverwrittenPendingFrames >= 3 ||
            snapshot.clientDisplayLayerNotReadyCount >= 2 ||
            snapshot.clientFrameIntervalP99Ms >= max(36.0, frameBudgetMs * 4.0) ||
            snapshot.clientWorstPresentationGapMs >= max(120.0, frameBudgetMs * 10.0)
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
