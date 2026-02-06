//
//  StreamControllerRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Decode overload and recovery behavior coverage for StreamController.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Stream Controller Recovery")
struct StreamControllerRecoveryTests {
    @Test("Overload signal triggers adaptive fallback after queue drops and recovery requests")
    func overloadTriggersAdaptiveFallback() async throws {
        let keyframeCounter = LockedCounter()
        let fallbackCounter = LockedCounter()
        let controller = StreamController(streamID: 1, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFrame: nil,
            onInputBlockingChanged: nil,
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        for _ in 0 ..< 12 {
            await controller.recordQueueDrop()
        }
        await controller.requestKeyframeRecovery(reason: "test-1")
        await controller.requestKeyframeRecovery(reason: "test-2")
        try await Task.sleep(for: .milliseconds(100))

        #expect(keyframeCounter.value == 2)
        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Backpressure recovery request is debounced")
    func backpressureRecoveryDebounce() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 2, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.maybeTriggerBackpressureRecovery()
        await controller.maybeTriggerBackpressureRecovery()
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 1)

        try await Task.sleep(for: .milliseconds(1100))
        await controller.maybeTriggerBackpressureRecovery()
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 2)

        await controller.stop()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
#endif
