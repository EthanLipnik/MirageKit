//
//  StreamControllerTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit

#if os(macOS)
extension StreamController {
    /// Applies a symmetric source/display cadence for decode-submission scheduler tests.
    func updateDecodeSubmissionLimit(
        targetFrameRate: Int,
        latencyMode: MirageStreamLatencyMode = .smoothest
    ) async {
        await updateCadenceTarget(
            sourceFPS: targetFrameRate,
            displayFPS: targetFrameRate,
            latencyMode: latencyMode,
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
}
#endif
