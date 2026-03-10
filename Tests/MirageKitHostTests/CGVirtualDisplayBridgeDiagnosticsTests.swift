//
//  CGVirtualDisplayBridgeDiagnosticsTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 3/7/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("CGVirtualDisplayBridge Diagnostics", .serialized)
struct CGVirtualDisplayBridgeDiagnosticsTests {
    @Test("Probe failures stay out of diagnostics errors")
    func probeFailuresStayOutOfDiagnosticsErrors() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = CGVirtualDisplayBridgeTestSink()
        _ = await LoomDiagnostics.addSink(sink)

        CGVirtualDisplayBridge.logVirtualDisplaySettingsProbeFailure(
            attemptLabel: "pixel-hiDPI0",
            transferFunctionLabel: "sRGB(13)"
        )
        CGVirtualDisplayBridge.logVirtualDisplayCreationProbeFailure(profileLabel: "serial0-global-queue")
        CGVirtualDisplayBridge.logVirtualDisplayResolutionUpdateFailure(
            hiDPI: false,
            isTerminal: false
        )

        #expect(await waitUntil { await sink.logCount() >= 3 })
        #expect(await sink.errorCount() == 0)

        let messages = await sink.logMessages()
        #expect(messages.contains { $0.contains("settings probe failed") })
        #expect(messages.contains { $0.contains("initialization failed for profile serial0-global-queue") })
        #expect(messages.contains { $0.contains("resolution update probe failed 1x activation") })
    }

    @Test("Terminal update failures still emit diagnostics errors")
    func terminalUpdateFailuresStillEmitDiagnosticsErrors() async {
        await LoomDiagnostics.removeAllSinks()

        let sink = CGVirtualDisplayBridgeTestSink()
        _ = await LoomDiagnostics.addSink(sink)

        CGVirtualDisplayBridge.logVirtualDisplayResolutionUpdateFailure(
            hiDPI: true,
            isTerminal: true
        )

        #expect(await waitUntil { await sink.errorCount() == 1 })

        guard let event = await sink.firstError() else {
            Issue.record("Expected diagnostics error event for terminal virtual display update failure")
            return
        }

        #expect(event.category == LoomLogCategory(rawValue: MirageLogCategory.host.rawValue))
        #expect(event.message.contains("Updated virtual display failed Retina activation"))
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
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

private actor CGVirtualDisplayBridgeTestSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []
    private var errors: [LoomDiagnosticsErrorEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event)
    }

    func logCount() -> Int {
        logs.count
    }

    func errorCount() -> Int {
        errors.count
    }

    func logMessages() -> [String] {
        logs.map(\.message)
    }

    func firstError() -> LoomDiagnosticsErrorEvent? {
        errors.first
    }
}
#endif
