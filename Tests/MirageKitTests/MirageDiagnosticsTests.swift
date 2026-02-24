//
//  MirageDiagnosticsTests.swift
//  MirageKit
//
//  Created by Codex on 2/23/26.
//
//  Diagnostics fanout, error reporting, and context registry tests.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Diagnostics", .serialized)
struct MirageDiagnosticsTests {
    @Test("Multi-sink fanout delivers every log event")
    func multiSinkFanoutDeliversEvents() async {
        await MirageDiagnostics.removeAllSinks()

        let sinkOne = TestSink()
        let sinkTwo = TestSink()
        _ = await MirageDiagnostics.addSink(sinkOne)
        _ = await MirageDiagnostics.addSink(sinkTwo)

        let event = MirageDiagnosticsLogEvent(
            date: Date(),
            category: .client,
            level: .info,
            message: "fanout-event",
            fileID: #fileID,
            line: #line,
            function: #function
        )
        MirageDiagnostics.record(log: event)

        #expect(await waitUntil {
            let firstCount = await sinkOne.logCount()
            let secondCount = await sinkTwo.logCount()
            return firstCount >= 1 && secondCount >= 1
        })
    }

    @Test("Sink removal stops future deliveries")
    func sinkRemovalStopsFutureDeliveries() async {
        await MirageDiagnostics.removeAllSinks()

        let sink = TestSink()
        let sinkToken = await MirageDiagnostics.addSink(sink)

        MirageDiagnostics.record(log: MirageDiagnosticsLogEvent(
            date: Date(),
            category: .client,
            level: .info,
            message: "before-removal",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
        #expect(await waitUntil { await sink.logCount() >= 1 })
        let baselineCount = await sink.logCount()

        await MirageDiagnostics.removeSink(sinkToken)
        MirageDiagnostics.record(log: MirageDiagnosticsLogEvent(
            date: Date(),
            category: .client,
            level: .info,
            message: "after-removal",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sink.logCount() == baselineCount)
    }

    @Test("Structured report(error:) emits typed diagnostics metadata")
    func reportErrorEmitsStructuredMetadata() async {
        await MirageDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await MirageDiagnostics.addSink(sink)

        let error = NSError(
            domain: "com.mirage.tests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Sensitive text should not appear"]
        )
        MirageDiagnostics.report(
            error: error,
            category: .host,
            source: .report
        )

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected structured error event")
            return
        }

        #expect(event.category == .host)
        #expect(event.source == .report)
        #expect(event.metadata?.domain == "com.mirage.tests")
        #expect(event.metadata?.code == 42)
        #expect(event.metadata?.typeName.contains("NSError") == true)
        #expect(event.message.contains("Sensitive text should not appear") == false)
    }

    @Test("run wrapper reports exactly once and rethrows original error")
    func runWrapperReportsOnceAndRethrows() async {
        await MirageDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await MirageDiagnostics.addSink(sink)

        let expected = NSError(domain: "com.mirage.tests.run", code: 777)
        do {
            _ = try await MirageDiagnostics.run(category: .stream, message: "run wrapper failure") {
                throw expected
            } as Int
            Issue.record("Expected MirageDiagnostics.run to rethrow")
        } catch {
            let rethrown = error as NSError
            #expect(rethrown.domain == expected.domain)
            #expect(rethrown.code == expected.code)
        }

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected run wrapper diagnostics event")
            return
        }

        #expect(event.source == .run)
        #expect(event.category == .stream)
        #expect(event.metadata?.domain == expected.domain)
        #expect(event.metadata?.code == expected.code)
    }

    @Test("Context provider registry snapshots active providers only")
    func contextProviderRegistrySnapshotsActiveProviders() async {
        await MirageDiagnostics.removeAllSinks()

        let firstToken = await MirageDiagnostics.registerContextProvider {
            ["provider.one": .int(1), "shared.key": .string("first")]
        }
        let secondToken = await MirageDiagnostics.registerContextProvider {
            ["provider.two": .bool(true), "shared.key": .string("second")]
        }

        let fullSnapshot = await MirageDiagnostics.snapshotContext()
        #expect(fullSnapshot["provider.one"] == .int(1))
        #expect(fullSnapshot["provider.two"] == .bool(true))
        #expect(fullSnapshot["shared.key"] == .string("second"))

        await MirageDiagnostics.unregisterContextProvider(secondToken)
        let partialSnapshot = await MirageDiagnostics.snapshotContext()
        #expect(partialSnapshot["provider.one"] == .int(1))
        #expect(partialSnapshot["provider.two"] == nil)
        #expect(partialSnapshot["shared.key"] == .string("first"))

        await MirageDiagnostics.unregisterContextProvider(firstToken)
    }

    @Test("Privacy-safe metadata path avoids localized error strings in fallback message")
    func privacySafeFallbackMessageOmitsLocalizedDescription() async {
        await MirageDiagnostics.removeAllSinks()

        let sink = TestSink()
        _ = await MirageDiagnostics.addSink(sink)

        let sensitiveMessage = "hostname=internal.example.local user=ethan"
        let error = NSError(
            domain: "com.mirage.tests.privacy",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: sensitiveMessage]
        )
        MirageDiagnostics.report(error: error, category: .network)

        #expect(await waitUntil { await sink.errorCount() == 1 })
        guard let event = await sink.firstError() else {
            Issue.record("Expected privacy-safe diagnostics event")
            return
        }

        #expect(event.message.contains("type="))
        #expect(event.message.contains("domain="))
        #expect(event.message.contains("code="))
        #expect(event.message.contains(sensitiveMessage) == false)
    }

    private func waitUntil(
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

private actor TestSink: MirageDiagnosticsSink {
    private var logs: [MirageDiagnosticsLogEvent] = []
    private var errors: [MirageDiagnosticsErrorEvent] = []

    func record(log event: MirageDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: MirageDiagnosticsErrorEvent) async {
        errors.append(event)
    }

    func logCount() -> Int {
        logs.count
    }

    func errorCount() -> Int {
        errors.count
    }

    func firstError() -> MirageDiagnosticsErrorEvent? {
        errors.first
    }
}
