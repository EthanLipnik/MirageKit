//
//  MirageHostCaptureBenchmarkDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageDiagnostics
import Testing

#if os(macOS)
@Suite("Host Capture Benchmark Diagnostics")
struct MirageHostCaptureBenchmarkDiagnosticsTests {
    @Test("Configuration normalizes modes and builds stable cache keys")
    func configurationNormalizesModesAndBuildsStableCacheKeys() {
        let configuration = MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(
            modeSelections: [.lowPowerOn, .lowPowerOff, .lowPowerOn],
            stages: [.benchmark1080p],
            warmupDurationSeconds: 1.25,
            measurementDurationSeconds: 2.5
        )

        #expect(configuration.modeSelections == [.lowPowerOff, .lowPowerOn])
        #expect(
            configuration.cacheKey ==
                "v2-modes-lowPowerOff-lowPowerOn-stages-1080p-1920x1080-warmup-1250-measure-2500"
        )
    }

    @Test("Stage results derive mode descriptions and thresholds")
    func stageResultsDeriveModeDescriptionsAndThresholds() {
        let stage = MirageDiagnostics.MirageHostCaptureBenchmarkStage(
            id: "custom",
            title: "Custom",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshRate: 120,
            targetFrameRate: 120
        )
        let result = MirageDiagnostics.MirageHostCaptureBenchmarkStageResult(
            stage: stage,
            status: .completed,
            actualPixelWidth: 2560,
            actualPixelHeight: 1440,
            reportedDisplayRefreshRate: 60,
            sourcePhase: MirageDiagnostics.MirageHostCaptureBenchmarkPhaseResult(
                kind: .source,
                rawIngressFPS: 120,
                renderableIngressFPS: 118,
                deliveryFPS: 116,
                startupReadiness: .usableFrameSeen
            ),
            validatedCapabilityFPS: 114,
            warnings: [.displayCadenceMismatch]
        )

        #expect(result.actualDisplayModeDescription == "2560x1440 @ 60Hz")
        #expect(result.meets60FPS)
        #expect(result.meets120FPS)
    }

    @Test("Reports derive capture capability and round trip through JSON")
    func reportsDeriveCaptureCapabilityAndRoundTripThroughJSON() throws {
        let measuredAt = Date(timeIntervalSince1970: 1_234)
        let machineID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF"))
        let modeResult = MirageDiagnostics.MirageHostCaptureBenchmarkModeResult(
            modeSelection: .lowPowerOff,
            lowPowerModeEnabled: false,
            stageResults: [
                MirageDiagnostics.MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark1080p,
                    status: .completed,
                    validatedCapabilityFPS: 90
                ),
                MirageDiagnostics.MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark4K,
                    status: .completed,
                    validatedCapabilityFPS: 118
                ),
            ]
        )
        let report = MirageDiagnostics.MirageHostCaptureBenchmarkReport(
            machineID: machineID,
            hostName: "Bench Mac",
            hardwareModelIdentifier: "Mac16,7",
            hardwareMachineFamily: "MacBook Pro",
            appVersion: "2.4",
            buildVersion: "812",
            operatingSystemVersion: "macOS 15.4 (24E214)",
            configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(
                modeSelections: [.lowPowerOff],
                stages: [.benchmark1080p, .benchmark4K]
            ),
            measuredAt: measuredAt,
            modeResults: [modeResult],
            didCancel: false
        )

        #expect(modeResult.summary.highestValidStageID == "4k")
        #expect(modeResult.summary.highest120FPSStageID == "4k")
        #expect(report.captureCapability?.highestValidPixelWidth == 3840)
        #expect(report.captureCapability?.highestSustainedFrameRate == 118)

        let decoded = try JSONDecoder().decode(
            MirageDiagnostics.MirageHostCaptureBenchmarkReport.self,
            from: try JSONEncoder().encode(report)
        )
        #expect(decoded == report)
    }
}
#endif
