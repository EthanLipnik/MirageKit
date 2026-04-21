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
    private func phaseResult(
        kind: MirageHostCaptureBenchmarkPhaseKind,
        rawIngressFPS: Double? = nil,
        renderableIngressFPS: Double? = nil,
        cadenceAdmittedFPS: Double? = nil,
        deliveryFPS: Double? = nil,
        startupReadiness: MirageHostCaptureBenchmarkStartupReadiness? = .usableFrameSeen
    ) -> MirageHostCaptureBenchmarkPhaseResult {
        MirageHostCaptureBenchmarkPhaseResult(
            kind: kind,
            rawIngressFPS: rawIngressFPS,
            validSampleFPS: rawIngressFPS,
            renderableIngressFPS: renderableIngressFPS,
            cadenceAdmittedFPS: cadenceAdmittedFPS,
            deliveryFPS: deliveryFPS,
            startupReadiness: startupReadiness
        )
    }

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
        #expect(MirageHostCaptureBenchmarkReport.currentVersion == 2)

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
        let staleReport = MirageHostCaptureBenchmarkReport(
            version: 0,
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

        #expect(
            report.isReusable(
                machineID: machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: configuration
            )
        )
        #expect(
            !staleReport.isReusable(
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

    @Test("Summary tracks the highest valid stage and highest sustained 120 fps stage")
    func summaryTracksValidAnd120Stages() {
        let summary = captureBenchmarkSummary(
            stageResults: [
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark1080p,
                    status: .completed,
                    validatedCapabilityFPS: 119.8
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark2K,
                    status: .completed,
                    validatedCapabilityFPS: 76.4
                ),
                MirageHostCaptureBenchmarkStageResult(
                    stage: .benchmark4K,
                    status: .completed,
                    validatedCapabilityFPS: 59.9
                ),
            ]
        )

        #expect(summary.targetFrameRate == 120)
        #expect(summary.validThresholdFPS == 60)
        #expect(summary.sustainThresholdFPS == 114)
        #expect(summary.highestValidStageID == MirageHostCaptureBenchmarkStage.benchmark2K.id)
        #expect(summary.highestValidStageTitle == "2K")
        #expect(summary.highestValidResolution == "2560x1440")
        #expect(summary.highest120FPSStageID == MirageHostCaptureBenchmarkStage.benchmark1080p.id)
        #expect(summary.highest120FPSStageTitle == "1080p")
        #expect(summary.highest120FPSResolution == "1920x1080")
    }

    @Test("Report exposes capture capability for quality summaries")
    func reportExposesCaptureCapability() throws {
        let report = MirageHostCaptureBenchmarkReport(
            machineID: UUID(),
            hostName: "Host",
            hardwareModelIdentifier: nil,
            hardwareMachineFamily: nil,
            appVersion: "1.0",
            buildVersion: "1",
            operatingSystemVersion: "macOS 15.4",
            configuration: MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOff]),
            measuredAt: Date(timeIntervalSince1970: 100),
            modeResults: [
                MirageHostCaptureBenchmarkModeResult(
                    modeSelection: .lowPowerOff,
                    lowPowerModeEnabled: false,
                    stageResults: [
                        MirageHostCaptureBenchmarkStageResult(
                            stage: .benchmark1080p,
                            status: .completed,
                            validatedCapabilityFPS: 119
                        ),
                        MirageHostCaptureBenchmarkStageResult(
                            stage: .benchmark2K,
                            status: .completed,
                            validatedCapabilityFPS: 76
                        ),
                        MirageHostCaptureBenchmarkStageResult(
                            stage: .benchmark4K,
                            status: .completed,
                            validatedCapabilityFPS: 58
                        ),
                    ]
                )
            ],
            didCancel: false
        )

        let capability = try #require(report.captureCapability)

        #expect(capability.highestValidPixelWidth == 2560)
        #expect(capability.highestValidPixelHeight == 1440)
        #expect(capability.highestSustainedPixelWidth == 1920)
        #expect(capability.highestSustainedPixelHeight == 1080)
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

        let refreshAdjustedResult = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark4K,
            status: .completed,
            actualPixelWidth: 3840,
            actualPixelHeight: 2156,
            reportedDisplayRefreshRate: 120
        )
        #expect(refreshAdjustedResult.actualDisplayModeDescription == "3840x2156")
    }

    @Test("Invalid measurement reason rejects blank startup")
    func invalidMeasurementReasonRejectsBlankStartup() {
        let reason = captureBenchmarkInvalidMeasurementReason(
            startupReadiness: .blankOrSuspendedOnly,
            targetFrameRate: 120
        )

        #expect(reason?.contains("blank or suspended") == true)
    }

    @Test("Invalid measurement reason rejects display cadence probe failures")
    func invalidMeasurementReasonRejectsDisplayCadenceProbeFailure() {
        let reason = captureBenchmarkInvalidMeasurementReason(
            displayCadenceProbeFailed: true,
            targetFrameRate: 120
        )

        #expect(reason?.contains("cadence probe failed") == true)
    }

    @Test("Source frame matching requires the settled stage size but ignores global origin")
    func sourceFrameMatchingRequiresSettledStageSize() {
        let expectedFrame = CGRect(x: 2880, y: 0, width: 960, height: 536)

        #expect(
            captureBenchmarkSourceFrameMatchesExpected(
                expectedFrame: expectedFrame,
                actualFrame: CGRect(x: 0, y: 0, width: 960, height: 536)
            )
        )
        #expect(
            !captureBenchmarkSourceFrameMatchesExpected(
                expectedFrame: expectedFrame,
                actualFrame: CGRect(x: 0, y: 0, width: 8, height: 8)
            )
        )
        #expect(
            !captureBenchmarkSourceFrameMatchesExpected(
                expectedFrame: expectedFrame,
                actualFrame: CGRect(x: 0, y: 0, width: 1280, height: 720)
            )
        )
    }

    @Test("Invalid measurement reason does not reject valid but subtarget throughput")
    func invalidMeasurementReasonAllowsSubtargetThroughput() {
        let reason = captureBenchmarkInvalidMeasurementReason(
            startupReadiness: .usableFrameSeen,
            targetFrameRate: 120
        )

        #expect(reason == nil)
    }

    @Test("Capability fps uses source generation, ingress, delivery, and encode floors")
    func capabilityFPSUsesValidatedBottleneck() {
        let sourceGenerationLimited = captureBenchmarkValidatedCapabilityFPS(
            sourceGenerationFPS: 92.5,
            sourcePhase: phaseResult(
                kind: .source,
                rawIngressFPS: 121,
                renderableIngressFPS: 120.4,
                cadenceAdmittedFPS: 120.0,
                deliveryFPS: 119.8
            ),
            displayPhase: phaseResult(
                kind: .display,
                rawIngressFPS: 118.4,
                renderableIngressFPS: 118.0,
                cadenceAdmittedFPS: 117.8,
                deliveryFPS: 117.6
            ),
            encodeFPS: 117.2,
            targetFrameRate: 120
        )
        let encodeLimited = captureBenchmarkValidatedCapabilityFPS(
            sourceGenerationFPS: 121,
            sourcePhase: phaseResult(
                kind: .source,
                rawIngressFPS: 121,
                renderableIngressFPS: 120.4,
                cadenceAdmittedFPS: 120.0,
                deliveryFPS: 119.8
            ),
            displayPhase: phaseResult(
                kind: .display,
                rawIngressFPS: 118.4,
                renderableIngressFPS: 118.0,
                cadenceAdmittedFPS: 117.8,
                deliveryFPS: 117.6
            ),
            encodeFPS: 97.2,
            targetFrameRate: 120
        )
        let capped = captureBenchmarkValidatedCapabilityFPS(
            sourceGenerationFPS: 144,
            sourcePhase: phaseResult(
                kind: .source,
                rawIngressFPS: 144,
                renderableIngressFPS: 141,
                cadenceAdmittedFPS: 140,
                deliveryFPS: 139
            ),
            displayPhase: phaseResult(
                kind: .display,
                rawIngressFPS: 136,
                renderableIngressFPS: 132,
                cadenceAdmittedFPS: 131,
                deliveryFPS: 130
            ),
            encodeFPS: 132,
            targetFrameRate: 120
        )
        let displayCapability = captureBenchmarkDisplayCapabilityFPS(
            displayPhase: phaseResult(
                kind: .display,
                rawIngressFPS: 118.4,
                renderableIngressFPS: 117.2,
                cadenceAdmittedFPS: 116.9,
                deliveryFPS: 116.8
            ),
            targetFrameRate: 120
        )

        #expect(sourceGenerationLimited == 92.5)
        #expect(encodeLimited == 97.2)
        #expect(capped == 120)
        #expect(displayCapability == 116.8)
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

    @Test("Bottleneck classification is ordered across source, ingress, delivery, and encode")
    func bottleneckClassificationIsOrdered() {
        let healthySource = phaseResult(
            kind: .source,
            rawIngressFPS: 120,
            renderableIngressFPS: 120,
            cadenceAdmittedFPS: 120,
            deliveryFPS: 120
        )
        let healthyDisplay = phaseResult(
            kind: .display,
            rawIngressFPS: 120,
            renderableIngressFPS: 120,
            cadenceAdmittedFPS: 120,
            deliveryFPS: 120
        )

        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 100,
                sourcePhase: healthySource,
                displayPhase: healthyDisplay,
                encodeFPS: 120
            ) == .sourceGeneration
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: phaseResult(
                    kind: .source,
                    rawIngressFPS: 110,
                    renderableIngressFPS: 109,
                    cadenceAdmittedFPS: 109,
                    deliveryFPS: 109
                ),
                displayPhase: healthyDisplay,
                encodeFPS: 120
            ) == .windowIngress
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: phaseResult(
                    kind: .source,
                    rawIngressFPS: 120,
                    renderableIngressFPS: 120,
                    cadenceAdmittedFPS: 110,
                    deliveryFPS: 109
                ),
                displayPhase: healthyDisplay,
                encodeFPS: 120
            ) == .windowDelivery
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: healthySource,
                displayPhase: phaseResult(
                    kind: .display,
                    rawIngressFPS: 110,
                    renderableIngressFPS: 109,
                    cadenceAdmittedFPS: 109,
                    deliveryFPS: 109
                ),
                encodeFPS: 120
            ) == .displayIngress
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: healthySource,
                displayPhase: phaseResult(
                    kind: .display,
                    rawIngressFPS: 120,
                    renderableIngressFPS: 120,
                    cadenceAdmittedFPS: 110,
                    deliveryFPS: 109
                ),
                encodeFPS: 120
            ) == .displayDelivery
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: healthySource,
                displayPhase: healthyDisplay,
                encodeFPS: 100
            ) == .encode
        )
        #expect(
            captureBenchmarkBottleneck(
                stage: .benchmark1080p,
                sourceGenerationFPS: 120,
                sourcePhase: healthySource,
                displayPhase: healthyDisplay,
                encodeFPS: 120
            ) == .balanced
        )
    }

    @Test("Warning classification derives from bottleneck and cadence mismatch")
    func warningClassificationDistinguishesBottlenecks() {
        let warnings = captureBenchmarkWarnings(
            stage: .benchmark1080p,
            reportedDisplayRefreshRate: 120,
            observedDisplayCadenceFPS: 60,
            bottleneck: .displayDelivery
        )
        let balancedWarnings = captureBenchmarkWarnings(
            stage: .benchmark1080p,
            reportedDisplayRefreshRate: 120,
            observedDisplayCadenceFPS: 119,
            bottleneck: .balanced
        )

        #expect(warnings.contains(.displayCadenceMismatch))
        #expect(warnings.contains(.displayDeliveryBelowTarget))
        #expect(!warnings.contains(.encodeBelowTarget))
        #expect(balancedWarnings.isEmpty)
    }

    @Test("Source clock measures source generation separately from capture delivery")
    func sourceClockMeasuresSourceGeneration() {
        let sourceClock = MirageHostCaptureBenchmarkSourceClock()
        sourceClock.beginMeasurement()
        for _ in 0 ..< 240 {
            sourceClock.noteDisplayTick()
        }
        let fps = sourceClock.completeMeasurement(durationSeconds: 2.0)

        #expect(fps != nil)
        #expect(abs((fps ?? 0) - 120) < 0.000_1)
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
