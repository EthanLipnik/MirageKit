//
//  MirageHostCaptureBenchmarkConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics

#if os(macOS)
/// Encoder low-power mode to exercise during host capture benchmarking.
@_spi(HostApp)
public enum MirageHostCaptureBenchmarkModeSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Runs the benchmark with VideoToolbox low-power mode enabled.
    case lowPowerOn

    /// Runs the benchmark with VideoToolbox low-power mode disabled.
    case lowPowerOff

    /// Stable identity for SwiftUI pickers and persisted selections.
    public var id: String { rawValue }

    /// Human-readable label for benchmark controls and reports.
    public var displayName: String {
        switch self {
        case .lowPowerOn:
            "Encoder Low Power On"
        case .lowPowerOff:
            "Encoder Low Power Off"
        }
    }

    /// Whether this mode enables low-power encoder mode.
    var lowPowerEnabled: Bool {
        self == .lowPowerOn
    }
}

/// One resolution and cadence target in the host capture benchmark matrix.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkStage: Codable, Hashable, Sendable, Identifiable {
    /// Stable stage identifier used in reports and cache keys.
    public let id: String

    /// Display title for the stage.
    public let title: String

    /// Encoded pixel width tested by this stage.
    public let pixelWidth: Int

    /// Encoded pixel height tested by this stage.
    public let pixelHeight: Int

    /// Display refresh rate to provision for the benchmark stage.
    public let refreshRate: Int

    /// Video frame rate requested from the capture and encode path.
    public let targetFrameRate: Int

    /// Creates one capture benchmark stage.
    public init(
        id: String,
        title: String,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Int = 120,
        targetFrameRate: Int = 120
    ) {
        self.id = id
        self.title = title
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.targetFrameRate = targetFrameRate
    }

    /// Pixel dimensions as a CoreGraphics size.
    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// Compact dimensions text used in benchmark result summaries.
    public var pixelDescription: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    /// 1920x1080 benchmark stage.
    public static let benchmark1080p = MirageHostCaptureBenchmarkStage(
        id: "1080p",
        title: "1080p",
        pixelWidth: 1920,
        pixelHeight: 1080
    )

    /// 2560x1440 benchmark stage.
    public static let benchmark2K = MirageHostCaptureBenchmarkStage(
        id: "2k",
        title: "2K",
        pixelWidth: 2560,
        pixelHeight: 1440
    )

    /// 3840x2160 benchmark stage.
    public static let benchmark4K = MirageHostCaptureBenchmarkStage(
        id: "4k",
        title: "4K",
        pixelWidth: 3840,
        pixelHeight: 2160
    )

    /// 5120x2880 benchmark stage.
    public static let benchmark5K = MirageHostCaptureBenchmarkStage(
        id: "5k",
        title: "5K",
        pixelWidth: 5120,
        pixelHeight: 2880
    )

    /// 6016x3384 benchmark stage.
    public static let benchmark6K = MirageHostCaptureBenchmarkStage(
        id: "6k",
        title: "6K",
        pixelWidth: 6016,
        pixelHeight: 3384
    )

    /// Default benchmark stage order.
    public static let allStages: [MirageHostCaptureBenchmarkStage] = [
        .benchmark1080p,
        .benchmark2K,
        .benchmark4K,
        .benchmark5K,
        .benchmark6K,
    ]
}

/// Host capture benchmark plan, including low-power modes, stages, and timing.
@_spi(HostApp)
public struct MirageHostCaptureBenchmarkConfiguration: Codable, Hashable, Sendable {
    /// Low-power mode variants to measure.
    public let modeSelections: [MirageHostCaptureBenchmarkModeSelection]

    /// Resolution stages to measure.
    public let stages: [MirageHostCaptureBenchmarkStage]

    /// Seconds spent warming the pipeline before collecting measurements.
    public let warmupDurationSeconds: Double

    /// Seconds spent recording each benchmark measurement.
    public let measurementDurationSeconds: Double

    /// Creates a host capture benchmark configuration.
    public init(
        modeSelections: [MirageHostCaptureBenchmarkModeSelection],
        stages: [MirageHostCaptureBenchmarkStage] = MirageHostCaptureBenchmarkStage.allStages,
        warmupDurationSeconds: Double = 1,
        measurementDurationSeconds: Double = 5
    ) {
        self.modeSelections = Self.normalizedModeSelections(modeSelections)
        self.stages = stages
        self.warmupDurationSeconds = warmupDurationSeconds
        self.measurementDurationSeconds = measurementDurationSeconds
    }

    /// Default host benchmark configuration used by the app.
    public static let standard = MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOff])

    /// Stable cache key for persisted benchmark reports.
    public var cacheKey: String {
        let modesText = modeSelections.map(\.rawValue).joined(separator: "-")
        let stagesText = stages
            .map { "\($0.id)-\($0.pixelWidth)x\($0.pixelHeight)" }
            .joined(separator: "_")
        let warmupMs = Int((warmupDurationSeconds * 1000).rounded())
        let measurementMs = Int((measurementDurationSeconds * 1000).rounded())
        return "v\(MirageHostCaptureBenchmarkReport.currentVersion)-modes-\(modesText)-stages-\(stagesText)-warmup-\(warmupMs)-measure-\(measurementMs)"
    }

    /// Deduplicates and sorts selected benchmark modes for stable execution and cache keys.
    public static func normalizedModeSelections(
        _ selections: [MirageHostCaptureBenchmarkModeSelection]
    ) -> [MirageHostCaptureBenchmarkModeSelection] {
        Array(Set(selections)).sorted { $0.rawValue < $1.rawValue }
    }
}
#endif
