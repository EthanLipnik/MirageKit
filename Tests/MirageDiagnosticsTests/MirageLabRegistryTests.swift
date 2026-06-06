//
//  MirageLabRegistryTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
@_spi(Labs) @testable import MirageDiagnostics
import Testing
@_spi(Labs) import MirageDiagnostics

@Suite("Mirage Lab Registry")
struct MirageLabRegistryTests {
    @Test("Registry runs fake Lab with default configuration")
    func registryRunsFakeLabWithDefaultConfiguration() async throws {
        let runner = FakeLabRunner(
            descriptor: testDescriptor(id: "fake.capture")
        ) { configuration, progress in
            await progress?(MirageDiagnostics.MirageLabProgress(completedUnitCount: 1, totalUnitCount: 2, message: "Half"))
            return testReport(
                labID: "fake.capture",
                configuration: configuration,
                metrics: [
                    MirageDiagnostics.MirageLabMetric(id: "fps", title: "Frames", unit: "fps", value: 118.5),
                ]
            )
        }
        let registry = try MirageDiagnostics.MirageLabRegistry(runners: [runner])
        let progressRecorder = ProgressRecorder()

        let report = try await registry.run(id: "fake.capture") { progress in
            await progressRecorder.append(progress.message)
        }

        #expect(registry.descriptors.map(\.id) == ["fake.capture"])
        #expect(report.labID == "fake.capture")
        #expect(report.configuration.parameters["mode"] == .string("standard"))
        #expect(report.metrics.first?.value == 118.5)
        #expect(await progressRecorder.messages == ["Half"])
    }

    @Test("Registry rejects duplicate Lab IDs")
    func registryRejectsDuplicateLabIDs() {
        let firstRunner = FakeLabRunner(descriptor: testDescriptor(id: "duplicate")) { configuration, _ in
            testReport(labID: "duplicate", configuration: configuration)
        }
        let secondRunner = FakeLabRunner(descriptor: testDescriptor(id: "duplicate")) { configuration, _ in
            testReport(labID: "duplicate", configuration: configuration)
        }

        #expect(throws: MirageDiagnostics.MirageLabRegistryError.duplicateLabID("duplicate")) {
            _ = try MirageDiagnostics.MirageLabRegistry(runners: [firstRunner, secondRunner])
        }
    }

    @Test("Registry reports unknown and unavailable Labs")
    func registryReportsUnknownAndUnavailableLabs() async throws {
        let unavailableRunner = FakeLabRunner(
            descriptor: testDescriptor(
                id: "unavailable",
                availability: .unavailable("Fixture unavailable")
            )
        ) { configuration, _ in
            testReport(labID: "unavailable", configuration: configuration)
        }
        let registry = try MirageDiagnostics.MirageLabRegistry(runners: [unavailableRunner])

        await #expect(throws: MirageDiagnostics.MirageLabRegistryError.unknownLabID("missing")) {
            try await registry.run(id: "missing")
        }
        await #expect(throws: MirageDiagnostics.MirageLabRegistryError.unavailableLab("unavailable")) {
            try await registry.run(id: "unavailable")
        }
    }

    @Test("Lab report storage saves, loads, and exports JSON")
    func labReportStorageSavesLoadsAndExportsJSON() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let report = testReport(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!,
            labID: "storage",
            configuration: .empty,
            warnings: ["Warmup was short"]
        )
        let store = MirageDiagnostics.MirageJSONLabReportStore(directoryURL: directoryURL)

        let storedReport = try store.save(report)
        let loadedReport = try #require(try store.loadReport(id: report.id))
        let exportedData = try MirageDiagnostics.MirageJSONLabReportStore.exportData(for: report)

        #expect(storedReport.fileURL == store.reportFileURL(id: report.id))
        #expect(loadedReport.report == report)
        #expect(String(decoding: exportedData, as: UTF8.self).contains("\"schemaVersion\""))
    }

    @Test("Registry propagates fake runner cancellation")
    func registryPropagatesFakeRunnerCancellation() async throws {
        let runner = FakeLabRunner(descriptor: testDescriptor(id: "slow")) { _, _ in
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let registry = try MirageDiagnostics.MirageLabRegistry(runners: [runner])

        let task = Task {
            try await registry.run(id: "slow")
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected registry run to throw CancellationError")
        } catch is CancellationError {
        }
    }
}

private struct FakeLabRunner: MirageDiagnostics.MirageLabRunner {
    let descriptor: MirageDiagnostics.MirageLabDescriptor
    let runBody: @Sendable (
        MirageDiagnostics.MirageLabConfiguration,
        MirageDiagnostics.MirageLabProgressHandler?
    ) async throws -> MirageDiagnostics.MirageLabReport

    func run(
        _ configuration: MirageDiagnostics.MirageLabConfiguration,
        progress: MirageDiagnostics.MirageLabProgressHandler?
    ) async throws -> MirageDiagnostics.MirageLabReport {
        try await runBody(configuration, progress)
    }
}

private actor ProgressRecorder {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}

private func testDescriptor(
    id: String,
    availability: MirageDiagnostics.MirageLabAvailability = .available
) -> MirageDiagnostics.MirageLabDescriptor {
    MirageDiagnostics.MirageLabDescriptor(
        id: id,
        title: "Fake Lab",
        summary: "Runs a fake deterministic Lab.",
        category: .capture,
        availability: availability,
        defaultConfiguration: MirageDiagnostics.MirageLabConfiguration(
            parameters: ["mode": .string("standard")]
        )
    )
}

private func testReport(
    id: UUID = UUID(),
    labID: String,
    configuration: MirageDiagnostics.MirageLabConfiguration,
    metrics: [MirageDiagnostics.MirageLabMetric] = [],
    warnings: [String] = []
) -> MirageDiagnostics.MirageLabReport {
    MirageDiagnostics.MirageLabReport(
        id: id,
        labID: labID,
        labTitle: "Fake Lab",
        category: .capture,
        configuration: configuration,
        measuredAt: Date(timeIntervalSince1970: 770_000_000),
        status: .completed,
        metrics: metrics,
        warnings: warnings
    )
}
