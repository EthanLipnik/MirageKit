//
//  MirageHostCaptureBenchmarkResults.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

#if os(macOS)
/// Minimum validated frame rate considered usable for remote display capture.
package let captureBenchmarkValidThresholdFPS: Double = 60

/// Returns the frame-rate threshold treated as sustained target performance.
package func captureBenchmarkSustainThreshold(targetFrameRate: Int) -> Double {
    Double(targetFrameRate) * 0.95
}

/// Measured frame flow for one phase of a capture benchmark stage.
public struct MirageHostCaptureBenchmarkPhaseResult: Codable, Hashable, Sendable {
    /// Benchmark phase represented by these measurements.
    public let kind: MirageHostCaptureBenchmarkPhaseKind
    /// Raw ScreenCaptureKit callback rate before filtering unusable samples.
    public let rawIngressFPS: Double?
    /// Rate of callbacks that passed sample validation.
    public let validSampleFPS: Double?
    /// Rate of callbacks containing renderable frame content.
    public let renderableIngressFPS: Double?
    /// Rate of frames admitted by the capture cadence policy.
    public let cadenceAdmittedFPS: Double?
    /// Rate of frames delivered past capture filtering into the next stage.
    public let deliveryFPS: Double?
    /// Startup readiness inferred from the samples observed before measurement.
    public let startupReadiness: MirageHostCaptureBenchmarkStartupReadiness?
    /// Average ScreenCaptureKit callback processing time in milliseconds.
    public let averageCallbackTimeMs: Double?
    /// Maximum ScreenCaptureKit callback processing time in milliseconds.
    public let maximumCallbackTimeMs: Double?
    /// Total ScreenCaptureKit callbacks received.
    public let rawCallbackCount: UInt64
    /// Number of callbacks that passed sample validation.
    public let validSampleCount: UInt64
    /// Number of callbacks containing renderable frame content.
    public let renderableSampleCount: UInt64
    /// Number of complete frame samples received.
    public let completeSampleCount: UInt64
    /// Number of idle samples received.
    public let idleSampleCount: UInt64
    /// Number of blank samples received.
    public let blankSampleCount: UInt64
    /// Number of suspended samples received.
    public let suspendedSampleCount: UInt64
    /// Number of stream-started marker samples received.
    public let startedSampleCount: UInt64
    /// Number of stream-stopped marker samples received.
    public let stoppedSampleCount: UInt64
    /// Number of frames admitted by the capture cadence policy.
    public let cadenceAdmittedCount: UInt64
    /// Number of frames delivered past capture filtering into the next stage.
    public let deliveryCount: UInt64
    /// Number of frames dropped by capture cadence policy.
    public let cadenceDropCount: UInt64
    /// Number of frames dropped by capture admission control.
    public let admissionDropCount: UInt64

    /// Conservative ingress capability derived from raw and renderable rates.
    package var ingressCapabilityFPS: Double? {
        let measurements = [rawIngressFPS, renderableIngressFPS].compactMap(\.self)
        guard let measuredFloor = measurements.min() else { return nil }
        return measuredFloor
    }

    /// Conservative delivery capability derived from ingress and delivery rates.
    package var deliveryCapabilityFPS: Double? {
        let measurements = [ingressCapabilityFPS, deliveryFPS].compactMap(\.self)
        guard let measuredFloor = measurements.min() else { return nil }
        return measuredFloor
    }

    /// Creates phase measurements for a benchmark stage.
    public init(
        kind: MirageHostCaptureBenchmarkPhaseKind,
        rawIngressFPS: Double? = nil,
        validSampleFPS: Double? = nil,
        renderableIngressFPS: Double? = nil,
        cadenceAdmittedFPS: Double? = nil,
        deliveryFPS: Double? = nil,
        startupReadiness: MirageHostCaptureBenchmarkStartupReadiness? = nil,
        averageCallbackTimeMs: Double? = nil,
        maximumCallbackTimeMs: Double? = nil,
        rawCallbackCount: UInt64 = 0,
        validSampleCount: UInt64 = 0,
        renderableSampleCount: UInt64 = 0,
        completeSampleCount: UInt64 = 0,
        idleSampleCount: UInt64 = 0,
        blankSampleCount: UInt64 = 0,
        suspendedSampleCount: UInt64 = 0,
        startedSampleCount: UInt64 = 0,
        stoppedSampleCount: UInt64 = 0,
        cadenceAdmittedCount: UInt64 = 0,
        deliveryCount: UInt64 = 0,
        cadenceDropCount: UInt64 = 0,
        admissionDropCount: UInt64 = 0
    ) {
        self.kind = kind
        self.rawIngressFPS = rawIngressFPS
        self.validSampleFPS = validSampleFPS
        self.renderableIngressFPS = renderableIngressFPS
        self.cadenceAdmittedFPS = cadenceAdmittedFPS
        self.deliveryFPS = deliveryFPS
        self.startupReadiness = startupReadiness
        self.averageCallbackTimeMs = averageCallbackTimeMs
        self.maximumCallbackTimeMs = maximumCallbackTimeMs
        self.rawCallbackCount = rawCallbackCount
        self.validSampleCount = validSampleCount
        self.renderableSampleCount = renderableSampleCount
        self.completeSampleCount = completeSampleCount
        self.idleSampleCount = idleSampleCount
        self.blankSampleCount = blankSampleCount
        self.suspendedSampleCount = suspendedSampleCount
        self.startedSampleCount = startedSampleCount
        self.stoppedSampleCount = stoppedSampleCount
        self.cadenceAdmittedCount = cadenceAdmittedCount
        self.deliveryCount = deliveryCount
        self.cadenceDropCount = cadenceDropCount
        self.admissionDropCount = admissionDropCount
    }
}

/// Aggregate result describing the highest usable benchmark stages.
public struct MirageHostCaptureBenchmarkSummary: Codable, Hashable, Sendable {
    /// Target refresh rate measured by the benchmark run.
    public let targetFrameRate: Int
    /// Minimum validated frame rate considered usable for remote display capture.
    public let validThresholdFPS: Double
    /// Minimum validated frame rate considered sustained for the target refresh rate.
    public let sustainThresholdFPS: Double
    /// Identifier of the highest completed stage that met the usable capture threshold.
    public let highestValidStageID: String?
    /// Display title of the highest completed stage that met the usable capture threshold.
    public let highestValidStageTitle: String?
    /// Pixel resolution of the highest completed stage that met the usable capture threshold.
    public let highestValidResolution: String?
    /// Identifier of the highest completed stage that met the sustained target-rate threshold.
    public let highest120FPSStageID: String?
    /// Display title of the highest completed stage that met the sustained target-rate threshold.
    public let highest120FPSStageTitle: String?
    /// Pixel resolution of the highest completed stage that met the sustained target-rate threshold.
    public let highest120FPSResolution: String?

    /// Creates a benchmark summary from the highest validated stages.
    public init(
        targetFrameRate: Int,
        validThresholdFPS: Double,
        sustainThresholdFPS: Double,
        highestValidStageID: String?,
        highestValidStageTitle: String?,
        highestValidResolution: String?,
        highest120FPSStageID: String?,
        highest120FPSStageTitle: String?,
        highest120FPSResolution: String?
    ) {
        self.targetFrameRate = targetFrameRate
        self.validThresholdFPS = validThresholdFPS
        self.sustainThresholdFPS = sustainThresholdFPS
        self.highestValidStageID = highestValidStageID
        self.highestValidStageTitle = highestValidStageTitle
        self.highestValidResolution = highestValidResolution
        self.highest120FPSStageID = highest120FPSStageID
        self.highest120FPSStageTitle = highest120FPSStageTitle
        self.highest120FPSResolution = highest120FPSResolution
    }
}

/// Result for one resolution/cadence benchmark stage.
public struct MirageHostCaptureBenchmarkStageResult: Codable, Hashable, Sendable {
    /// Benchmark stage that produced this result.
    public let stage: MirageHostCaptureBenchmarkStage
    /// Final outcome for the benchmark stage.
    public let status: MirageHostCaptureBenchmarkStageStatus
    /// Actual captured display width in pixels when it differed from the requested stage.
    public let actualPixelWidth: Int?
    /// Actual captured display height in pixels when it differed from the requested stage.
    public let actualPixelHeight: Int?
    /// Refresh rate reported by the acquired display mode.
    public let reportedDisplayRefreshRate: Double?
    /// Observed display tick cadence during the stage.
    public let observedDisplayCadenceFPS: Double?
    /// Frame generation rate reported by the prepared benchmark source.
    public let sourceGenerationFPS: Double?
    /// Window-capture phase measurements for the prepared source.
    public let sourcePhase: MirageHostCaptureBenchmarkPhaseResult?
    /// Display-capture phase measurements for the target display.
    public let displayPhase: MirageHostCaptureBenchmarkPhaseResult?
    /// Encoder throughput measured while capture samples were flowing.
    public let encodeFPS: Double?
    /// Capture policy used for the source window phase.
    public let sourceCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
    /// Capture policy used for the display phase.
    public let displayCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
    /// Slowest measured subsystem for this stage.
    public let bottleneck: MirageHostCaptureBenchmarkBottleneck?
    /// Validated display-capture floor, clamped to the target frame rate.
    public let displayCaptureCapabilityFPS: Double?
    /// Overall validated streaming floor across display capture, delivery, and encoding.
    public let validatedCapabilityFPS: Double?
    /// Average encoder callback duration in milliseconds.
    public let averageEncodeTimeMs: Double?
    /// Non-fatal quality or measurement warnings produced by the stage.
    public let warnings: [MirageHostCaptureBenchmarkWarning]
    /// Explanation for completed measurements that should not be treated as valid capability data.
    public let invalidMeasurementReason: String?
    /// Explanation for stages skipped because the host could not acquire the requested mode.
    public let unsupportedReason: String?
    /// Human-readable failure description when the stage failed before producing measurements.
    public let failureDescription: String?

    /// Description of the actual display mode when it differed from the requested stage.
    public var actualDisplayModeDescription: String? {
        let pixelDescription: String? = {
            guard let actualPixelWidth, let actualPixelHeight else { return nil }
            let actual = "\(actualPixelWidth)x\(actualPixelHeight)"
            return actual != stage.pixelDescription ? actual : nil
        }()
        let refreshDescription: String? = {
            guard let reportedDisplayRefreshRate else { return nil }
            let roundedRefreshRate = Int(reportedDisplayRefreshRate.rounded())
            guard roundedRefreshRate != stage.refreshRate else { return nil }
            return "\(roundedRefreshRate)Hz"
        }()

        switch (pixelDescription, refreshDescription) {
        case let (.some(pixelDescription), .some(refreshRateDescription)):
            return "\(pixelDescription) @ \(refreshRateDescription)"
        case let (.some(pixelDescription), nil):
            return pixelDescription
        case let (nil, .some(refreshRateDescription)):
            return refreshRateDescription
        case (nil, nil):
            return nil
        }
    }

    /// Whether the validated capability reached the baseline remote display threshold.
    public var meets60FPS: Bool {
        (validatedCapabilityFPS ?? 0) >= captureBenchmarkValidThresholdFPS
    }

    /// Whether the validated capability sustained the target refresh-rate threshold.
    public var meets120FPS: Bool {
        guard let validatedCapabilityFPS else { return false }
        return validatedCapabilityFPS >= captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)
    }

    /// Creates a benchmark result for a single capture stage.
    public init(
        stage: MirageHostCaptureBenchmarkStage,
        status: MirageHostCaptureBenchmarkStageStatus,
        actualPixelWidth: Int? = nil,
        actualPixelHeight: Int? = nil,
        reportedDisplayRefreshRate: Double? = nil,
        observedDisplayCadenceFPS: Double? = nil,
        sourceGenerationFPS: Double? = nil,
        sourcePhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        displayPhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        encodeFPS: Double? = nil,
        sourceCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy? = nil,
        displayCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy? = nil,
        bottleneck: MirageHostCaptureBenchmarkBottleneck? = nil,
        displayCaptureCapabilityFPS: Double? = nil,
        validatedCapabilityFPS: Double? = nil,
        averageEncodeTimeMs: Double? = nil,
        warnings: [MirageHostCaptureBenchmarkWarning] = [],
        invalidMeasurementReason: String? = nil,
        unsupportedReason: String? = nil,
        failureDescription: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.actualPixelWidth = actualPixelWidth
        self.actualPixelHeight = actualPixelHeight
        self.reportedDisplayRefreshRate = reportedDisplayRefreshRate
        self.observedDisplayCadenceFPS = observedDisplayCadenceFPS
        self.sourceGenerationFPS = sourceGenerationFPS
        self.sourcePhase = sourcePhase
        self.displayPhase = displayPhase
        self.encodeFPS = encodeFPS
        self.sourceCapturePolicy = sourceCapturePolicy
        self.displayCapturePolicy = displayCapturePolicy
        self.bottleneck = bottleneck
        self.displayCaptureCapabilityFPS = displayCaptureCapabilityFPS
        self.validatedCapabilityFPS = validatedCapabilityFPS
        self.averageEncodeTimeMs = averageEncodeTimeMs
        self.warnings = warnings
        self.invalidMeasurementReason = invalidMeasurementReason
        self.unsupportedReason = unsupportedReason
        self.failureDescription = failureDescription
    }
}

/// Summarizes the highest completed benchmark stages that meet validity and sustain thresholds.
package func captureBenchmarkSummary(
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
