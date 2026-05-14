//
//  StreamControllerTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

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
}
#endif
