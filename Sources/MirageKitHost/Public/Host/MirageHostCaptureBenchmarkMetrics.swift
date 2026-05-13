//
//  MirageHostCaptureBenchmarkMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Capture benchmark measurement helpers.
//

import CoreMedia
import Foundation
import MirageKit

#if os(macOS)
/// Produces benchmark warnings from display cadence and measured bottleneck state.
func captureBenchmarkWarnings(
    stage: MirageHostCaptureBenchmarkStage,
    reportedDisplayRefreshRate: Double?,
    observedDisplayCadenceFPS: Double?,
    bottleneck: MirageHostCaptureBenchmarkBottleneck?
) -> [MirageHostCaptureBenchmarkWarning] {
    var warnings: [MirageHostCaptureBenchmarkWarning] = []

    if let reportedDisplayRefreshRate,
       Int(reportedDisplayRefreshRate.rounded()) >= stage.refreshRate,
       let observedDisplayCadenceFPS,
       observedDisplayCadenceFPS < max(captureBenchmarkValidThresholdFPS, Double(stage.targetFrameRate) * 0.75) {
        warnings.append(.displayCadenceMismatch)
    }

    switch bottleneck {
    case .sourceGeneration:
        warnings.append(.sourceGenerationBelowTarget)
    case .windowIngress:
        warnings.append(.windowIngressBelowTarget)
    case .windowDelivery:
        warnings.append(.windowDeliveryBelowTarget)
    case .displayIngress:
        warnings.append(.displayIngressBelowTarget)
    case .displayDelivery:
        warnings.append(.displayDeliveryBelowTarget)
    case .encode:
        warnings.append(.encodeBelowTarget)
    case .balanced, .none:
        break
    }

    return warnings
}

/// Removes repeated benchmark warnings while preserving first-seen order.
func deduplicatedBenchmarkWarnings(
    _ warnings: [MirageHostCaptureBenchmarkWarning]
) -> [MirageHostCaptureBenchmarkWarning] {
    var seen = Set<MirageHostCaptureBenchmarkWarning>()
    var ordered: [MirageHostCaptureBenchmarkWarning] = []
    for warning in warnings where seen.insert(warning).inserted {
        ordered.append(warning)
    }
    return ordered
}

/// Calculates capture telemetry produced between two cumulative stream snapshots.
func captureBenchmarkTelemetryDelta(
    baseline: CaptureStreamOutput.TelemetrySnapshot?,
    final: CaptureStreamOutput.TelemetrySnapshot?
) -> MirageHostCaptureBenchmarkTelemetryDelta {
    let baselineCallbackTotal = baseline?.callbackDurationTotalMs ?? 0
    let finalCallbackTotal = final?.callbackDurationTotalMs ?? 0
    let baselineCallbackSamples = baseline?.callbackSampleCount ?? 0
    let finalCallbackSamples = final?.callbackSampleCount ?? 0
    let callbackSampleDelta = finalCallbackSamples >= baselineCallbackSamples
        ? finalCallbackSamples - baselineCallbackSamples
        : 0
    let callbackTotalDelta = max(0, finalCallbackTotal - baselineCallbackTotal)
    let rawCallbackCount = subtractCounter(
        final?.rawScreenCallbackCount ?? 0,
        baseline?.rawScreenCallbackCount ?? 0
    )
    let validSampleCount = subtractCounter(
        final?.validScreenSampleCount ?? 0,
        baseline?.validScreenSampleCount ?? 0
    )
    let renderableSampleCount = subtractCounter(
        final?.renderableScreenSampleCount ?? 0,
        baseline?.renderableScreenSampleCount ?? 0
    )
    let completeSampleCount = subtractCounter(
        final?.completeFrameCount ?? 0,
        baseline?.completeFrameCount ?? 0
    )
    let idleSampleCount = subtractCounter(
        final?.idleFrameCount ?? 0,
        baseline?.idleFrameCount ?? 0
    )
    let blankSampleCount = subtractCounter(
        final?.blankFrameCount ?? 0,
        baseline?.blankFrameCount ?? 0
    )
    let suspendedSampleCount = subtractCounter(
        final?.suspendedFrameCount ?? 0,
        baseline?.suspendedFrameCount ?? 0
    )
    let startedSampleCount = subtractCounter(
        final?.startedFrameCount ?? 0,
        baseline?.startedFrameCount ?? 0
    )
    let stoppedSampleCount = subtractCounter(
        final?.stoppedFrameCount ?? 0,
        baseline?.stoppedFrameCount ?? 0
    )
    let cadenceAdmittedCount = subtractCounter(
        final?.cadenceAdmittedFrameCount ?? 0,
        baseline?.cadenceAdmittedFrameCount ?? 0
    )
    let deliveryCount = subtractCounter(
        final?.deliveredFrameCount ?? 0,
        baseline?.deliveredFrameCount ?? 0
    )

    return MirageHostCaptureBenchmarkTelemetryDelta(
        rawCallbackCount: rawCallbackCount,
        validSampleCount: validSampleCount,
        renderableSampleCount: renderableSampleCount,
        completeSampleCount: completeSampleCount,
        idleSampleCount: idleSampleCount,
        blankSampleCount: blankSampleCount,
        suspendedSampleCount: suspendedSampleCount,
        startedSampleCount: startedSampleCount,
        stoppedSampleCount: stoppedSampleCount,
        cadenceAdmittedCount: cadenceAdmittedCount,
        deliveryCount: deliveryCount,
        averageCallbackTimeMs: callbackSampleDelta > 0
            ? callbackTotalDelta / Double(callbackSampleDelta)
            : nil,
        maximumCallbackTimeMs: final?.callbackDurationMaxMs,
        cadenceDropCount: subtractCounter(
            final?.cadenceDropCount ?? 0,
            baseline?.cadenceDropCount ?? 0
        ),
        admissionDropCount: subtractCounter(
            final?.admissionDropCount ?? 0,
            baseline?.admissionDropCount ?? 0
        )
    )
}

/// Builds a phase result from a telemetry delta and measured duration.
func captureBenchmarkPhaseResult(
    kind: MirageHostCaptureBenchmarkPhaseKind,
    telemetryDelta: MirageHostCaptureBenchmarkTelemetryDelta,
    startupReadiness: DisplayCaptureStartupReadiness,
    measurementDuration: Double
) -> MirageHostCaptureBenchmarkPhaseResult {
    let duration = max(0.001, measurementDuration)
    return MirageHostCaptureBenchmarkPhaseResult(
        kind: kind,
        rawIngressFPS: Double(telemetryDelta.rawCallbackCount) / duration,
        validSampleFPS: Double(telemetryDelta.validSampleCount) / duration,
        renderableIngressFPS: Double(telemetryDelta.renderableSampleCount) / duration,
        cadenceAdmittedFPS: Double(telemetryDelta.cadenceAdmittedCount) / duration,
        deliveryFPS: Double(telemetryDelta.deliveryCount) / duration,
        startupReadiness: MirageHostCaptureBenchmarkStartupReadiness(startupReadiness),
        averageCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
        maximumCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
        rawCallbackCount: telemetryDelta.rawCallbackCount,
        validSampleCount: telemetryDelta.validSampleCount,
        renderableSampleCount: telemetryDelta.renderableSampleCount,
        completeSampleCount: telemetryDelta.completeSampleCount,
        idleSampleCount: telemetryDelta.idleSampleCount,
        blankSampleCount: telemetryDelta.blankSampleCount,
        suspendedSampleCount: telemetryDelta.suspendedSampleCount,
        startedSampleCount: telemetryDelta.startedSampleCount,
        stoppedSampleCount: telemetryDelta.stoppedSampleCount,
        cadenceAdmittedCount: telemetryDelta.cadenceAdmittedCount,
        deliveryCount: telemetryDelta.deliveryCount,
        cadenceDropCount: telemetryDelta.cadenceDropCount,
        admissionDropCount: telemetryDelta.admissionDropCount
    )
}

/// Subtracts monotonic counters while treating reset or rollover as zero delta.
func subtractCounter(_ end: UInt64, _ start: UInt64) -> UInt64 {
    end >= start ? end - start : 0
}

/// Creates an encoder callback that counts frames only inside the measurement window.
func captureBenchmarkEncodedFrameHandler(
    measurementWindow: Locked<MirageHostCaptureBenchmarkMeasurementWindow?>,
    encodedFrameCount: Locked<UInt64>
) -> @Sendable (Data, Bool, CMTime) -> Void {
    { _, _, _ in
        let now = CFAbsoluteTimeGetCurrent()
        let shouldCount = measurementWindow.read { window in
            window?.contains(now) ?? false
        }
        guard shouldCount else { return }
        encodedFrameCount.withLock { $0 &+= 1 }
    }
}
#endif
