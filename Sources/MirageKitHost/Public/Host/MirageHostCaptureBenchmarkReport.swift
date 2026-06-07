//
//  MirageHostCaptureBenchmarkReport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Results for one low-power mode selection in a capture benchmark run.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkModeResult: Codable, Hashable, Sendable {
    /// Capture mode selection measured for these stage results.
    public let modeSelection: MirageHostCaptureBenchmarkModeSelection
    /// Whether the host low-power encoder mode was enabled during this benchmark pass.
    public let lowPowerModeEnabled: Bool
    /// Ordered results for each stage measured in this mode.
    public let stageResults: [MirageHostCaptureBenchmarkStageResult]
    /// Aggregate capability summary derived from ``stageResults``.
    public let summary: MirageHostCaptureBenchmarkSummary

    /// Creates a mode result and derives its summary from the stage results.
    public init(
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        lowPowerModeEnabled: Bool,
        stageResults: [MirageHostCaptureBenchmarkStageResult]
    ) {
        self.modeSelection = modeSelection
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.stageResults = stageResults
        summary = captureBenchmarkSummary(stageResults: stageResults)
    }
}

/// Persisted host capture benchmark report.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkReport: Codable, Hashable, Sendable {
    /// Current persisted report schema version.
    public static let currentVersion = 3

    /// Persisted report schema version.
    public let version: Int
    /// Stable identifier for the host that produced the report.
    public let machineID: UUID
    /// Human-readable host name captured with the report.
    public let hostName: String
    /// Hardware model identifier reported by the host, when available.
    public let hardwareModelIdentifier: String?
    /// Hardware machine family reported by the host, when available.
    public let hardwareMachineFamily: String?
    /// Host app marketing version used for the benchmark.
    public let appVersion: String
    /// Host app build version used for the benchmark.
    public let buildVersion: String
    /// Operating system version used for the benchmark.
    public let operatingSystemVersion: String
    /// Benchmark configuration used to produce the report.
    public let configuration: MirageHostCaptureBenchmarkConfiguration
    /// Date when the benchmark was measured.
    public let measuredAt: Date
    /// Results for each measured capture mode.
    public let modeResults: [MirageHostCaptureBenchmarkModeResult]
    /// Whether the user or caller cancelled the benchmark before completion.
    public let didCancel: Bool

    /// Creates a persisted benchmark report.
    public init(
        version: Int = Self.currentVersion,
        machineID: UUID,
        hostName: String,
        hardwareModelIdentifier: String?,
        hardwareMachineFamily: String?,
        appVersion: String,
        buildVersion: String,
        operatingSystemVersion: String,
        configuration: MirageHostCaptureBenchmarkConfiguration,
        measuredAt: Date,
        modeResults: [MirageHostCaptureBenchmarkModeResult],
        didCancel: Bool
    ) {
        self.version = version
        self.machineID = machineID
        self.hostName = hostName
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.hardwareMachineFamily = hardwareMachineFamily
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.configuration = configuration
        self.measuredAt = measuredAt
        self.modeResults = modeResults
        self.didCancel = didCancel
    }

    /// Returns whether this report can be reused for the same host, app, OS, and configuration.
    public func isReusable(
        machineID: UUID,
        appVersion: String,
        operatingSystemVersion: String,
        configuration: MirageHostCaptureBenchmarkConfiguration
    ) -> Bool {
        version == Self.currentVersion &&
            !didCancel &&
            self.machineID == machineID &&
            self.appVersion == appVersion &&
            self.operatingSystemVersion == operatingSystemVersion &&
            self.configuration == configuration
    }

    /// Host capture capability derived from the preferred completed mode result.
    public var captureCapability: MirageHostCaptureCapability? {
        guard let modeResult = modeResults.first(where: { !$0.lowPowerModeEnabled }) ?? modeResults.first else {
            return nil
        }
        let highestValidStage = modeResult.stageResults.last { $0.meets60FPS }
        let highestSustainedStage = modeResult.stageResults.last { $0.meets120FPS }
        return MirageHostCaptureCapability(
            targetFrameRate: modeResult.summary.targetFrameRate,
            validThresholdFPS: modeResult.summary.validThresholdFPS,
            sustainThresholdFPS: modeResult.summary.sustainThresholdFPS,
            highestValidPixelWidth: highestValidStage?.stage.pixelWidth,
            highestValidPixelHeight: highestValidStage?.stage.pixelHeight,
            highestValidFrameRate: highestValidStage?.validatedCapabilityFPS,
            highestSustainedPixelWidth: highestSustainedStage?.stage.pixelWidth,
            highestSustainedPixelHeight: highestSustainedStage?.stage.pixelHeight,
            highestSustainedFrameRate: highestSustainedStage?.validatedCapabilityFPS,
            measuredAt: measuredAt
        )
    }
}

/// Progress update emitted while running the host capture benchmark.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkProgress: Sendable, Equatable {
    /// Current benchmark progress phase.
    public enum Phase: String, Sendable {
        /// Preparing the source window and display mode.
        case preparing
        /// Warming up capture and encode pipelines before measurement.
        case warmingUp
        /// Collecting measurements for the current stage.
        case measuring
        /// Completed all configured benchmark stages.
        case completed
        /// Benchmark execution was cancelled.
        case cancelled
    }

    /// Current progress phase.
    public let phase: Phase
    /// Capture mode selection being measured.
    public let modeSelection: MirageHostCaptureBenchmarkModeSelection
    /// Stage associated with this progress update.
    public let stage: MirageHostCaptureBenchmarkStage
    /// Number of stages completed before this update.
    public let completedStageCount: Int
    /// Total number of configured benchmark stages.
    public let totalStageCount: Int
    /// Human-readable progress message for host UI.
    public let message: String

    /// Creates a benchmark progress update.
    public init(
        phase: Phase,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        stage: MirageHostCaptureBenchmarkStage,
        completedStageCount: Int,
        totalStageCount: Int,
        message: String
    ) {
        self.phase = phase
        self.modeSelection = modeSelection
        self.stage = stage
        self.completedStageCount = completedStageCount
        self.totalStageCount = totalStageCount
        self.message = message
    }
}

extension MirageHostCaptureBenchmarkStartupReadiness {
    init(_ readiness: DisplayCaptureStartupReadiness) {
        switch readiness {
        case .usableFrameSeen:
            self = .usableFrameSeen
        case .idleFrameSeen:
            self = .idleFrameSeen
        case .blankOrSuspendedOnly:
            self = .blankOrSuspendedOnly
        case .noScreenSamples:
            self = .noScreenSamples
        }
    }
}

#endif
