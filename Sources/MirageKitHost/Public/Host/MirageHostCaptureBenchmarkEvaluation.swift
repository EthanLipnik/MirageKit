//
//  MirageHostCaptureBenchmarkEvaluation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation

#if os(macOS)
/// Validation status for the virtual display acquired for a benchmark stage.
enum MirageHostCaptureBenchmarkDisplayValidationResult: Equatable {
    case exact
    case accepted(actualWidth: Int, actualHeight: Int)
    case invalid(String)
}

/// Validates whether the acquired display mode can be used for a requested benchmark stage.
func captureBenchmarkDisplayValidationResult(
    requestedStage: MirageHostCaptureBenchmarkStage,
    actualResolution: CGSize,
    actualRefreshRate: Double
) -> MirageHostCaptureBenchmarkDisplayValidationResult {
    let actualWidth = Int(actualResolution.width.rounded())
    let actualHeight = Int(actualResolution.height.rounded())
    let actualRefresh = Int(actualRefreshRate.rounded())

    guard actualRefresh == requestedStage.refreshRate else {
        return .invalid(
            "Requested \(requestedStage.refreshRate)Hz but acquired \(actualRefresh)Hz."
        )
    }

    if actualWidth == requestedStage.pixelWidth, actualHeight == requestedStage.pixelHeight {
        return .exact
    }

    return .accepted(actualWidth: actualWidth, actualHeight: actualHeight)
}

let captureBenchmarkValidThresholdFPS: Double = 60

/// Returns the frame-rate threshold treated as sustained target performance.
func captureBenchmarkSustainThreshold(targetFrameRate: Int) -> Double {
    Double(targetFrameRate) * 0.95
}

/// Returns whether the observed source-window frame matches the prepared benchmark frame.
func captureBenchmarkSourceFrameMatchesExpected(
    expectedFrame: CGRect,
    actualFrame: CGRect,
    pointTolerance: CGFloat = 2
) -> Bool {
    let expectedWidth = max(1, expectedFrame.width.rounded())
    let expectedHeight = max(1, expectedFrame.height.rounded())
    let actualWidth = max(1, actualFrame.width.rounded())
    let actualHeight = max(1, actualFrame.height.rounded())

    return abs(actualWidth - expectedWidth) <= pointTolerance &&
        abs(actualHeight - expectedHeight) <= pointTolerance
}

/// Returns the user-facing reason a benchmark measurement cannot be trusted.
func captureBenchmarkInvalidMeasurementReason(
    displayValidationResult: MirageHostCaptureBenchmarkDisplayValidationResult? = nil,
    displayCadenceProbeFailed: Bool = false,
    startupReadiness: DisplayCaptureStartupReadiness? = nil
) -> String? {
    if case let .invalid(reason)? = displayValidationResult {
        return reason
    }

    if displayCadenceProbeFailed {
        return "Display cadence probe failed to attach to the benchmark display."
    }

    if let startupReadiness {
        switch startupReadiness {
        case .blankOrSuspendedOnly:
            return "Capture startup only produced blank or suspended frames."
        case .noScreenSamples:
            return "Capture startup did not produce screen samples."
        case .usableFrameSeen, .idleFrameSeen:
            break
        }
    }

    return nil
}

/// Caps measured display-capture capability to the stage target frame rate.
func captureBenchmarkDisplayCapabilityFPS(
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    targetFrameRate: Int
) -> Double? {
    guard let measuredFloor = displayPhase?.deliveryCapabilityFPS else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

/// Returns the lowest measured throughput across source, capture, delivery, and encode phases.
func captureBenchmarkValidatedCapabilityFPS(
    sourceGenerationFPS: Double?,
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?,
    targetFrameRate: Int
) -> Double? {
    let measurements = [
        sourceGenerationFPS,
        sourcePhase?.ingressCapabilityFPS,
        sourcePhase?.deliveryCapabilityFPS,
        displayPhase?.ingressCapabilityFPS,
        displayPhase?.deliveryCapabilityFPS,
        encodeFPS,
    ].compactMap(\.self)
    guard let measuredFloor = measurements.min() else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

/// Classifies the first benchmark phase below the sustained target threshold.
func captureBenchmarkBottleneck(
    stage: MirageHostCaptureBenchmarkStage,
    sourceGenerationFPS: Double?,
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?
) -> MirageHostCaptureBenchmarkBottleneck? {
    let targetThreshold = captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)

    if let sourceGenerationFPS, sourceGenerationFPS < targetThreshold {
        return .sourceGeneration
    }
    if let sourceIngressFPS = sourcePhase?.ingressCapabilityFPS, sourceIngressFPS < targetThreshold {
        return .windowIngress
    }
    if let sourceDeliveryFPS = sourcePhase?.deliveryCapabilityFPS, sourceDeliveryFPS < targetThreshold {
        return .windowDelivery
    }
    if let displayIngressFPS = displayPhase?.ingressCapabilityFPS, displayIngressFPS < targetThreshold {
        return .displayIngress
    }
    if let displayDeliveryFPS = displayPhase?.deliveryCapabilityFPS, displayDeliveryFPS < targetThreshold {
        return .displayDelivery
    }
    if let encodeFPS, encodeFPS < targetThreshold {
        return .encode
    }

    let hasMeasurement = sourceGenerationFPS != nil ||
        sourcePhase != nil ||
        displayPhase != nil ||
        encodeFPS != nil
    return hasMeasurement ? .balanced : nil
}

/// Summarizes the highest completed benchmark stages that meet validity and sustain thresholds.
func captureBenchmarkSummary(
    stageResults: [MirageHostCaptureBenchmarkStageResult]
) -> MirageHostCaptureBenchmarkSummary {
    let targetFrameRate = stageResults.last?.stage.targetFrameRate ??
        MirageHostCaptureBenchmarkStage.allStages.last?.targetFrameRate ?? 120
    let validThreshold = captureBenchmarkValidThresholdFPS
    let threshold = captureBenchmarkSustainThreshold(targetFrameRate: targetFrameRate)
    let highestValidStage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.validatedCapabilityFPS ?? 0) >= validThreshold
    })
    let highest120Stage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.validatedCapabilityFPS ?? 0) >= threshold
    })

    return MirageHostCaptureBenchmarkSummary(
        targetFrameRate: targetFrameRate,
        validThresholdFPS: validThreshold,
        sustainThresholdFPS: threshold,
        highestValidStageID: highestValidStage?.stage.id,
        highestValidStageTitle: highestValidStage?.stage.title,
        highestValidResolution: highestValidStage?.stage.pixelDescription,
        highest120FPSStageID: highest120Stage?.stage.id,
        highest120FPSStageTitle: highest120Stage?.stage.title,
        highest120FPSResolution: highest120Stage?.stage.pixelDescription
    )
}
#endif
