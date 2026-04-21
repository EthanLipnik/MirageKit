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
    public let currentTier: MirageAutomaticDesktopWorkloadTier?

    public var isPipelineBound: Bool {
        switch bottleneckKind {
        case .captureBound, .encodeBound, .decodeBound, .presentationBound, .mixed:
            true
        case .networkBound, .unknown:
            false
        }
    }

    public static func evaluate(snapshot: MirageClientMetricsSnapshot?) -> MirageStreamPipelineHealth {
        guard let snapshot else {
            return MirageStreamPipelineHealth(
                bottleneckKind: .unknown,
                transportIsClean: false,
                observedPixelRate: nil,
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

        let cadence = minimumPositive([
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS,
            snapshot.decodedFPS,
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
        ])
        let observedPixelRate = if let currentTier, let cadence {
            Double(max(1, Int(currentTier.encodedPixelSize.width))) *
                Double(max(1, Int(currentTier.encodedPixelSize.height))) *
                cadence
        } else {
            Optional<Double>.none
        }

        return MirageStreamPipelineHealth(
            bottleneckKind: snapshot.bottleneckKind,
            transportIsClean: !transportAssessment.isStress && !transportAssessment.isDelayOnlyBurst,
            observedPixelRate: observedPixelRate,
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

    private static let requiredPipelinePressureSamples = 3
    private static let reconfigurationCooldownSeconds: CFAbsoluteTime = 20
    private static let observedPixelRateSafetyFactor = 0.85

    private var pipelinePressureSampleCount = 0
    private var lastReconfigurationAt: CFAbsoluteTime?

    public init() {}

    public mutating func reset() {
        pipelinePressureSampleCount = 0
        lastReconfigurationAt = nil
    }

    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        resizeCriticalSectionActive: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard !resizeCriticalSectionActive else {
            pipelinePressureSampleCount = 0
            return .none
        }

        let health = MirageStreamPipelineHealth.evaluate(snapshot: snapshot)
        guard health.transportIsClean,
              health.isPipelineBound,
              let observedPixelRate = health.observedPixelRate,
              let currentTier = health.currentTier else {
            pipelinePressureSampleCount = 0
            return .none
        }

        pipelinePressureSampleCount += 1
        guard pipelinePressureSampleCount >= Self.requiredPipelinePressureSamples else {
            return .none
        }
        if let lastReconfigurationAt,
           now - lastReconfigurationAt < Self.reconfigurationCooldownSeconds {
            return .none
        }
        guard let targetTier = Self.targetTier(
            currentTier: currentTier,
            observedPixelRate: observedPixelRate
        ) else {
            return .none
        }

        pipelinePressureSampleCount = 0
        lastReconfigurationAt = now
        let reason = "\(health.bottleneckKind.rawValue), observed \(Int(observedPixelRate)) px/s"
        return .reconfigure(target: targetTier, reason: reason)
    }

    private static func targetTier(
        currentTier: MirageAutomaticDesktopWorkloadTier,
        observedPixelRate: Double
    ) -> MirageAutomaticDesktopWorkloadTier? {
        let sustainablePixelRate = observedPixelRate * observedPixelRateSafetyFactor
        let eligibleTier = MirageAutomaticDesktopWorkloadTier.defaultDescendingTiers.first { tier in
            tier.pixelRate <= sustainablePixelRate
        } ?? MirageAutomaticDesktopWorkloadTier.defaultDescendingTiers.last

        guard let eligibleTier else { return nil }
        guard eligibleTier.pixelRate < currentTier.pixelRate else { return nil }
        return eligibleTier
    }
}
