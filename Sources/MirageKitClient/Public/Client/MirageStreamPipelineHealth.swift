//
//  MirageStreamPipelineHealth.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

/// Returns the smallest positive sample from a sparse cadence list.
func minimumPositive(_ values: Double?...) -> Double? {
    values.compactMap(\.self).filter { $0 > 0 }.min()
}

/// Clamps an optional health floor to the requested stream frame rate.
func effectiveHealthFrameRate(
    requestedTargetFrameRate: Int,
    minimumHealthyFrameRate: Int?
) -> Int {
    let requestedTargetFrameRate = max(1, requestedTargetFrameRate)
    guard let minimumHealthyFrameRate else { return requestedTargetFrameRate }
    return min(requestedTargetFrameRate, max(1, minimumHealthyFrameRate))
}

/// Summary of whether a desktop stream appears constrained by host work, client work, or transport.
public struct MirageStreamPipelineHealth: Sendable, Equatable {
    /// Bottleneck classification reported by the client metrics snapshot.
    public let bottleneckKind: MirageStreamBottleneckKind

    /// Whether transport pressure is low enough for workload changes to be meaningful.
    public let transportIsClean: Bool

    /// Client-presented encoded pixel throughput in pixels per second, when measurable.
    public let observedPixelRate: Double?

    /// Host-produced encoded pixel throughput in pixels per second, when measurable.
    public let hostPipelinePixelRate: Double?

    /// The stream's current encoded-size and frame-rate tier, when host dimensions are known.
    public let currentTier: MirageAutomaticDesktopWorkloadTier?
    let sourceCadenceDeficient: Bool
    let clientPipelineDeficient: Bool
    let minimumHealthyFrameRate: Int
    let usesVariableHighRefreshFloor: Bool

    /// Whether the current metrics should be treated as pipeline-bound.
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

    /// Whether the host-side capture or encode pipeline is the likely limiter.
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
            let hostPipelineFPS = if let currentTier, let hostPipelinePixelRate {
                hostPipelinePixelRate / currentTier.encodedPixelCount
            } else {
                0.0
            }
            return sourceCadenceDeficient || hostPipelineFPS < Double(frameRateFloor) * 0.90
        case .decodeBound, .presentationBound, .networkBound, .unknown:
            return false
        }
    }

    /// Whether decode or presentation on the client is the likely limiter.
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

    /// Builds a health summary from the latest client metrics snapshot.
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
                packetPacerAverageSleepMs: max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0),
                packetPacerStressThresholdMs: 0.75,
                sendStartDelayAverageMs: max(0, snapshot.hostSendStartDelayAverageMs ?? 0),
                sendStartDelayStressThresholdMs: 2.0,
                sendCompletionAverageMs: max(0, snapshot.hostSendCompletionAverageMs ?? 0),
                sendCompletionStressThresholdMs: 12.0,
                transportDropCount: snapshot.hostTransportPressureDropCount
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

        let hostCadence = minimumPositive(
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS
        )
        let presentedCadence = minimumPositive(
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
            snapshot.hostEncodedFPS,
            snapshot.decodedFPS,
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS
        )
        let hostPipelinePixelRate = if let currentTier, let hostCadence {
            currentTier.pixelRate(at: hostCadence)
        } else {
            Double?.none
        }
        let observedPixelRate = if let currentTier, let presentedCadence {
            currentTier.pixelRate(at: presentedCadence)
        } else {
            Double?.none
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
            transportIsClean: !transportAssessment.primaryStress && !transportAssessment.isDelayOnlyBurst,
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
        let frameBudgetMs = 1000.0 / targetFPS
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
        let frameBudgetMs = 1000.0 / targetFPS
        let clientCadence = minimumPositive(
            snapshot.decodedFPS,
            snapshot.submittedFPS,
            snapshot.uniqueSubmittedFPS,
            snapshot.clientPresentedFPS > 0 ? snapshot.clientPresentedFPS : nil,
            snapshot.clientLayerAcceptedFPS > 0 ? snapshot.clientLayerAcceptedFPS : nil
        ) ?? 0
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
}
