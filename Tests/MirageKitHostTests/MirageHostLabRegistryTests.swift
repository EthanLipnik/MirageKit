//
//  MirageHostLabRegistryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
@_spi(Labs) import MirageKit
@_spi(HostApp) @_spi(Labs) @testable import MirageKitHost
import Testing
@_spi(Labs) import MirageDiagnostics

#if os(macOS)
@Suite("Mirage Host Lab Registry")
struct MirageHostLabRegistryTests {
    @Test("Standard host registry includes capture benchmark descriptor")
    func standardHostRegistryIncludesCaptureBenchmarkDescriptor() {
        let registry = MirageHostLabRegistry.standard()
        let descriptor = registry.descriptor(id: MirageHostCaptureBenchmarkLab.id)

        #expect(descriptor?.id == "host.capture-benchmark")
        #expect(descriptor?.category == .capture)
        #expect(descriptor?.defaultConfiguration.parameters["modeSelections"] == .stringArray(["lowPowerOff"]))
    }

    @Test("Capture benchmark Lab configuration round trips")
    func captureBenchmarkLabConfigurationRoundTrips() throws {
        let captureConfiguration = MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(
            modeSelections: [.lowPowerOn, .lowPowerOff],
            stages: [.benchmark1080p, .benchmark2K],
            warmupDurationSeconds: 2,
            measurementDurationSeconds: 6
        )

        let labConfiguration = MirageHostCaptureBenchmarkLab.configuration(for: captureConfiguration)
        let decodedConfiguration = try MirageHostCaptureBenchmarkLab.captureConfiguration(from: labConfiguration)

        #expect(decodedConfiguration == captureConfiguration)
    }

    @Test("Capture benchmark Lab rejects unknown stage IDs")
    func captureBenchmarkLabRejectsUnknownStageIDs() {
        let labConfiguration = MirageDiagnostics.MirageLabConfiguration(
            parameters: ["stageIDs": .stringArray(["missing"])]
        )

        #expect(throws: MirageHostCaptureBenchmarkLabError.unknownStageID("missing")) {
            _ = try MirageHostCaptureBenchmarkLab.captureConfiguration(from: labConfiguration)
        }
    }

    @Test("Capture benchmark report maps to generic Lab report")
    func captureBenchmarkReportMapsToGenericLabReport() {
        let captureReport = makeCaptureReport()
        let labReport = MirageHostCaptureBenchmarkLab.report(from: captureReport)

        #expect(labReport.labID == MirageHostCaptureBenchmarkLab.id)
        #expect(labReport.status == .completed)
        #expect(labReport.metrics.contains { $0.id == "validated-fps.lowPowerOff.1080p" && $0.value == 118 })
        #expect(labReport.metrics.contains { $0.id == "average-encode-ms.lowPowerOff.1080p" && $0.value == 2.4 })
        #expect(labReport.warnings == ["lowPowerOff.1080p: displayCadenceMismatch"])
        #expect(labReport.invalidationReasons.isEmpty)
    }

    @Test("Capture benchmark runner bridges progress and report")
    func captureBenchmarkRunnerBridgesProgressAndReport() async throws {
        let progressRecorder = HostLabProgressRecorder()
        let configurationRecorder = CaptureConfigurationRecorder()
        let runner = MirageHostCaptureBenchmarkLabRunner { configuration, progress in
            await configurationRecorder.set(configuration)
            await progress?(
                MirageDiagnostics.MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: .lowPowerOff,
                    stage: .benchmark1080p,
                    completedStageCount: 1,
                    totalStageCount: 2,
                    message: "Measuring"
                )
            )
            return makeCaptureReport(configuration: configuration)
        }

        let labReport = try await runner.run(
            MirageHostCaptureBenchmarkLab.configuration(
                for: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration(
                    modeSelections: [.lowPowerOff],
                    stages: [.benchmark1080p]
                )
            )
        ) { progress in
            await progressRecorder.append(progress)
        }

        #expect(await configurationRecorder.configuration?.stages == [.benchmark1080p])
        #expect(await progressRecorder.messages == ["Measuring"])
        #expect(labReport.labID == MirageHostCaptureBenchmarkLab.id)
    }
}

private actor HostLabProgressRecorder {
    private var progressMessages: [String] = []

    var messages: [String] {
        progressMessages
    }

    func append(_ progress: MirageDiagnostics.MirageLabProgress) {
        progressMessages.append(progress.message)
    }
}

private actor CaptureConfigurationRecorder {
    private(set) var configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration?

    func set(_ configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration) {
        self.configuration = configuration
    }
}

private func makeCaptureReport(
    configuration: MirageDiagnostics.MirageHostCaptureBenchmarkConfiguration = .standard
) -> MirageDiagnostics.MirageHostCaptureBenchmarkReport {
    MirageDiagnostics.MirageHostCaptureBenchmarkReport(
        machineID: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!,
        hostName: "Bench Mac",
        hardwareModelIdentifier: "Mac16,7",
        hardwareMachineFamily: "MacBook Pro",
        appVersion: "2.4",
        buildVersion: "812",
        operatingSystemVersion: "macOS 15.4 (24E214)",
        configuration: configuration,
        measuredAt: Date(timeIntervalSince1970: 770_000_000),
        modeResults: [
            MirageDiagnostics.MirageHostCaptureBenchmarkModeResult(
                modeSelection: .lowPowerOff,
                lowPowerModeEnabled: false,
                stageResults: [
                    MirageDiagnostics.MirageHostCaptureBenchmarkStageResult(
                        stage: .benchmark1080p,
                        status: .completed,
                        encodeFPS: 119,
                        validatedCapabilityFPS: 118,
                        averageEncodeTimeMs: 2.4,
                        warnings: [.displayCadenceMismatch]
                    ),
                ]
            ),
        ],
        didCancel: false
    )
}
#endif
