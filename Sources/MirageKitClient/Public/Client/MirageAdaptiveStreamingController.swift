//
//  MirageAdaptiveStreamingController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
//
//  Unified adaptive streaming workload policy.
//

import CoreGraphics
import Foundation
import MirageKit

public enum MirageAdaptiveStreamingRecoveryPhase: String, Sendable, Equatable {
    case startupAdmission
    case steady
    case freshnessCatchUp
    case dependencyRepair
    case encoderOnlyRelief
    case mediaRestart
    case degraded
}

public enum MirageAdaptiveStreamingRecoveryTrigger: String, Sendable, Equatable {
    case cleanPromotion
    case clientPresentationPressure
    case hostPipelinePressure
    case memoryPressure
    case manual
}

package enum MirageDependencyInvalidationReason: String, Sendable, Equatable {
    case fragmentLoss
    case fragmentTimeout
    case decryptFailure
    case checksumFailure
    case badData
    case malformedKeyframe
    case decoderFormatChange
    case epochReset
    case dimensionTokenChange
}

package enum MirageTopologyMutationReason: String, Sendable, Equatable {
    case explicitUserAction
    case prePresentationStartupRecovery
    case provenDisplayLoss
    case automaticDesktopRecovery
    case captureCadenceRecovery
    case desktopResize
}

public struct MirageStreamingHealthSample: Sendable, Equatable {
    public let bottleneckKind: MirageStreamBottleneckKind
    public let transportIsClean: Bool
    public let observedPixelRate: Double?
    public let hostPipelinePixelRate: Double?
    public let currentTier: MirageAutomaticDesktopWorkloadTier?

    public init(
        bottleneckKind: MirageStreamBottleneckKind,
        transportIsClean: Bool,
        observedPixelRate: Double?,
        hostPipelinePixelRate: Double?,
        currentTier: MirageAutomaticDesktopWorkloadTier?
    ) {
        self.bottleneckKind = bottleneckKind
        self.transportIsClean = transportIsClean
        self.observedPixelRate = observedPixelRate
        self.hostPipelinePixelRate = hostPipelinePixelRate
        self.currentTier = currentTier
    }

    init(health: MirageStreamPipelineHealth) {
        self.init(
            bottleneckKind: health.bottleneckKind,
            transportIsClean: health.transportIsClean,
            observedPixelRate: health.observedPixelRate,
            hostPipelinePixelRate: health.hostPipelinePixelRate,
            currentTier: health.currentTier
        )
    }
}

public struct MirageWorkloadVector: Sendable, Equatable {
    public let tier: MirageAutomaticDesktopWorkloadTier
    public let phase: MirageAdaptiveStreamingRecoveryPhase
    public let trigger: MirageAdaptiveStreamingRecoveryTrigger
    public let encodedPixelRatio: Double
    public let pixelRateRatio: Double
    public let qualityMultiplier: Double

    public var encodedPixelSize: CGSize {
        tier.encodedPixelSize
    }

    public var targetFrameRate: Int {
        tier.targetFrameRate
    }

    public var logLabel: String {
        "\(tier.logLabel) phase=\(phase.rawValue) trigger=\(trigger.rawValue)"
    }

    init(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        targetTier: MirageAutomaticDesktopWorkloadTier,
        phase: MirageAdaptiveStreamingRecoveryPhase,
        trigger: MirageAdaptiveStreamingRecoveryTrigger
    ) {
        let currentPixels = Self.pixelCount(currentTier.encodedPixelSize)
        let targetPixels = Self.pixelCount(targetTier.encodedPixelSize)
        let pixelRateRatio = targetTier.pixelRate / max(1.0, currentTier.pixelRate)
        self.tier = targetTier
        self.phase = phase
        self.trigger = trigger
        self.encodedPixelRatio = targetPixels / currentPixels
        self.pixelRateRatio = pixelRateRatio
        self.qualityMultiplier = min(1.0, max(0.55, pixelRateRatio))
    }

    private static func pixelCount(_ size: CGSize) -> Double {
        Double(max(1, Int(size.width))) * Double(max(1, Int(size.height)))
    }
}

public struct MirageAdaptiveStreamingController: Sendable {
    public enum Action: Sendable, Equatable {
        case none
        case reconfigure(vector: MirageWorkloadVector, reason: String)
    }

    private var workloadController = MirageAutomaticDesktopWorkloadController()
    public private(set) var lastHealthSample: MirageStreamingHealthSample?

    public init() {}

    public mutating func reset() {
        workloadController.reset()
        lastHealthSample = nil
    }

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
        let health = MirageStreamPipelineHealth.evaluate(
            snapshot: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        lastHealthSample = MirageStreamingHealthSample(health: health)
        let action = workloadController.advance(
            snapshot: snapshot,
            resizeCriticalSectionActive: resizeCriticalSectionActive,
            minimumTargetFrameRate: minimumTargetFrameRate,
            maximumTargetFrameRate: maximumTargetFrameRate,
            minimumHealthyFrameRate: minimumHealthyFrameRate,
            adaptivePriority: adaptivePriority,
            preferredMaximumTier: preferredMaximumTier,
            now: now
        )

        guard case .reconfigure(let target, let reason) = action,
              let currentTier = health.currentTier else {
            return .none
        }

        let trigger: MirageAdaptiveStreamingRecoveryTrigger
        if health.isClientPipelineBound {
            trigger = .clientPresentationPressure
        } else if health.isPipelineBound {
            trigger = .hostPipelinePressure
        } else {
            trigger = .cleanPromotion
        }

        let vector = MirageWorkloadVector(
            currentTier: currentTier,
            targetTier: target,
            phase: target.pixelRate < currentTier.pixelRate ? .encoderOnlyRelief : .steady,
            trigger: trigger
        )
        return .reconfigure(vector: vector, reason: reason)
    }
}
