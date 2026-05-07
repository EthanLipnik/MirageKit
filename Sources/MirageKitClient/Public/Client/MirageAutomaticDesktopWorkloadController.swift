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

public struct MirageAutomaticDesktopWorkloadTier: Sendable, Equatable {
    public let encodedPixelSize: CGSize
    public let targetFrameRate: Int

    public init(encodedPixelSize: CGSize, targetFrameRate: Int) {
        self.encodedPixelSize = MirageStreamGeometry.alignedEncodedSize(encodedPixelSize)
        self.targetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(targetFrameRate)
    }

    public var pixelRate: Double {
        Double(max(1, Int(encodedPixelSize.width))) *
            Double(max(1, Int(encodedPixelSize.height))) *
            Double(max(1, targetFrameRate))
    }

    public var logLabel: String {
        "\(Int(encodedPixelSize.width))x\(Int(encodedPixelSize.height))@\(targetFrameRate)"
    }

    public static let fourK60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 3840, height: 2160),
        targetFrameRate: 60
    )
    public static let fourK30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 3840, height: 2160),
        targetFrameRate: 30
    )
    public static let qhd60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 2560, height: 1440),
        targetFrameRate: 60
    )
    public static let qhd30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 2560, height: 1440),
        targetFrameRate: 30
    )
    public static let fullHD60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 1920, height: 1080),
        targetFrameRate: 60
    )
    public static let fullHD30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 1920, height: 1080),
        targetFrameRate: 30
    )

    public static let defaultDescendingTiers: [MirageAutomaticDesktopWorkloadTier] = [
        .fourK60,
        .fourK30,
        .qhd60,
        .qhd30,
        .fullHD60,
        .fullHD30,
    ]
}

public struct MirageStreamPipelineHealth: Sendable, Equatable {
    public let bottleneckKind: MirageStreamBottleneckKind
    public let transportIsClean: Bool
    public let observedPixelRate: Double?
    public let hostPipelinePixelRate: Double?
    public let currentTier: MirageAutomaticDesktopWorkloadTier?

    public var isPipelineBound: Bool {
        switch bottleneckKind {
        case .captureBound, .encodeBound, .hostCadenceLimited, .decodeBound, .presentationBound, .mixed:
            true
        case .networkBound, .unknown:
            false
        }
    }

    public var isHostPipelineBound: Bool {
        guard let currentTier, let hostPipelinePixelRate else { return false }
        switch bottleneckKind {
        case .captureBound, .encodeBound, .hostCadenceLimited:
            return true
        case .mixed:
            return hostPipelinePixelRate < currentTier.pixelRate * 0.90
        case .decodeBound, .presentationBound, .networkBound, .unknown:
            return false
        }
    }

    public var isClientPipelineBound: Bool {
        guard let currentTier, let observedPixelRate else { return false }
        switch bottleneckKind {
        case .decodeBound, .presentationBound:
            return true
        case .mixed:
            return observedPixelRate < currentTier.pixelRate * 0.90
        case .captureBound, .encodeBound, .hostCadenceLimited, .networkBound, .unknown:
            return false
        }
    }

    public static func evaluate(snapshot: MirageClientMetricsSnapshot?) -> MirageStreamPipelineHealth {
        guard let snapshot else {
            return MirageStreamPipelineHealth(
                bottleneckKind: .unknown,
                transportIsClean: false,
                observedPixelRate: nil,
                hostPipelinePixelRate: nil,
                currentTier: nil
            )
        }

        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: max(0, snapshot.hostSendQueueBytes ?? 0),
                queueStressBytes: 800_000,
                queueSevereBytes: 2_000_000,
                packetPacerAverageSleepMs: max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0),
                packetPacerStressThresholdMs: 0.75,
                packetPacerSevereThresholdMs: 2.0,
                sendStartDelayAverageMs: max(0, snapshot.hostSendStartDelayAverageMs ?? 0),
                sendStartDelayStressThresholdMs: 2.0,
                sendStartDelaySevereThresholdMs: 6.0,
                sendCompletionAverageMs: max(0, snapshot.hostSendCompletionAverageMs ?? 0),
                sendCompletionStressThresholdMs: 12.0,
                sendCompletionSevereThresholdMs: 28.0,
                transportDropCount: snapshot.hostStalePacketDrops ?? 0,
                transportDropSevereCount: 12
            )
        )

        let currentTier: MirageAutomaticDesktopWorkloadTier? = if let width = snapshot.hostEncodedWidth,
            let height = snapshot.hostEncodedHeight,
            width > 0,
            height > 0 {
            MirageAutomaticDesktopWorkloadTier(
                encodedPixelSize: CGSize(width: width, height: height),
                targetFrameRate: snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60
            )
        } else {
            nil
        }

        let hostCadence = minimumPositive([
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS,
        ])
        let presentedCadence = minimumPositive([
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS,
            snapshot.decodedFPS,
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
        ])
        let hostPipelinePixelRate = if let currentTier, let hostCadence {
            Double(max(1, Int(currentTier.encodedPixelSize.width))) *
                Double(max(1, Int(currentTier.encodedPixelSize.height))) *
                hostCadence
        } else {
            Optional<Double>.none
        }
        let observedPixelRate = if let currentTier, let presentedCadence {
            Double(max(1, Int(currentTier.encodedPixelSize.width))) *
                Double(max(1, Int(currentTier.encodedPixelSize.height))) *
                presentedCadence
        } else {
            Optional<Double>.none
        }

        return MirageStreamPipelineHealth(
            bottleneckKind: snapshot.bottleneckKind,
            transportIsClean: !transportAssessment.isStress && !transportAssessment.isDelayOnlyBurst,
            observedPixelRate: observedPixelRate,
            hostPipelinePixelRate: hostPipelinePixelRate,
            currentTier: currentTier
        )
    }

    private static func minimumPositive(_ values: [Double?]) -> Double? {
        values
            .compactMap { $0 }
            .filter { $0 > 0 }
            .min()
    }
}

public struct MirageAutomaticDesktopWorkloadController: Sendable {
    public enum Action: Sendable, Equatable {
        case none
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

    public init() {}

    public mutating func reset() {
        pipelinePressureSampleCount = 0
        presentationCollapseSampleCount = 0
        promotionSampleCount = 0
        lastReconfigurationAt = nil
    }

    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        resizeCriticalSectionActive: Bool,
        minimumTargetFrameRate: Int = 30,
        maximumTargetFrameRate: Int = 60,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard !resizeCriticalSectionActive else {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            return .none
        }

        let health = MirageStreamPipelineHealth.evaluate(snapshot: snapshot)
        guard health.transportIsClean,
              let currentTier = health.currentTier else {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            promotionSampleCount = 0
            return .none
        }

        if health.isClientPipelineBound {
            guard let observedPixelRate = health.observedPixelRate else {
                pipelinePressureSampleCount = 0
                presentationCollapseSampleCount = 0
                promotionSampleCount = 0
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
                  let targetTier = Self.targetTier(
                      currentTier: currentTier,
                      pipelinePixelRate: observedPixelRate,
                      minimumTargetFrameRate: minimumTargetFrameRate,
                      maximumTargetFrameRate: maximumTargetFrameRate
                  ) else {
                return .none
            }

            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            lastReconfigurationAt = now
            let reasonPrefix = requiredSamples == Self.requiredPresentationCollapseSamples
                ? "client presentation collapse"
                : health.bottleneckKind.rawValue
            let reason = "\(reasonPrefix), client presented \(Int(observedPixelRate)) px/s"
            return .reconfigure(target: targetTier, reason: reason)
        }

        if !health.isPipelineBound {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            promotionSampleCount += 1
            guard promotionSampleCount >= Self.requiredPromotionSamples,
                  cooldownElapsed(now: now),
                  let targetTier = Self.nextHigherTier(
                      after: currentTier,
                      maximumTargetFrameRate: maximumTargetFrameRate
                  ) else {
                return .none
            }
            promotionSampleCount = 0
            lastReconfigurationAt = now
            return .reconfigure(target: targetTier, reason: "sustained clean transport and host cadence")
        }

        guard let hostPipelinePixelRate = health.hostPipelinePixelRate else {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            promotionSampleCount = 0
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
        guard let targetTier = Self.targetTier(
            currentTier: currentTier,
            pipelinePixelRate: hostPipelinePixelRate,
            minimumTargetFrameRate: minimumTargetFrameRate,
            maximumTargetFrameRate: maximumTargetFrameRate
        ) else {
            return .none
        }

        pipelinePressureSampleCount = 0
        presentationCollapseSampleCount = 0
        lastReconfigurationAt = now
        let reason = "\(health.bottleneckKind.rawValue), host pipeline \(Int(hostPipelinePixelRate)) px/s"
        return .reconfigure(target: targetTier, reason: reason)
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
        if let sameResolutionFrameRateTier = sameResolutionFrameRateRecoveryTier(
            currentTier: currentTier,
            observedPixelRate: pipelinePixelRate,
            minimumTargetFrameRate: normalizedMinimumTargetFrameRate,
            maximumTargetFrameRate: normalizedMaximumTargetFrameRate
        ) {
            return sameResolutionFrameRateTier
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

    private static func sameResolutionFrameRateRecoveryTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        observedPixelRate: Double,
        minimumTargetFrameRate: Int,
        maximumTargetFrameRate: Int
    ) -> MirageAutomaticDesktopWorkloadTier? {
        guard currentTier.targetFrameRate > 60 else { return nil }
        let candidateFrameRates = [90, 60, 30, 20].filter {
            $0 >= minimumTargetFrameRate &&
                $0 <= maximumTargetFrameRate &&
                $0 < currentTier.targetFrameRate
        }
        for frameRate in candidateFrameRates {
            let tier = MirageAutomaticDesktopWorkloadTier(
                encodedPixelSize: currentTier.encodedPixelSize,
                targetFrameRate: frameRate
            )
            if tier.pixelRate <= observedPixelRate {
                return tier
            }
        }
        return nil
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
        let hostCadence = minPositive(
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS
        ) ?? 0
        let clientCadence = minPositive(
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
            snapshot.clientPresentedFPS > 0 ? snapshot.clientPresentedFPS : nil,
            snapshot.clientLayerAcceptedFPS > 0 ? snapshot.clientLayerAcceptedFPS : nil
        ) ?? 0
        guard hostCadence >= targetFPS * 0.85 else { return false }
        guard snapshot.decodedFPS >= targetFPS * 0.60 else { return false }
        guard clientCadence > 0, clientCadence <= targetFPS * 0.72 else { return false }

        let frameBudgetMs = 1_000.0 / targetFPS
        return snapshot.clientPendingFrameAgeMs >= max(28.0, frameBudgetMs * 3.0) ||
            snapshot.clientOverwrittenPendingFrames >= 3 ||
            snapshot.clientDisplayLayerNotReadyCount >= 2 ||
            snapshot.clientFrameIntervalP99Ms >= max(36.0, frameBudgetMs * 4.0) ||
            snapshot.clientWorstPresentationGapMs >= max(120.0, frameBudgetMs * 10.0)
    }

    private static func minPositive(_ values: Double?...) -> Double? {
        values.compactMap { $0 }.filter { $0 > 0 }.min()
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
        let candidateFrameRates = [20, 30, 60, 90, 120].filter {
            $0 > currentTier.targetFrameRate && $0 <= maximumTargetFrameRate
        }
        guard let frameRate = candidateFrameRates.first else { return nil }
        return MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: currentTier.encodedPixelSize,
            targetFrameRate: frameRate
        )
    }
}
