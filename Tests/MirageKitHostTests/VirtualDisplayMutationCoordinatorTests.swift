//
//  VirtualDisplayMutationCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import Testing

@Suite("Virtual Display Mutation Coordinator")
struct VirtualDisplayMutationCoordinatorTests {
    @Test("Coordinator serializes display mutations")
    func serializesDisplayMutations() async {
        let coordinator = VirtualDisplayMutationCoordinator(
            timingPolicy: VirtualDisplayMutationTimingPolicy(settleDelay: .zero)
        )
        let recorder = MutationRecorder()

        let firstTask = Task {
            await performMutation(coordinator: coordinator, kind: .displayMirroring) {
                await recorder.append("first-start")
                try? await Task.sleep(for: .milliseconds(40))
                await recorder.append("first-end")
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let secondTask = Task {
            await performMutation(coordinator: coordinator, kind: .virtualDisplayModeUpdate) {
                await recorder.append("second-start")
                await recorder.append("second-end")
            }
        }

        await firstTask.value
        await secondTask.value

        #expect(await recorder.events == [
            "first-start",
            "first-end",
            "second-start",
            "second-end",
        ])
    }

    @Test("Coordinator waits for settle before next mutation starts")
    func waitsForSettleBeforeNextMutationStarts() async {
        let coordinator = VirtualDisplayMutationCoordinator(
            timingPolicy: VirtualDisplayMutationTimingPolicy(settleDelay: .milliseconds(80))
        )
        let recorder = MutationTimeRecorder()

        let firstTask = Task {
            await performMutation(coordinator: coordinator, kind: .displayMirroring) {
                await recorder.markFirstEnd()
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let secondTask = Task {
            await performMutation(coordinator: coordinator, kind: .virtualDisplayModeUpdate) {
                await recorder.markSecondStart()
            }
        }

        await firstTask.value
        await secondTask.value

        let delay = await recorder.delayBetweenFirstEndAndSecondStart
        #expect(delay >= 0.05)
    }
}

private func performMutation(
    coordinator: VirtualDisplayMutationCoordinator,
    kind: VirtualDisplayMutationKind,
    operation: () async -> Void
) async {
    let lease = await coordinator.acquire(kind: kind)
    await operation()
    await coordinator.release(lease)
}

private actor MutationRecorder {
    private var recordedEvents: [String] = []

    var events: [String] {
        recordedEvents
    }

    func append(_ event: String) {
        recordedEvents.append(event)
    }
}

private actor MutationTimeRecorder {
    private var firstEnd: CFAbsoluteTime?
    private var secondStart: CFAbsoluteTime?

    var delayBetweenFirstEndAndSecondStart: CFTimeInterval {
        guard let firstEnd, let secondStart else { return 0 }
        return secondStart - firstEnd
    }

    func markFirstEnd(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        firstEnd = now
    }

    func markSecondStart(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        secondStart = now
    }
}
#endif
