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
}
#endif
