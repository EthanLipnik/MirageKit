//
//  MirageHostCaptureBenchmarkSupport.swift
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

/// Errors surfaced while preparing or measuring a host capture benchmark.
enum MirageHostCaptureBenchmarkError: LocalizedError {
    case noModesSelected
    case noStagesConfigured
    case hostBusy
    case displayBoundsUnavailable(CGDirectDisplayID)
    case measurementInvalid(String)

    var errorDescription: String? {
        switch self {
        case .noModesSelected:
            "Select at least one benchmark mode."
        case .noStagesConfigured:
            "Configure at least one benchmark stage."
        case .hostBusy:
            "Capture benchmarking is unavailable while clients or streams are active."
        case let .displayBoundsUnavailable(displayID):
            "Unable to resolve bounds for benchmark display \(displayID)."
        case let .measurementInvalid(reason):
            reason
        }
    }
}

/// Wall-clock interval used to count encoded frames for a benchmark phase.
struct MirageHostCaptureBenchmarkMeasurementWindow {
    let startTime: CFAbsoluteTime
    let endTime: CFAbsoluteTime

    /// Returns whether a frame timestamp falls inside the measurement interval.
    func contains(_ timestamp: CFAbsoluteTime) -> Bool {
        timestamp >= startTime && timestamp <= endTime
    }
}

/// Difference between two cumulative capture telemetry snapshots.
struct MirageHostCaptureBenchmarkTelemetryDelta {
    let rawCallbackCount: UInt64
    let validSampleCount: UInt64
    let renderableSampleCount: UInt64
    let completeSampleCount: UInt64
    let idleSampleCount: UInt64
    let blankSampleCount: UInt64
    let suspendedSampleCount: UInt64
    let startedSampleCount: UInt64
    let stoppedSampleCount: UInt64
    let cadenceAdmittedCount: UInt64
    let deliveryCount: UInt64
    let averageCallbackTimeMs: Double?
    let maximumCallbackTimeMs: Double?
    let cadenceDropCount: UInt64
    let admissionDropCount: UInt64
}

/// ScreenCaptureKit objects resolved for the prepared benchmark source window.
struct MirageHostCaptureBenchmarkResolvedSource {
    let windowWrapper: SCWindowWrapper
    let applicationWrapper: SCApplicationWrapper
    let displayWrapper: SCDisplayWrapper
    let sourceClock: MirageHostCaptureBenchmarkSourceClock?
}

/// Measurements produced by the source-window benchmark phase.
struct MirageHostCaptureBenchmarkPhaseMeasurement {
    let phase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult
    let observedDisplayCadenceFPS: Double?
    let sourceGenerationFPS: Double?
    let capturePolicy: MirageDiagnostics.MirageHostCaptureBenchmarkCapturePolicy?
}

/// Measurements produced by the display-capture and encode benchmark phase.
struct MirageHostCaptureBenchmarkDisplayMeasurement {
    let phase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult
    let encodeFPS: Double?
    let averageEncodeTimeMs: Double?
    let capturePolicy: MirageDiagnostics.MirageHostCaptureBenchmarkCapturePolicy?
}
#endif
