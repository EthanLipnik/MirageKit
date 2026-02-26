//
//  MirageInstrumentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  Instrumentation fanout and sink lifecycle behavior tests.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Instrumentation", .serialized)
struct MirageInstrumentationTests {
    @Test("Multi-sink fanout delivers every step event")
    func multiSinkFanoutDeliversEvents() async {
        await MirageInstrumentation.removeAllSinks()

        let sinkOne = TestInstrumentationSink()
        let sinkTwo = TestInstrumentationSink()
        _ = await MirageInstrumentation.addSink(sinkOne)
        _ = await MirageInstrumentation.addSink(sinkTwo)

        MirageInstrumentation.record(.clientConnectionRequested)

        #expect(await waitUntil {
            let firstCount = await sinkOne.eventCount()
            let secondCount = await sinkTwo.eventCount()
            return firstCount >= 1 && secondCount >= 1
        })
    }

    @Test("Sink removal stops future instrumentation delivery")
    func sinkRemovalStopsFutureDeliveries() async {
        await MirageInstrumentation.removeAllSinks()

        let sink = TestInstrumentationSink()
        let sinkToken = await MirageInstrumentation.addSink(sink)

        MirageInstrumentation.record(.clientConnectionRequested)
        #expect(await waitUntil { await sink.eventCount() >= 1 })
        let baselineCount = await sink.eventCount()

        await MirageInstrumentation.removeSink(sinkToken)
        MirageInstrumentation.record(.clientConnectionEstablished)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sink.eventCount() == baselineCount)
    }

    @Test("removeAllSinks clears all instrumentation recipients")
    func removeAllSinksStopsAllDeliveries() async {
        await MirageInstrumentation.removeAllSinks()

        let sinkOne = TestInstrumentationSink()
        let sinkTwo = TestInstrumentationSink()
        _ = await MirageInstrumentation.addSink(sinkOne)
        _ = await MirageInstrumentation.addSink(sinkTwo)

        MirageInstrumentation.record(.clientConnectionRequested)
        #expect(await waitUntil {
            let firstCount = await sinkOne.eventCount()
            let secondCount = await sinkTwo.eventCount()
            return firstCount >= 1 && secondCount >= 1
        })

        let sinkOneBaseline = await sinkOne.eventCount()
        let sinkTwoBaseline = await sinkTwo.eventCount()

        await MirageInstrumentation.removeAllSinks()
        MirageInstrumentation.record(.clientConnectionFailed)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await sinkOne.eventCount() == sinkOneBaseline)
        #expect(await sinkTwo.eventCount() == sinkTwoBaseline)
    }

    @Test("No sinks skip step construction")
    func noSinksSkipStepConstruction() async {
        await MirageInstrumentation.removeAllSinks()

        let probe = StepProbe()
        MirageInstrumentation.record(probe.nextStep())

        #expect(probe.callCount == 0)
    }

    @Test("Dispatch keeps step event identity")
    func dispatchKeepsStepIdentity() async {
        await MirageInstrumentation.removeAllSinks()

        let sink = TestInstrumentationSink()
        _ = await MirageInstrumentation.addSink(sink)
        let expectedStep: MirageStepEvent = .hostStreamWindowStartedPerformanceMode(.game)
        MirageInstrumentation.record(expectedStep)

        #expect(await waitUntil { await sink.eventCount() >= 1 })
        let event = await sink.latestEvent()
        #expect(event?.step == expectedStep)
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

private final class StepProbe {
    private(set) var callCount = 0

    func nextStep() -> MirageStepEvent {
        callCount += 1
        return .clientConnectionRequested
    }
}

private actor TestInstrumentationSink: MirageInstrumentationSink {
    private var events: [MirageInstrumentationEvent] = []

    func record(event: MirageInstrumentationEvent) async {
        events.append(event)
    }

    func eventCount() -> Int {
        events.count
    }

    func latestEvent() -> MirageInstrumentationEvent? {
        events.last
    }
}
