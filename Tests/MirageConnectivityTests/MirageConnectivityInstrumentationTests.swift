//
//  MirageConnectivityInstrumentationTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

@testable import MirageConnectivity
import Loom
import Testing
import MirageConnectivity
import MirageDiagnostics

@Suite("Mirage Connectivity Instrumentation")
struct MirageConnectivityInstrumentationTests {
    @Test("Instrumentation records Mirage steps into Loom sinks")
    func instrumentationRecordsMirageStepsIntoLoomSinks() async {
        let sink = RecordingLoomInstrumentationSink()
        let token = await LoomInstrumentation.addSink(sink)
        let expectedName = MirageDiagnostics.MirageStepEvent.clientConnectionRequested.name

        MirageConnectivity.MirageInstrumentation.record(.clientConnectionRequested)
        let delivered = await Self.waitUntil {
            await sink.containsStep(named: expectedName)
        }
        await LoomInstrumentation.removeSink(token)

        #expect(delivered)
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

private actor RecordingLoomInstrumentationSink: LoomInstrumentationSink {
    private var stepNames: [String] = []

    func record(event: LoomInstrumentationEvent) async {
        stepNames.append(event.name)
    }

    func containsStep(named name: String) -> Bool {
        stepNames.contains(name)
    }
}
