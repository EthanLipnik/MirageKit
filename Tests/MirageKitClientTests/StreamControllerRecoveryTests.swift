//
//  StreamControllerRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Decode overload and recovery behavior coverage for StreamController.
//

@testable import MirageKitClient
import CoreVideo
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
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        for _ in 0 ..< 12 {
            await controller.recordQueueDrop()
        }
        await controller.requestKeyframeRecovery(reason: .manualRecovery)
        try await Task.sleep(for: .milliseconds(550))
        await controller.requestKeyframeRecovery(reason: .manualRecovery)
        try await Task.sleep(for: .milliseconds(100))

        #expect(keyframeCounter.value == 2)
        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Backpressure recovery requires sustained drops and is debounced")
    func backpressureRecoveryDebounce() async throws {
        let keyframeCounter = LockedCounter()
        let clock = ManualTimeProvider(start: 1_000)
        let controller = StreamController(
            streamID: 2,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        for _ in 0 ..< StreamController.backpressureRecoveryDropThreshold {
            await controller.recordQueueDrop()
        }
        await controller.maybeTriggerBackpressureRecovery(queueDepth: 6)
        try await waitUntil("first backpressure keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        // Additional drops inside cooldown should not trigger another request.
        for _ in 0 ..< StreamController.backpressureRecoveryDropThreshold {
            await controller.recordQueueDrop()
        }
        await controller.maybeTriggerBackpressureRecovery(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 1)

        clock.advance(by: 1.1)
        for _ in 0 ..< StreamController.backpressureRecoveryDropThreshold {
            await controller.recordQueueDrop()
        }
        await controller.maybeTriggerBackpressureRecovery(queueDepth: 6)
        try await waitUntil("second backpressure keyframe request") {
            keyframeCounter.value == 2
        }
        #expect(keyframeCounter.value == 2)

        await controller.stop()
    }

    @Test("Decode threshold storms trigger adaptive fallback without queue-drop threshold")
    func decodeThresholdStormTriggersAdaptiveFallback() async throws {
        let fallbackCounter = LockedCounter()
        let controller = StreamController(streamID: 3, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFrame: nil,
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        await controller.recordDecodeThresholdEvent()
        try await Task.sleep(for: .milliseconds(50))
        await controller.recordDecodeThresholdEvent()
        try await waitUntil("decode threshold fallback trigger") {
            fallbackCounter.value == 1
        }

        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Present-stall freeze recovery triggers keyframe and escalates on repeated stalls")
    func presentStallFreezeRecoveryEscalates() async throws {
        let streamID: StreamID = 4
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFrame: nil,
            onAdaptiveFallbackNeeded: nil
        )

        let pixelBuffer = makePixelBuffer()
        _ = MirageFrameCache.shared.enqueue(
            pixelBuffer,
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent() - 10,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        await controller.recordDecodedFrame()

        try await waitUntil(
            "freeze keyframe recovery trigger",
            timeout: .seconds(8)
        ) {
            keyframeCounter.value >= 1
        }

        try await waitUntil(
            "freeze recovery escalation",
            timeout: .seconds(6)
        ) {
            keyframeCounter.value >= 2
        }

        #expect(keyframeCounter.value >= 2)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
    }

    private func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(20),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        guard let buffer else {
            Issue.record("Failed to create CVPixelBuffer")
            fatalError("Failed to create CVPixelBuffer")
        }
        return buffer
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

private final class ManualTimeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CFAbsoluteTime

    init(start: CFAbsoluteTime) {
        value = start
    }

    var now: CFAbsoluteTime {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: CFAbsoluteTime) {
        lock.lock()
        value += delta
        lock.unlock()
    }
}
#endif
