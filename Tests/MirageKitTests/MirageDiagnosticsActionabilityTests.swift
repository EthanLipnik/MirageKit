//
//  MirageDiagnosticsActionabilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Ensures diagnostics filtering prefers typed error metadata over message parsing.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Diagnostics Actionability")
struct MirageDiagnosticsActionabilityTests {
    @Test("Typed NSURLError metadata is filtered")
    func typedURLErrorMetadataIsFiltered() {
        let event = makeEvent(
            message: "Socket dropped",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSURLErrorDomain,
                code: -1009
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed VideoToolbox BadData metadata is filtered")
    func typedDecoderBadDataMetadataIsFiltered() {
        let event = makeEvent(
            message: "Decode callback failed",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSOSStatusErrorDomain,
                code: -12909
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed metadata wins over message fallback")
    func typedMetadataWinsOverMessageFallback() {
        let event = makeEvent(
            message: "network is down",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: "com.mirage.tests",
                code: 777
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Legacy message fallback applies when metadata is absent")
    func messageFallbackAppliesOnlyWithoutMetadata() {
        let event = makeEvent(
            message: "The Internet connection appears to be offline",
            metadata: nil
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Fault severity is always captured")
    func faultSeverityAlwaysCaptured() {
        let event = MirageDiagnosticsErrorEvent(
            date: Date(),
            category: .client,
            severity: .fault,
            source: .logger,
            message: "fatal",
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: nil
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    private func makeEvent(
        message: String,
        metadata: MirageDiagnosticsErrorMetadata?
    ) -> MirageDiagnosticsErrorEvent {
        MirageDiagnosticsErrorEvent(
            date: Date(),
            category: .network,
            severity: .error,
            source: .logger,
            message: message,
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: metadata
        )
    }
}
