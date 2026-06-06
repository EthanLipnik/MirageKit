//
//  MirageClientLabRegistryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
@_spi(Labs) import MirageKit
@_spi(Labs) @testable import MirageKitClient
import Testing
@_spi(Labs) import MirageDiagnostics

@Suite("Mirage Client Lab Registry")
struct MirageClientLabRegistryTests {
    @Test("Standard client registry starts empty until client measurements register runners")
    func standardClientRegistryStartsEmpty() {
        let registry = MirageClientLabRegistry.standard()

        #expect(registry.descriptors.isEmpty)
        #expect(registry.descriptor(id: "client.decode-fixture") == nil)
    }

    @Test("Client registry can run decode and presentation Labs")
    func clientRegistryRunsDecodeAndPresentationLabs() async throws {
        let decodeRunner = FakeClientLabRunner(
            descriptor: testDescriptor(id: "client.decode-fixture", category: .decode)
        )
        let presentationRunner = FakeClientLabRunner(
            descriptor: testDescriptor(id: "client.presentation-fixture", category: .presentation)
        )
        let registry = try MirageClientLabRegistry(
            runners: [decodeRunner, presentationRunner]
        )

        #expect(registry.descriptors.map(\.id) == ["client.decode-fixture", "client.presentation-fixture"])
        #expect(registry.descriptor(id: "client.decode-fixture")?.category == .decode)
        #expect(registry.runner(id: "client.presentation-fixture") != nil)

        let report = try await registry.run(id: "client.presentation-fixture")
        #expect(report.labID == "client.presentation-fixture")
        #expect(report.category == .presentation)
        #expect(report.metrics == [
            MirageDiagnostics.MirageLabMetric(
                id: "frame-latency-p95",
                title: "Frame Latency P95",
                unit: "ms",
                value: 12.4
            ),
        ])
    }

    @Test("Client registry rejects duplicate Lab IDs")
    func clientRegistryRejectsDuplicateLabIDs() {
        let firstRunner = FakeClientLabRunner(
            descriptor: testDescriptor(id: "client.duplicate", category: .decode)
        )
        let secondRunner = FakeClientLabRunner(
            descriptor: testDescriptor(id: "client.duplicate", category: .presentation)
        )

        #expect(throws: MirageDiagnostics.MirageLabRegistryError.duplicateLabID("client.duplicate")) {
            _ = try MirageClientLabRegistry(runners: [firstRunner, secondRunner])
        }
    }
}

private struct FakeClientLabRunner: MirageDiagnostics.MirageLabRunner {
    let descriptor: MirageDiagnostics.MirageLabDescriptor

    func run(
        _ configuration: MirageDiagnostics.MirageLabConfiguration,
        progress: MirageDiagnostics.MirageLabProgressHandler?
    ) async throws -> MirageDiagnostics.MirageLabReport {
        await progress?(
            MirageDiagnostics.MirageLabProgress(
                completedUnitCount: 1,
                totalUnitCount: 1,
                message: "Measured"
            )
        )
        return MirageDiagnostics.MirageLabReport(
            labID: descriptor.id,
            labTitle: descriptor.title,
            category: descriptor.category,
            configuration: configuration,
            measuredAt: Date(timeIntervalSince1970: 770_000_000),
            status: .completed,
            metrics: [
                MirageDiagnostics.MirageLabMetric(
                    id: "frame-latency-p95",
                    title: "Frame Latency P95",
                    unit: "ms",
                    value: 12.4
                ),
            ]
        )
    }
}

private func testDescriptor(
    id: String,
    category: MirageDiagnostics.MirageLabCategory
) -> MirageDiagnostics.MirageLabDescriptor {
    MirageDiagnostics.MirageLabDescriptor(
        id: id,
        title: "Client Lab",
        summary: "Runs a client measurement fixture.",
        category: category,
        defaultConfiguration: MirageDiagnostics.MirageLabConfiguration(
            parameters: ["sampleCount": .int(30)]
        )
    )
}
