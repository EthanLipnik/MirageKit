//
//  MirageDiagnosticsRecorderLoomTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
@testable import MirageConnectivity
import Loom
import MirageDiagnostics
import Testing

@Suite("Mirage Diagnostics Recorder Loom Bridge")
struct MirageDiagnosticsRecorderLoomTests {
    @Test("Diagnostics recorder emits Loom log and error events")
    func diagnosticsRecorderEmitsLoomLogAndErrorEvents() async {
        let sink = RecordingLoomDiagnosticsSink()
        let token = await LoomDiagnostics.addSink(sink)

        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(
            typeName: "NSError",
            domain: "MirageDiagnosticsRecorderLoomTests",
            code: 42
        )
        MirageDiagnosticsRecorder.recordLog(
            date: Date(timeIntervalSinceReferenceDate: 1),
            category: .client,
            level: .debug,
            message: "bridge log",
            fileID: "MirageDiagnosticsRecorderLoomTests.swift",
            line: 20,
            function: "diagnosticsRecorderEmitsLoomLogAndErrorEvents()"
        )
        MirageDiagnosticsRecorder.recordLoggerError(
            date: Date(timeIntervalSinceReferenceDate: 2),
            category: .host,
            severity: .fault,
            message: "bridge error",
            fileID: "MirageDiagnosticsRecorderLoomTests.swift",
            line: 30,
            function: "diagnosticsRecorderEmitsLoomLogAndErrorEvents()",
            metadata: metadata
        )

        let delivered = await Self.waitUntil {
            await sink.hasBridgeEvents
        }

        let log = await sink.logEvent(message: "bridge log")
        let error = await sink.errorEvent(message: "bridge error")
        await LoomDiagnostics.removeSink(token)

        #expect(delivered)
        #expect(log?.category.rawValue == MirageDiagnostics.MirageLogCategory.client.rawValue)
        #expect(log?.level == .debug)
        #expect(log?.message == "bridge log")
        #expect(error?.category.rawValue == MirageDiagnostics.MirageLogCategory.host.rawValue)
        #expect(error?.severity == .fault)
        #expect(error?.source == .logger)
        #expect(error?.metadata?.domain == metadata.domain)
        #expect(error?.metadata?.code == metadata.code)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor RecordingLoomDiagnosticsSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []
    private var errors: [LoomDiagnosticsErrorEvent] = []

    var hasBridgeEvents: Bool {
        logs.contains { $0.message == "bridge log" } &&
            errors.contains { $0.message == "bridge error" }
    }

    func logEvent(message: String) -> LoomDiagnosticsLogEvent? {
        logs.last { $0.message == message }
    }

    func errorEvent(message: String) -> LoomDiagnosticsErrorEvent? {
        errors.last { $0.message == message }
    }

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event)
    }
}
