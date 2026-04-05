//
//  StreamRecoveryStatusLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Stream Recovery Status Lifecycle")
struct StreamRecoveryStatusLifecycleTests {
    @Test("Presentation progress clears transient recovery states")
    func presentationProgressClearsTransientRecoveryStates() {
        #expect(StreamController.shouldClearRecoveryStatusOnPresentationProgress(.tierPromotionProbe))
        #expect(StreamController.shouldClearRecoveryStatusOnPresentationProgress(.keyframeRecovery))
        #expect(StreamController.shouldClearRecoveryStatusOnPresentationProgress(.hardRecovery))
        #expect(!StreamController.shouldClearRecoveryStatusOnPresentationProgress(.idle))
        #expect(!StreamController.shouldClearRecoveryStatusOnPresentationProgress(.startup))
        #expect(!StreamController.shouldClearRecoveryStatusOnPresentationProgress(.postResizeAwaitingFirstFrame))
    }

    @Test("Presentation progress resets active recovery state back to idle")
    func presentationProgressResetsRecoveryStateToIdle() async {
        let controller = StreamController(streamID: 401, maxPayloadSize: 1200)

        await controller.setClientRecoveryStatus(.hardRecovery)
        await controller.startKeyframeRecoveryLoopIfNeeded()
        await controller.clearTransientRecoveryStateAfterPresentationProgress()

        #expect(await controller.clientRecoveryStatus == .idle)

        await controller.stop()
    }
}
