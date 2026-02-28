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
    @Test("Post-resize decode admission stays keyframe-only until first frame")
    func postResizeDecodeAdmissionStaysKeyframeOnlyUntilFirstFrame() {
        let dropDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: true,
            isKeyframe: false
        )
        let acceptKeyframeDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: true,
            isKeyframe: true
        )
        let acceptNormalDecision = StreamController.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: false,
            isKeyframe: false
        )

        #expect(dropDecision == .dropNonKeyframeWhileAwaitingFirstFrame)
        #expect(acceptKeyframeDecision == .accept)
        #expect(acceptNormalDecision == .accept)
    }

    @Test("Local-resize decode admission drops while paused")
    func localResizeDecodeAdmissionDropsWhilePaused() {
        let dropDecision = StreamController.localResizeDecodeAdmissionDecision(
            decodePausedForLocalResize: true
        )
        let acceptDecision = StreamController.localResizeDecodeAdmissionDecision(
            decodePausedForLocalResize: false
        )

        #expect(dropDecision == .dropWhileLocalResizePaused)
        #expect(acceptDecision == .accept)
    }

    @Test("Suspend and resume local-resize decode toggles pause state")
    func suspendAndResumeLocalResizeDecodeTogglesPauseState() async {
        let controller = StreamController(streamID: 91, maxPayloadSize: 1200)

        await controller.suspendDecodeForLocalResize()
        #expect(await controller.decodePausedForLocalResize)

        await controller.resumeDecodeAfterLocalResize(requestRecoveryKeyframe: false)
        #expect(!(await controller.decodePausedForLocalResize))

        await controller.stop()
    }

    @Test("Passive to active tier promotion requests immediate keyframe recovery")
    func passiveToActiveTierPromotionRequestsKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 92, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.updatePresentationTier(.passiveSnapshot)
        await controller.updatePresentationTier(.activeLive)
        try await waitUntil("tier promotion keyframe request") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
    }

    @Test("Reset re-arms first-frame callback for post-resize transitions")
    func resetRearmsFirstFrameCallbackForPostResizeTransition() async throws {
        let firstFrameCounter = LockedCounter()
        let controller = StreamController(streamID: 90, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: nil,
            onResizeEvent: nil,
            onResizeStateChanged: nil,
            onFrameDecoded: nil,
            onFirstFramePresented: {
                firstFrameCounter.increment()
            },
            onAdaptiveFallbackNeeded: nil
        )

        await controller.markFirstFramePresented()
        try await waitUntil("initial first-frame callback") {
            firstFrameCounter.value == 1
        }
        #expect(await controller.hasPresentedFirstFrame)

        await controller.resetForNewSession()
        #expect(!(await controller.hasPresentedFirstFrame))
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.beginPostResizeTransition()
        #expect(await controller.awaitingFirstFrameAfterResize)

        await controller.markFirstFramePresented()
        try await waitUntil("post-resize first-frame callback") {
            firstFrameCounter.value == 2
        }

        #expect(await controller.hasPresentedFirstFrame)
        #expect(!(await controller.awaitingFirstFrameAfterResize))

        await controller.stop()
    }

    @Test("Decode enqueue signals render listeners through stream store")
    func decodeEnqueueSignalsRenderListeners() {
        let streamID: StreamID = 50
        let owner = NSObject()
        let signalCounter = LockedCounter()

        MirageFrameCache.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: owner) {
            signalCounter.increment()
        }
        defer {
            MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: owner)
            MirageFrameCache.shared.clear(for: streamID)
        }

        MirageFrameCache.shared.store(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        #expect(signalCounter.value == 1)
    }

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
            onFirstFramePresented: nil,
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

    @Test("Backpressure threshold does not request keyframe recovery")
    func backpressureDoesNotRequestKeyframes() async throws {
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

        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        // Additional drops inside cooldown should remain no-op.
        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        clock.advance(by: 1.1)
        await controller.recordQueueDrop()
        await controller.maybeLogDecodeBackpressure(queueDepth: 6)
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

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
            onFirstFramePresented: nil,
            onAdaptiveFallbackNeeded: {
                fallbackCounter.increment()
            }
        )

        await controller.recordDecodeThresholdEvent()
        try await Task.sleep(for: .milliseconds(50))
        await controller.recordDecodeThresholdEvent()
        try await waitUntil("decode threshold fallback trigger", timeout: .seconds(5)) {
            fallbackCounter.value == 1
        }

        #expect(fallbackCounter.value == 1)

        await controller.stop()
    }

    @Test("Decode threshold recovery is soft-first and escalates to hard reset")
    func decodeThresholdRecoveryEscalatesAfterRepeatedFailures() async throws {
        let streamID: StreamID = 44
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageFrameCache.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 1)

        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(150))
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 1)

        await controller.handleDecodeErrorThresholdSignal()
        await controller.handleDecodeErrorThresholdSignal()
        try await Task.sleep(for: .milliseconds(250))
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)
        // Recovery requests are cooldown-gated, so threshold storms coalesce requests.
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Frame-loss bootstrap requests keyframe before first decoded frame")
    func frameLossBootstrapRequestsKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 40, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.handleFrameLossSignal()
        try await waitUntil("bootstrap keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Frame-loss after first decode without starvation does not request keyframe recovery")
    func frameLossAfterFirstDecodeWithoutStarvationDoesNotRequestKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 41, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        await controller.handleFrameLossSignal()
        try await Task.sleep(for: .milliseconds(150))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
    }

    @Test("Frame-loss after first decode while keyframe-starved requests recovery keyframe")
    func frameLossAfterFirstDecodeWithStarvationRequestsKeyframe() async throws {
        let keyframeCounter = LockedCounter()
        let controller = StreamController(streamID: 42, maxPayloadSize: 1200)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            },
            onResizeEvent: nil
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        await controller.handleFrameLossSignal()
        try await waitUntil("starved frame-loss keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
    }

    @Test("Present-stall monitoring without keyframe starvation does not request keyframe recovery")
    func presentStallWithoutStarvationDoesNotRequestKeyframeRecovery() async throws {
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
            onFirstFramePresented: nil,
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

        try await Task.sleep(for: .seconds(7))
        #expect(keyframeCounter.value == 0)

        await controller.stop()
        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Present-stall while keyframe-starved escalates from soft request to hard recovery")
    func presentStallWhileKeyframeStarvedEscalatesRecovery() async throws {
        let streamID: StreamID = 5
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
            onFirstFramePresented: nil,
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
        let reassembler = await controller.getReassembler()
        reassembler.enterKeyframeOnlyMode()

        try await Task.sleep(for: .seconds(11))
        #expect(keyframeCounter.value >= 2)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)

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
