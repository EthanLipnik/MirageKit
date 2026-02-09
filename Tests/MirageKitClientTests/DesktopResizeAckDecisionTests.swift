//
//  DesktopResizeAckDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/8/26.
//
//  Desktop resize acknowledgement decision coverage.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Resize Ack Decision")
struct DesktopResizeAckDecisionTests {
    @Test("No mismatch converges immediately")
    func noMismatchConverges() {
        let decision = desktopResizeAckDecision(
            acknowledgedDisplaySize: CGSize(width: 978, height: 874),
            targetDisplaySize: CGSize(width: 978, height: 874),
            correctionAlreadySent: false
        )

        #expect(decision == .converged)
    }

    @Test("Mismatch requests one correction")
    func mismatchRequestsCorrection() {
        let decision = desktopResizeAckDecision(
            acknowledgedDisplaySize: CGSize(width: 970, height: 860),
            targetDisplaySize: CGSize(width: 978, height: 874),
            correctionAlreadySent: false
        )

        #expect(decision == .requestCorrection)
    }

    @Test("Mismatch after correction waits for timeout")
    func mismatchAfterCorrectionWaitsForTimeout() {
        let decision = desktopResizeAckDecision(
            acknowledgedDisplaySize: CGSize(width: 970, height: 860),
            targetDisplaySize: CGSize(width: 978, height: 874),
            correctionAlreadySent: true
        )

        #expect(decision == .waitForTimeout)
    }
}
#endif
