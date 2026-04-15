//
//  CaptureBenchmarkTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
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
            modeSelections: [.lowPowerOff, .lowPowerOn, .lowPowerOff]
        )
        let reorderedConfiguration = MirageHostCaptureBenchmarkConfiguration(
            modeSelections: [.lowPowerOn, .lowPowerOff]
        )

        #expect(normalizedConfiguration.modeSelections == [.lowPowerOff, .lowPowerOn])
        #expect(normalizedConfiguration.cacheKey == reorderedConfiguration.cacheKey)
        #expect(normalizedConfiguration == reorderedConfiguration)
    }

    @Test("Report reuse requires matching machine, software environment, configuration, and a completed run")
    func reportReuseRequiresMatchingEnvironment() {
        let configuration = MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOff])
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
                configuration: MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOn])
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
                    encodeFPS: 118.6,
                    effectiveFPS: 118.6,
                    validatedCapabilityFPS: 119.8
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark2K,
                    status: .completed,
                    encodeFPS: 114.0,
                    effectiveFPS: 114.0,
                    validatedCapabilityFPS: 117.2
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark4K,
                    status: .completed,
                    encodeFPS: 113.9,
                    effectiveFPS: 113.9,
                    validatedCapabilityFPS: 113.9
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
        #expect(captureBenchmarkShouldContinue(after: .invalid))
        #expect(captureBenchmarkShouldContinue(after: .unsupported))
        #expect(captureBenchmarkShouldContinue(after: .failed))
        #expect(!captureBenchmarkShouldContinue(after: .cancelled))
    }

    @Test("Display validation accepts close-enough resolutions")
    func displayValidationAcceptsCloseResolutions() {
        #expect(
            captureBenchmarkDisplayValidationResult(
                requestedStage: .benchmark5K,
                actualResolution: .init(width: 5120, height: 2880),
                actualRefreshRate: 120
            ) == .exact
        )

        #expect(
            captureBenchmarkDisplayValidationResult(
                requestedStage: .benchmark4K,
                actualResolution: .init(width: 3840, height: 2156),
                actualRefreshRate: 120
            ) == .accepted(actualWidth: 3840, actualHeight: 2156)
        )

        #expect(
            captureBenchmarkDisplayValidationResult(
                requestedStage: .benchmark5K,
                actualResolution: .init(width: 3840, height: 2160),
                actualRefreshRate: 120
            ) == .accepted(actualWidth: 3840, actualHeight: 2160)
        )
    }

    @Test("Display validation rejects degraded refresh rate")
    func displayValidationRejectsDegradedRefreshRate() {
        switch captureBenchmarkDisplayValidationResult(
            requestedStage: .benchmark6K,
            actualResolution: .init(width: 6016, height: 3384),
            actualRefreshRate: 60
        ) {
        case .exact, .accepted:
            Issue.record("Expected the degraded refresh rate to be rejected.")
        case let .invalid(reason):
            #expect(reason.contains("Requested 120Hz"))
            #expect(reason.contains("acquired 60Hz"))
        }
    }

    @Test("Mode selections resolve low power enabled correctly")
    func modeSelectionsResolveLowPower() {
        #expect(MirageHostCaptureBenchmarkModeSelection.lowPowerOn.lowPowerEnabled)
        #expect(!MirageHostCaptureBenchmarkModeSelection.lowPowerOff.lowPowerEnabled)
    }

    @Test("Stage result tracks actual resolution when different from requested")
    func stageResultTracksActualResolution() {
        let exactResult = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark4K,
            status: .completed,
            actualPixelWidth: 3840,
            actualPixelHeight: 2160
        )
        #expect(exactResult.actualPixelDescription == nil)

        let tolerantResult = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark4K,
            status: .completed,
            actualPixelWidth: 3840,
            actualPixelHeight: 2156
        )
        #expect(tolerantResult.actualPixelDescription == "3840x2156")
    }

    @Test("Invalid measurement reason rejects blank startup")
    func invalidMeasurementReasonRejectsBlankStartup() {
        let reason = captureBenchmarkInvalidMeasurementReason(
            startupReadiness: .blankOrSuspendedOnly,
            validateSourceCadence: false,
            targetFrameRate: 120
        )

        #expect(reason?.contains("blank or suspended") == true)
    }

    @Test("Invalid measurement reason rejects low source cadence")
    func invalidMeasurementReasonRejectsLowSourceCadence() {
        let reason = captureBenchmarkInvalidMeasurementReason(
            startupReadiness: .usableFrameSeen,
            sourceFPS: 92,
            targetFrameRate: 120
        )

        #expect(reason?.contains("92.0 fps") == true)
        #expect(reason?.contains("114.0 fps") == true)
    }

    @Test("Capability fps uses the lowest validated bottleneck and caps at 120")
    func capabilityFPSUsesValidatedBottleneck() {
        let capability = captureBenchmarkValidatedCapabilityFPS(
            sourceFPS: 121,
            capturePresentationFPS: 118.4,
            encodeFPS: 97.2,
            targetFrameRate: 120
        )
        let capped = captureBenchmarkValidatedCapabilityFPS(
            sourceFPS: 144,
            capturePresentationFPS: 136,
            encodeFPS: 132,
            targetFrameRate: 120
        )

        #expect(capability == 97.2)
        #expect(capped == 120)
    }

    @Test("Stage result badges derive from validated capability")
    func stageResultBadgesDeriveFromValidatedCapability() {
        let meets60Only = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark2K,
            status: .completed,
            validatedCapabilityFPS: 76.4
        )
        let meets120 = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark2K,
            status: .completed,
            validatedCapabilityFPS: 114.2
        )

        #expect(meets60Only.meets60FPS)
        #expect(!meets60Only.meets120FPS)
        #expect(meets120.meets60FPS)
        #expect(meets120.meets120FPS)
    }

    @Test("Observed shared display mode accepts requested mode after in-place update")
    func observedSharedDisplayModeAcceptsRequestedMode() async {
        let validated = await SharedVirtualDisplayManager.shared.validatedObservedDisplayMode(
            requestedResolution: CGSize(width: 3840, height: 2160),
            requestedRefreshRate: 120,
            observedMode: SharedVirtualDisplayManager.ObservedDisplayMode(
                logicalResolution: CGSize(width: 1920, height: 1080),
                pixelResolution: CGSize(width: 3840, height: 2160),
                refreshRate: 120
            )
        )

        #expect(validated?.pixelResolution == CGSize(width: 3840, height: 2160))
        #expect(validated?.refreshRate == 120)
    }

    @Test("Observed shared display mode rejects refresh mismatches after in-place update")
    func observedSharedDisplayModeRejectsRefreshMismatch() async {
        let validated = await SharedVirtualDisplayManager.shared.validatedObservedDisplayMode(
            requestedResolution: CGSize(width: 3840, height: 2160),
            requestedRefreshRate: 120,
            observedMode: SharedVirtualDisplayManager.ObservedDisplayMode(
                logicalResolution: CGSize(width: 1920, height: 1080),
                pixelResolution: CGSize(width: 3840, height: 2160),
                refreshRate: 60
            )
        )

        #expect(validated == nil)
    }

    @Test("Observed shared display mode rejects resolution mismatches after in-place update")
    func observedSharedDisplayModeRejectsResolutionMismatch() async {
        let validated = await SharedVirtualDisplayManager.shared.validatedObservedDisplayMode(
            requestedResolution: CGSize(width: 3840, height: 2160),
            requestedRefreshRate: 120,
            observedMode: SharedVirtualDisplayManager.ObservedDisplayMode(
                logicalResolution: CGSize(width: 1920, height: 1080),
                pixelResolution: CGSize(width: 3200, height: 1800),
                refreshRate: 120
            )
        )

        #expect(validated == nil)
    }
}
#endif
