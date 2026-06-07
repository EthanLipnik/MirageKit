//
//  MirageHostLabs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
@_spi(Labs) import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)

/// Host Lab definitions backed by MirageKitHost measurements.
@_spi(Labs)
public enum MirageHostCaptureBenchmarkLab {
    public static let id = "host.capture-benchmark"

    public static func descriptor(
        defaultConfiguration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration = .standard
    ) -> MirageDiagnostics.MirageLabDescriptor {
        MirageDiagnostics.MirageLabDescriptor(
            id: id,
            title: "Host Capture Benchmark",
            summary: "Measures host capture, display delivery, and encode throughput.",
            category: .capture,
            defaultConfiguration: configuration(for: defaultConfiguration)
        )
    }

    public static func configuration(
        for configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration
    ) -> MirageDiagnostics.MirageLabConfiguration {
        MirageDiagnostics.MirageLabConfiguration(
            parameters: [
                "measurementDurationSeconds": .double(configuration.measurementDurationSeconds),
                "modeSelections": .stringArray(configuration.modeSelections.map(\.rawValue)),
                "stageIDs": .stringArray(configuration.stages.map(\.id)),
                "warmupDurationSeconds": .double(configuration.warmupDurationSeconds),
            ]
        )
    }

    public static func captureConfiguration(
        from configuration: MirageDiagnostics.MirageLabConfiguration
    ) throws -> MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration {
        let modeSelections = try modeSelections(from: configuration)
        let stages = try stages(from: configuration)
        let warmupDurationSeconds = doubleValue(
            "warmupDurationSeconds",
            in: configuration,
            defaultValue: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration.standard.warmupDurationSeconds
        )
        let measurementDurationSeconds = doubleValue(
            "measurementDurationSeconds",
            in: configuration,
            defaultValue: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration.standard.measurementDurationSeconds
        )

        return MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(
            modeSelections: modeSelections,
            stages: stages,
            warmupDurationSeconds: warmupDurationSeconds,
            measurementDurationSeconds: measurementDurationSeconds
        )
    }

    public static func report(
        from captureReport: MirageDiagnostics.MirageHostCaptureBenchmarkReport
    ) -> MirageDiagnostics.MirageLabReport {
        MirageDiagnostics.MirageLabReport(
            labID: id,
            labTitle: descriptor(defaultConfiguration: captureReport.configuration).title,
            category: .capture,
            configuration: configuration(for: captureReport.configuration),
            measuredAt: captureReport.measuredAt,
            status: status(for: captureReport),
            metrics: metrics(for: captureReport),
            warnings: warnings(for: captureReport),
            invalidationReasons: invalidationReasons(for: captureReport)
        )
    }

    public static func progress(
        from progress: MirageDiagnostics.MirageHostCaptureBenchmarkProgress
    ) -> MirageDiagnostics.MirageLabProgress {
        MirageDiagnostics.MirageLabProgress(
            completedUnitCount: progress.completedStageCount,
            totalUnitCount: progress.totalStageCount,
            message: progress.message
        )
    }

    private static func modeSelections(
        from configuration: MirageDiagnostics.MirageLabConfiguration
    ) throws -> [MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection] {
        guard case let .stringArray(rawValues)? = configuration.parameters["modeSelections"] else {
            return MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration.standard.modeSelections
        }

        return try rawValues.map { rawValue in
            guard let selection = MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection(rawValue: rawValue) else {
                throw MirageHostCaptureBenchmarkLabError.unknownModeSelection(rawValue)
            }
            return selection
        }
    }

    private static func stages(
        from configuration: MirageDiagnostics.MirageLabConfiguration
    ) throws -> [MirageDiagnostics.MirageHostCaptureBenchmarkStage] {
        guard case let .stringArray(stageIDs)? = configuration.parameters["stageIDs"] else {
            return MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration.standard.stages
        }

        return try stageIDs.map { stageID in
            guard let stage = MirageDiagnostics.MirageHostCaptureBenchmarkStage.allStages.first(where: { $0.id == stageID }) else {
                throw MirageHostCaptureBenchmarkLabError.unknownStageID(stageID)
            }
            return stage
        }
    }

    private static func doubleValue(
        _ key: String,
        in configuration: MirageDiagnostics.MirageLabConfiguration,
        defaultValue: Double
    ) -> Double {
        guard case let .double(value)? = configuration.parameters[key] else {
            return defaultValue
        }
        return value
    }

    private static func status(
        for report: MirageDiagnostics.MirageHostCaptureBenchmarkReport
    ) -> MirageDiagnostics.MirageLabRunStatus {
        if report.didCancel {
            return .cancelled
        }

        let stageStatuses = report.modeResults.flatMap { modeResult in
            modeResult.stageResults.map(\.status)
        }
        if stageStatuses.contains(.failed) {
            return .failed
        }
        if stageStatuses.contains(.invalid) || stageStatuses.contains(.unsupported) {
            return .invalid
        }
        return .completed
    }

    private static func metrics(
        for report: MirageDiagnostics.MirageHostCaptureBenchmarkReport
    ) -> [MirageDiagnostics.MirageLabMetric] {
        report.modeResults.flatMap { modeResult in
            modeResult.stageResults.flatMap { stageResult in
                stageMetrics(modeResult: modeResult, stageResult: stageResult)
            }
        }
    }

    private static func stageMetrics(
        modeResult: MirageDiagnostics.MirageHostCaptureBenchmarkModeResult,
        stageResult: MirageDiagnostics.MirageHostCaptureBenchmarkStageResult
    ) -> [MirageDiagnostics.MirageLabMetric] {
        let prefix = "\(modeResult.modeSelection.rawValue).\(stageResult.stage.id)"
        let dimensions = [
            "mode": modeResult.modeSelection.rawValue,
            "stage": stageResult.stage.id,
        ]
        var metrics: [MirageDiagnostics.MirageLabMetric] = []

        if let validatedCapabilityFPS = stageResult.validatedCapabilityFPS {
            metrics.append(
                MirageDiagnostics.MirageLabMetric(
                    id: "validated-fps.\(prefix)",
                    title: "Validated FPS",
                    unit: "fps",
                    value: validatedCapabilityFPS,
                    dimensions: dimensions
                )
            )
        }
        if let encodeFPS = stageResult.encodeFPS {
            metrics.append(
                MirageDiagnostics.MirageLabMetric(
                    id: "encode-fps.\(prefix)",
                    title: "Encode FPS",
                    unit: "fps",
                    value: encodeFPS,
                    dimensions: dimensions
                )
            )
        }
        if let averageEncodeTimeMs = stageResult.averageEncodeTimeMs {
            metrics.append(
                MirageDiagnostics.MirageLabMetric(
                    id: "average-encode-ms.\(prefix)",
                    title: "Average Encode Time",
                    unit: "ms",
                    value: averageEncodeTimeMs,
                    dimensions: dimensions
                )
            )
        }

        return metrics
    }

    private static func warnings(
        for report: MirageDiagnostics.MirageHostCaptureBenchmarkReport
    ) -> [String] {
        report.modeResults.flatMap { modeResult in
            modeResult.stageResults.flatMap { stageResult in
                stageResult.warnings.map { warning in
                    "\(modeResult.modeSelection.rawValue).\(stageResult.stage.id): \(warning.rawValue)"
                }
            }
        }
    }

    private static func invalidationReasons(
        for report: MirageDiagnostics.MirageHostCaptureBenchmarkReport
    ) -> [String] {
        report.modeResults.flatMap { modeResult in
            modeResult.stageResults.compactMap { stageResult in
                let prefix = "\(modeResult.modeSelection.rawValue).\(stageResult.stage.id)"
                if let invalidMeasurementReason = stageResult.invalidMeasurementReason {
                    return "\(prefix): \(invalidMeasurementReason)"
                }
                if let unsupportedReason = stageResult.unsupportedReason {
                    return "\(prefix): \(unsupportedReason)"
                }
                if let failureDescription = stageResult.failureDescription {
                    return "\(prefix): \(failureDescription)"
                }
                return nil
            }
        }
    }
}

@_spi(Labs)
public enum MirageHostCaptureBenchmarkLabError: Error, Equatable, Sendable {
    case unknownModeSelection(String)
    case unknownStageID(String)
}

@_spi(Labs)
public typealias MirageHostCaptureBenchmarkLabProgressHandler = @Sendable (
    MirageDiagnostics.MirageHostCaptureBenchmarkProgress?
) async -> Void

@_spi(Labs)
public struct MirageHostCaptureBenchmarkLabRunner: MirageDiagnostics.MirageLabRunner {
    public typealias RunCaptureBenchmark = @Sendable (
        MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration,
        MirageHostCaptureBenchmarkLabProgressHandler?
    ) async throws -> MirageDiagnostics.MirageHostCaptureBenchmarkReport

    public let descriptor: MirageDiagnostics.MirageLabDescriptor
    private let runCaptureBenchmark: RunCaptureBenchmark

    public init(
        defaultConfiguration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration = .standard,
        runCaptureBenchmark: @escaping RunCaptureBenchmark
    ) {
        descriptor = MirageHostCaptureBenchmarkLab.descriptor(
            defaultConfiguration: defaultConfiguration
        )
        self.runCaptureBenchmark = runCaptureBenchmark
    }

    public func run(
        _ configuration: MirageDiagnostics.MirageLabConfiguration,
        progress: MirageDiagnostics.MirageLabProgressHandler?
    ) async throws -> MirageDiagnostics.MirageLabReport {
        let captureConfiguration = try MirageHostCaptureBenchmarkLab.captureConfiguration(
            from: configuration
        )
        let captureReport = try await runCaptureBenchmark(captureConfiguration) { captureProgress in
            guard let captureProgress else { return }
            await progress?(MirageHostCaptureBenchmarkLab.progress(from: captureProgress))
        }
        return MirageHostCaptureBenchmarkLab.report(from: captureReport)
    }
}

/// Descriptor registry for host Labs.
@_spi(Labs)
public struct MirageHostLabRegistry: Sendable {
    public let descriptors: [MirageDiagnostics.MirageLabDescriptor]

    public init(descriptors: [MirageDiagnostics.MirageLabDescriptor]) {
        self.descriptors = descriptors
    }

    public static func standard(
        captureConfiguration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration = .standard
    ) -> MirageHostLabRegistry {
        MirageHostLabRegistry(
            descriptors: [
                MirageHostCaptureBenchmarkLab.descriptor(
                    defaultConfiguration: captureConfiguration
                ),
            ]
        )
    }

    public func descriptor(id: String) -> MirageDiagnostics.MirageLabDescriptor? {
        descriptors.first { $0.id == id }
    }
}

#endif
