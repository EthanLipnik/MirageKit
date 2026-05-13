//
//  StreamControllerDecodeThresholdTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
extension StreamControllerRecoveryTests {
    @Test("Decode threshold requests immediate keyframe")
    func decodeThresholdRequestsImmediateKeyframe() async throws {
        let streamID: StreamID = 44
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            }
        )

        await controller.markFirstFramePresented()
        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("decode-threshold immediate keyframe request") {
            keyframeCounter.value == 1
        }
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Decode threshold requests recovery after sustained freeze")
    func decodeThresholdRequestsRecoveryAfterSustainedFreeze() async throws {
        let streamID: StreamID = 144
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            }
        )

        await controller.markFirstFramePresented()
        let reassembler = await controller.reassembler
        primeStreamControllerKeyframeAnchor(for: reassembler, streamID: streamID)
        await controller.simulatePresentationStall()

        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("decode-threshold keyframe request after freeze") {
            keyframeCounter.value >= 1
        }
        #expect(keyframeCounter.value >= 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Decode threshold before first presented frame requests immediate startup recovery")
    func decodeThresholdBeforeFirstPresentedFrameRequestsImmediateStartupRecovery() async throws {
        let streamID: StreamID = 146
        let keyframeCounter = StreamControllerLockedCounter()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            }
        )
        await controller.updatePresentationTier(.activeLive)

        await controller.handleDecodeErrorThresholdSignal()
        try await streamControllerWaitUntil("startup decode-threshold recovery request") {
            keyframeCounter.value == 1
        }

        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(await controller.firstPresentedFrameWaitStartTime > 0)
        #expect(await !(controller.hasDecodedFirstFrame))
        #expect(keyframeCounter.value == 1)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    @Test("Decode threshold while awaiting recovered presentation requests immediate keyframe")
    func decodeThresholdWhileAwaitingRecoveredPresentationRequestsImmediateKeyframe() async throws {
        let streamID: StreamID = 247
        let keyframeCounter = StreamControllerLockedCounter()
        let clock = StreamControllerManualTimeProvider(start: 4000)
        let controller = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200,
            nowProvider: { clock.now }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)

        await controller.setCallbacks(
            onKeyframeNeeded: {
                keyframeCounter.increment()
            }
        )
        await controller.updatePresentationTier(.activeLive)
        await controller.markFirstFramePresented()

        await controller.requestRecovery(
            reason: .frameLoss,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "test-hard-recovery"
        )
        let baselineRequests = keyframeCounter.value
        #expect(await controller.awaitingFirstPresentedFrame)
        #expect(baselineRequests >= 1)

        clock.advance(by: StreamController.recoveryRequestDispatchCooldown + 0.01)
        await controller.handleDecodeErrorThresholdSignal()

        try await streamControllerWaitUntil("decode-threshold keyframe while awaiting recovered presentation") {
            keyframeCounter.value > baselineRequests
        }
        #expect(await controller.awaitingFirstPresentedFrame)

        await controller.stop()
        MirageRenderStreamStore.shared.clear(for: streamID)
    }
}
#endif
