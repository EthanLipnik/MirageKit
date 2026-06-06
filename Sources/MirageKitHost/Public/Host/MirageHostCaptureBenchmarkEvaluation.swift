//
//  MirageHostCaptureBenchmarkEvaluation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation
@_spi(HostApp) import MirageDiagnostics

#if os(macOS)
/// Validation status for the virtual display acquired for a benchmark stage.
enum MirageHostCaptureBenchmarkDisplayValidationResult: Equatable {
    case exact
    case accepted(actualWidth: Int, actualHeight: Int)
    case invalid(String)
}

/// Validates whether the acquired display mode can be used for a requested benchmark stage.
func captureBenchmarkDisplayValidationResult(
    requestedStage: MirageDiagnostics.MirageHostCaptureBenchmarkStage,
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
    displayPhase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult?,
    targetFrameRate: Int
) -> Double? {
    guard let measuredFloor = displayPhase?.deliveryCapabilityFPS else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

/// Returns the lowest measured throughput across display capture, delivery, and encode phases.
func captureBenchmarkValidatedCapabilityFPS(
    displayPhase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?,
    targetFrameRate: Int
) -> Double? {
    let measurements = [
        displayPhase?.ingressCapabilityFPS,
        displayPhase?.deliveryCapabilityFPS,
        encodeFPS,
    ].compactMap(\.self)
    guard let measuredFloor = measurements.min() else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

/// Classifies the first benchmark phase below the sustained target threshold.
func captureBenchmarkBottleneck(
    stage: MirageDiagnostics.MirageHostCaptureBenchmarkStage,
    displayPhase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?
) -> MirageDiagnostics.MirageHostCaptureBenchmarkBottleneck? {
    let targetThreshold = captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)

    if let displayIngressFPS = displayPhase?.ingressCapabilityFPS, displayIngressFPS < targetThreshold {
        return .displayIngress
    }
    if let displayDeliveryFPS = displayPhase?.deliveryCapabilityFPS, displayDeliveryFPS < targetThreshold {
        return .displayDelivery
    }
    if let encodeFPS, encodeFPS < targetThreshold {
        return .encode
    }

    let hasMeasurement = displayPhase != nil ||
        encodeFPS != nil
    return hasMeasurement ? .balanced : nil
}

#endif
