//
//  MirageHostCaptureBenchmarkTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation

#if os(macOS)
/// Final status for one capture benchmark stage.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkStageStatus: String, Codable, Sendable {
    /// Stage completed and produced a valid measurement.
    case completed
    /// Stage completed but failed validation thresholds.
    case invalid
    /// Stage cannot run on the current host/runtime.
    case unsupported
    /// Stage failed before producing usable measurements.
    case failed
    /// Stage was cancelled before completion.
    case cancelled
}

/// Measurement phase within a capture benchmark stage.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkPhaseKind: String, Codable, Hashable, Sendable {
    /// Capture source phase before display delivery.
    case source
    /// Display delivery phase after capture handoff.
    case display
}

/// Non-fatal condition detected while measuring a capture benchmark stage.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkWarning: String, Codable, CaseIterable, Sendable {
    /// Requested resolution was quantized before capture.
    case quantizedResolution
    /// Display refresh cadence did not match the benchmark target.
    case displayCadenceMismatch
    /// Source sample generation fell below the target frame rate.
    case sourceGenerationBelowTarget
    /// Window capture ingress fell below the target frame rate.
    case windowIngressBelowTarget
    /// Window delivery fell below the target frame rate.
    case windowDeliveryBelowTarget
    /// Display capture ingress fell below the target frame rate.
    case displayIngressBelowTarget
    /// Display delivery fell below the target frame rate.
    case displayDeliveryBelowTarget
    /// Encoder output fell below the target frame rate.
    case encodeBelowTarget
}

/// Startup sample quality observed before a capture benchmark starts measurement.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkStartupReadiness: String, Codable, Hashable, Sendable {
    /// A complete non-idle frame was observed.
    case usableFrameSeen
    /// Only an idle frame was observed.
    case idleFrameSeen
    /// Only blank or suspended samples were observed.
    case blankOrSuspendedOnly
    /// No ScreenCaptureKit samples were observed.
    case noScreenSamples
}

/// Slowest subsystem identified in a capture benchmark stage.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkBottleneck: String, Codable, CaseIterable, Hashable, Sendable {
    /// Source generation was the limiting stage.
    case sourceGeneration
    /// Window capture ingress was the limiting stage.
    case windowIngress
    /// Window delivery was the limiting stage.
    case windowDelivery
    /// Display capture ingress was the limiting stage.
    case displayIngress
    /// Display delivery was the limiting stage.
    case displayDelivery
    /// Encoding was the limiting stage.
    case encode
    /// No single stage dominated the result.
    case balanced
}

/// Capture timing and queue policy recorded for one benchmark phase.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkCapturePolicy: Codable, Hashable, Sendable {
    /// Capture rate requested from ScreenCaptureKit for this phase.
    public let effectiveCaptureRate: Int

    /// Minimum frame interval rate applied to capture output.
    public let minimumFrameIntervalRate: Int

    /// Whether the minimum frame interval follows the native display refresh rate.
    public let usesNativeRefreshMinimumFrameInterval: Bool

    /// ScreenCaptureKit queue depth used during the benchmark phase.
    public let sckQueueDepth: Int

    /// Whether capture timing is driven by display refresh cadence.
    public let usesDisplayRefreshCadence: Bool

    /// Creates the capture policy recorded with a benchmark phase.
    public init(
        effectiveCaptureRate: Int,
        minimumFrameIntervalRate: Int,
        usesNativeRefreshMinimumFrameInterval: Bool,
        sckQueueDepth: Int,
        usesDisplayRefreshCadence: Bool
    ) {
        self.effectiveCaptureRate = effectiveCaptureRate
        self.minimumFrameIntervalRate = minimumFrameIntervalRate
        self.usesNativeRefreshMinimumFrameInterval = usesNativeRefreshMinimumFrameInterval
        self.sckQueueDepth = sckQueueDepth
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
    }
}
#endif
