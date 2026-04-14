//
//  CaptureBenchmarkTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import Foundation
@_spi(HostApp) @testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Capture Benchmark")
struct CaptureBenchmarkTests {
    @Test("Benchmark stages use the expected resolutions and 120 fps cadence")
    func benchmarkStageCatalogUsesExpectedSizes() {
        let stages = MirageHostCaptureBenchmarkStage.allStages

        #expect(stages.map(\.title) == ["1080p", "2K", "4K", "5K", "6K"])
        #expect(stages.map(\.pixelDescription) == [
            "1920x1080",
            "2560x1440",
            "3840x2160",
            "5120x2880",
            "6016x3384",
        ])
        #expect(stages.allSatisfy { $0.refreshRate == 120 })
        #expect(stages.allSatisfy { $0.targetFrameRate == 120 })
    }

    @Test("Configuration cache keys normalize mode selection ordering and duplicates")
    func configurationCacheKeyNormalizesModeSelections() {
        let normalizedConfiguration = MirageHostCaptureBenchmarkConfiguration(
            modeSelections: [.always, .auto, .always]
        )
        let reorderedConfiguration = MirageHostCaptureBenchmarkConfiguration(
            modeSelections: [.auto, .always]
        )

        #expect(normalizedConfiguration.modeSelections == [.always, .auto])
        #expect(normalizedConfiguration.cacheKey == reorderedConfiguration.cacheKey)
        #expect(normalizedConfiguration == reorderedConfiguration)
    }

    @Test("Report reuse requires matching machine, software environment, configuration, and a completed run")
    func reportReuseRequiresMatchingEnvironment() {
        let configuration = MirageHostCaptureBenchmarkConfiguration(modeSelections: [.auto])
        let machineID = UUID()
        let report = MirageHostCaptureBenchmarkReport(
            machineID: machineID,
            hostName: "Bench Mac",
            hardwareModelIdentifier: "Mac16,7",
            hardwareMachineFamily: "MacBook Pro",
            appVersion: "2.4",
            buildVersion: "812",
            operatingSystemVersion: "macOS 15.4 (24E214)",
            configuration: configuration,
            measuredAt: .now,
            modeResults: [],
            didCancel: false
        )
        let cancelledReport = MirageHostCaptureBenchmarkReport(
            machineID: machineID,
            hostName: "Bench Mac",
            hardwareModelIdentifier: "Mac16,7",
            hardwareMachineFamily: "MacBook Pro",
            appVersion: "2.4",
            buildVersion: "812",
            operatingSystemVersion: "macOS 15.4 (24E214)",
            configuration: configuration,
            measuredAt: .now,
            modeResults: [],
            didCancel: true
        )

        #expect(
            report.isReusable(
                machineID: machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: configuration
            )
        )
        #expect(
            !report.isReusable(
                machineID: UUID(),
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: configuration
            )
        )
        #expect(
            !report.isReusable(
                machineID: machineID,
                appVersion: "2.5",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: configuration
            )
        )
        #expect(
            !report.isReusable(
                machineID: machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.5 (24F101)",
                configuration: configuration
            )
        )
        #expect(
            !report.isReusable(
                machineID: machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: MirageHostCaptureBenchmarkConfiguration(modeSelections: [.always])
            )
        )
        #expect(
            !cancelledReport.isReusable(
                machineID: machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: configuration
            )
        )
    }

    @Test("Summary uses a 95 percent sustain threshold")
    func summaryUsesSustainThreshold() {
        let summary = captureBenchmarkSummary(
            stageResults: [
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark1080p,
                    status: .completed,
                    captureFPS: 119.8,
                    encodeFPS: 118.6,
                    effectiveFPS: 118.6
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark2K,
                    status: .completed,
                    captureFPS: 117.2,
                    encodeFPS: 114.0,
                    effectiveFPS: 114.0
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark4K,
                    status: .completed,
                    captureFPS: 116.5,
                    encodeFPS: 113.9,
                    effectiveFPS: 113.9
                ),
            ]
        )

        #expect(summary.targetFrameRate == 120)
        #expect(summary.sustainThresholdFPS == 114)
        #expect(summary.highestSustainedStageID == MirageHostCaptureBenchmarkStage.benchmark2K.id)
        #expect(summary.highestSustainedStageTitle == "2K")
        #expect(summary.highestSustainedResolution == "2560x1440")
    }

    @Test("Stage continuation stops only after cancellation")
    func continuationStopsOnlyForCancelledStages() {
        #expect(captureBenchmarkShouldContinue(after: .completed))
        #expect(captureBenchmarkShouldContinue(after: .unsupported))
        #expect(captureBenchmarkShouldContinue(after: .failed))
        #expect(!captureBenchmarkShouldContinue(after: .cancelled))
    }

    @Test("Display validation rejects degraded resolution and refresh rate")
    func displayValidationRejectsDegradedTargets() {
        #expect(
            captureBenchmarkDisplayValidationResult(
                requestedStage: .benchmark5K,
                actualResolution: .init(width: 5120, height: 2880),
                actualRefreshRate: 120
            ) == .exact
        )

        switch captureBenchmarkDisplayValidationResult(
            requestedStage: .benchmark5K,
            actualResolution: .init(width: 3840, height: 2160),
            actualRefreshRate: 120
        ) {
        case .exact:
            Issue.record("Expected the degraded resolution to be rejected.")
        case let .unsupported(reason):
            #expect(reason.contains("Requested 5120x2880"))
            #expect(reason.contains("acquired 3840x2160"))
        }

        switch captureBenchmarkDisplayValidationResult(
            requestedStage: .benchmark6K,
            actualResolution: .init(width: 6016, height: 3384),
            actualRefreshRate: 60
        ) {
        case .exact:
            Issue.record("Expected the degraded refresh rate to be rejected.")
        case let .unsupported(reason):
            #expect(reason.contains("Requested 120Hz"))
            #expect(reason.contains("acquired 60Hz"))
        }
    }
}
#endif
