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
import MirageDiagnostics

#if os(macOS)
@Suite("Capture Benchmark")
struct CaptureBenchmarkTests {
    @Test("Report reuse requires matching machine, software environment, configuration, and a completed run")
    func reportReuseRequiresMatchingEnvironment() {
        #expect(MirageDiagnostics.MirageHostCaptureBenchmarkReport.currentVersion == 3)

        let configuration = MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOff])
        let machineID = UUID()
        let report = MirageDiagnostics.MirageHostCaptureBenchmarkReport(
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
        let cancelledReport = MirageDiagnostics.MirageHostCaptureBenchmarkReport(
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
        let staleReport = MirageDiagnostics.MirageHostCaptureBenchmarkReport(
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
                configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOn])
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

    @Test("Validated benchmark capability uses display capture and encode throughput")
    func validatedCapabilityUsesDisplayCaptureAndEncodeThroughput() {
        let sourcePhase = benchmarkPhaseResult(kind: .source, fps: 60)
        let displayPhase = benchmarkPhaseResult(kind: .display, fps: 119)

        let capability = captureBenchmarkValidatedCapabilityFPS(
            displayPhase: displayPhase,
            encodeFPS: 118,
            targetFrameRate: 120
        )

        #expect(capability == 118)
        #expect(sourcePhase.deliveryFPS == 60)
    }

    @Test("Benchmark stage can sustain target when source window phase is slower")
    func stageCanSustainTargetWhenSourceWindowPhaseIsSlower() {
        let result = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark2K,
            status: .completed,
            sourceGenerationFPS: 60,
            sourcePhase: benchmarkPhaseResult(kind: .source, fps: 60),
            displayPhase: benchmarkPhaseResult(kind: .display, fps: 119),
            encodeFPS: 118,
            validatedCapabilityFPS: 118
        )

        #expect(result.meets120FPS)
    }

    @Test("Benchmark stage still fails target when display capture is slower")
    func stageFailsTargetWhenDisplayCaptureIsSlower() {
        let result = MirageHostCaptureBenchmarkStageResult(
            stage: .benchmark2K,
            status: .completed,
            sourceGenerationFPS: 120,
            sourcePhase: benchmarkPhaseResult(kind: .source, fps: 120),
            displayPhase: benchmarkPhaseResult(kind: .display, fps: 60),
            encodeFPS: 120,
            validatedCapabilityFPS: captureBenchmarkValidatedCapabilityFPS(
                displayPhase: benchmarkPhaseResult(kind: .display, fps: 60),
                encodeFPS: 120,
                targetFrameRate: 120
            )
        )

        #expect(!result.meets120FPS)
    }

    private func benchmarkPhaseResult(
        kind: MirageHostCaptureBenchmarkPhaseKind,
        fps: Double
    ) -> MirageHostCaptureBenchmarkPhaseResult {
        let count = UInt64(fps.rounded())
        return MirageHostCaptureBenchmarkPhaseResult(
            kind: kind,
            rawIngressFPS: fps,
            validSampleFPS: fps,
            renderableIngressFPS: fps,
            cadenceAdmittedFPS: fps,
            deliveryFPS: fps,
            startupReadiness: .usableFrameSeen,
            rawCallbackCount: count,
            validSampleCount: count,
            renderableSampleCount: count,
            completeSampleCount: count,
            cadenceAdmittedCount: count,
            deliveryCount: count
        )
    }
}
#endif
