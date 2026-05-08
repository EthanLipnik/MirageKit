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
    let sourceCadenceDeficient: Bool
    let clientPipelineDeficient: Bool
    let minimumHealthyFrameRate: Int
    let usesVariableHighRefreshFloor: Bool

    public var isPipelineBound: Bool {
        switch bottleneckKind {
        case .captureBound, .encodeBound:
            true
        case .hostCadenceLimited:
            usesVariableHighRefreshFloor ? sourceCadenceDeficient : true
        case .decodeBound, .presentationBound:
            clientPipelineDeficient
        case .mixed:
            sourceCadenceDeficient || clientPipelineDeficient
        case .networkBound, .unknown:
            false
        }
    }

    public var isHostPipelineBound: Bool {
        guard currentTier != nil, hostPipelinePixelRate != nil else { return false }
        switch bottleneckKind {
        case .captureBound, .encodeBound:
            return true
        case .hostCadenceLimited:
            return usesVariableHighRefreshFloor ? sourceCadenceDeficient : true
        case .mixed:
            let frameRateFloor = usesVariableHighRefreshFloor
                ? minimumHealthyFrameRate
                : (currentTier?.targetFrameRate ?? minimumHealthyFrameRate)
            return sourceCadenceDeficient || hostPipelineFPS < Double(frameRateFloor) * 0.90
        case .decodeBound, .presentationBound, .networkBound, .unknown:
            return false
        }
    }

    public var isClientPipelineBound: Bool {
        guard currentTier != nil, observedPixelRate != nil else { return false }
        switch bottleneckKind {
        case .decodeBound, .presentationBound:
            return clientPipelineDeficient
        case .mixed:
            return !sourceCadenceDeficient && clientPipelineDeficient
        case .captureBound, .encodeBound, .hostCadenceLimited, .networkBound, .unknown:
            return false
        }
    }

    private var hostPipelineFPS: Double {
        guard let currentTier, let hostPipelinePixelRate else { return 0 }
        return hostPipelinePixelRate / max(1.0, currentTier.pixelRate / Double(max(1, currentTier.targetFrameRate)))
    }

    public static func evaluate(
        snapshot: MirageClientMetricsSnapshot?,
        minimumHealthyFrameRate: Int? = nil
    ) -> MirageStreamPipelineHealth {
        guard let snapshot else {
            return MirageStreamPipelineHealth(
                bottleneckKind: .unknown,
                transportIsClean: false,
                observedPixelRate: nil,
                hostPipelinePixelRate: nil,
                currentTier: nil,
                sourceCadenceDeficient: false,
                clientPipelineDeficient: false,
                minimumHealthyFrameRate: 60,
                usesVariableHighRefreshFloor: false
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
        let requestedTargetFrameRate = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let effectiveMinimumHealthyFrameRate = effectiveHealthFrameRate(
            requestedTargetFrameRate: requestedTargetFrameRate,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        let usesVariableHighRefreshFloor = requestedTargetFrameRate >= 90 &&
            effectiveMinimumHealthyFrameRate < requestedTargetFrameRate

        return MirageStreamPipelineHealth(
            bottleneckKind: snapshot.bottleneckKind,
            transportIsClean: !transportAssessment.isStress && !transportAssessment.isDelayOnlyBurst,
            observedPixelRate: observedPixelRate,
            hostPipelinePixelRate: hostPipelinePixelRate,
            currentTier: currentTier,
            sourceCadenceDeficient: sourceCadenceDeficient(
                snapshot: snapshot,
                minimumHealthyFrameRate: effectiveMinimumHealthyFrameRate
            ),
            clientPipelineDeficient: clientPipelineDeficient(
                snapshot: snapshot,
                minimumHealthyFrameRate: effectiveMinimumHealthyFrameRate
            ),
            minimumHealthyFrameRate: effectiveMinimumHealthyFrameRate,
            usesVariableHighRefreshFloor: usesVariableHighRefreshFloor
        )
    }

    private static func sourceCadenceDeficient(
        snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int
    ) -> Bool {
        let targetFPS = Double(max(1, minimumHealthyFrameRate))
        let frameBudgetMs = 1_000.0 / targetFPS
        let lowSourceCadence = [
            snapshot.hostCaptureIngressFPS,
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
        ].contains { value in
            guard let value, value > 0 else { return false }
            return value < targetFPS * 0.85
        }
        let p99Gap = max(
            snapshot.hostCaptureDeliveredFrameGapP99Ms ?? 0,
            snapshot.hostCaptureWallClockGapP99Ms ?? 0,
            snapshot.hostCaptureDisplayTimeGapP99Ms ?? 0
        )
        let worstGap = max(
            snapshot.hostCaptureDeliveredFrameGapWorstMs ?? 0,
            snapshot.hostCaptureWallClockGapWorstMs ?? 0,
            snapshot.hostCaptureDisplayTimeGapWorstMs ?? 0
        )
        return snapshot.hostCaptureVirtualDisplayTimingSuspect == true ||
            (snapshot.hostCaptureUsesDisplayRefreshCadence == true && lowSourceCadence) ||
            p99Gap >= max(35.0, frameBudgetMs * 2.0) ||
            worstGap >= max(70.0, frameBudgetMs * 4.0) ||
            (snapshot.hostCaptureLongFrameGapCount ?? 0) > 0
    }

    private static func clientPipelineDeficient(
        snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int
    ) -> Bool {
        let targetFPS = Double(max(1, minimumHealthyFrameRate))
        let frameBudgetMs = 1_000.0 / targetFPS
        let clientCadence = minimumPositive([
            snapshot.decodedFPS,
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
            snapshot.clientPresentedFPS > 0 ? snapshot.clientPresentedFPS : nil,
            snapshot.clientLayerAcceptedFPS > 0 ? snapshot.clientLayerAcceptedFPS : nil,
        ]) ?? 0
        let belowHealthFloor = clientCadence > 0 && clientCadence < targetFPS * 0.90
        let decodeFailed = !snapshot.decodeHealthy &&
            (snapshot.receivedFPS > 0 || snapshot.decodedFPS > 0)
        let presentationStalled =
            snapshot.clientPresentationStallCount > 0 ||
            snapshot.clientWorstPresentationGapMs >= max(120.0, frameBudgetMs * 6.0) ||
            snapshot.clientFrameIntervalP99Ms >= max(80.0, frameBudgetMs * 4.0) ||
            snapshot.clientDisplayTickIntervalP99Ms >= max(80.0, frameBudgetMs * 4.0) ||
            snapshot.clientPendingFrameAgeMs >= max(40.0, frameBudgetMs * 3.0) ||
            snapshot.clientOverwrittenPendingFrames >= 3 ||
            snapshot.clientDisplayLayerNotReadyCount >= 2
        return belowHealthFloor || decodeFailed || presentationStalled
    }

    private static func effectiveHealthFrameRate(
        requestedTargetFrameRate: Int,
        minimumHealthyFrameRate: Int?
    ) -> Int {
        let requestedTargetFrameRate = max(1, requestedTargetFrameRate)
        guard let minimumHealthyFrameRate else { return requestedTargetFrameRate }
        return min(requestedTargetFrameRate, max(1, minimumHealthyFrameRate))
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
        minimumHealthyFrameRate: Int? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard !resizeCriticalSectionActive else {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            return .none
        }

        let health = MirageStreamPipelineHealth.evaluate(
            snapshot: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        guard health.transportIsClean,
              let currentTier = health.currentTier else {
            pipelinePressureSampleCount = 0
            presentationCollapseSampleCount = 0
            promotionSampleCount = 0
            return .none
        }

        if health.sourceCadenceDeficient {
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
                  let targetTier = Self.clientPipelineTargetTier(
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

        let currentPixels = max(
            1.0,
            Double(max(1, Int(currentTier.encodedPixelSize.width))) *
                Double(max(1, Int(currentTier.encodedPixelSize.height)))
        )
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
        let currentPixels = max(
            1.0,
            Double(max(1, Int(currentTier.encodedPixelSize.width))) *
                Double(max(1, Int(currentTier.encodedPixelSize.height)))
        )
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
