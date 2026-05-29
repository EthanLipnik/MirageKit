//
//  StreamControllerTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation

#if os(macOS)
extension StreamController {
    /// Applies a symmetric source/display cadence for decode-submission scheduler tests.
    func updateDecodeSubmissionLimit(targetFrameRate: Int) async {
        await updateCadenceTarget(
            sourceFPS: targetFrameRate,
            displayFPS: targetFrameRate,
            reason: "test target refresh update"
        )
    }

    /// Seeds presentation timing so freeze-monitor tests can exercise stall recovery without rendering frames.
    func simulatePresentationStall(now: CFAbsoluteTime? = nil) {
        let referenceNow = now ?? currentTime
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        lastPresentedProgressTime = referenceNow - Self.freezeTimeout - 0.5
    }

    func testSeedFrameRates(
        decodedFPS: Int,
        receivedFPS: Int,
        now: CFAbsoluteTime
    ) {
        metricsTracker.reset()
        for _ in 0 ..< max(0, decodedFPS) {
            _ = metricsTracker.recordDecodedFrame(now: now)
        }
        for _ in 0 ..< max(0, receivedFPS) {
            metricsTracker.recordReceivedFrame(now: now)
        }
    }

    func testSeedHostMetrics(
        encodedFPS: Double,
        targetFrameRate: Int = 60,
        currentBitrate: Int? = nil,
        sendQueueBytes: Int? = nil,
        sendCompletionMaxMs: Double? = nil,
        nonKeyframeSendCompletionMaxMs: Double? = nil,
        senderLocalDeadlineDrops: UInt64? = nil,
        stalePacketDrops: UInt64? = nil,
        generationAbortDrops: UInt64? = nil,
        nonKeyframeHoldDrops: UInt64? = nil
    ) {
        updateHostMetrics(
            StreamMetricsMessage(
                streamID: streamID,
                encodedFPS: encodedFPS,
                idleEncodedFPS: 0,
                droppedFrames: 0,
                activeQuality: 0.5,
                targetFrameRate: targetFrameRate,
                currentBitrate: currentBitrate,
                sendQueueBytes: sendQueueBytes,
                sendCompletionMaxMs: sendCompletionMaxMs,
                nonKeyframeSendCompletionMaxMs: nonKeyframeSendCompletionMaxMs,
                stalePacketDrops: stalePacketDrops,
                senderLocalDeadlineDrops: senderLocalDeadlineDrops,
                generationAbortDrops: generationAbortDrops,
                nonKeyframeHoldDrops: nonKeyframeHoldDrops
            )
        )
    }

    func testSeedLatestPacketReceivedTime(_ time: CFAbsoluteTime) {
        reassembler.lock.lock()
        reassembler.lastPacketReceivedTime = time
        reassembler.lock.unlock()
    }
}
#endif
