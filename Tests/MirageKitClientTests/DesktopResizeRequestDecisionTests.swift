//
//  DesktopResizeRequestDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Desktop resize request no-op suppression decisions.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Resize Request Decision")
struct DesktopResizeRequestDecisionTests {
    @Test("Exact host match skips request")
    func exactHostMatchSkipsRequest() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 1600, height: 1200),
            acknowledgedPixelSize: CGSize(width: 3200, height: 2400)
        )

        #expect(decision == .skipNoOp)
    }

    @Test("Host mismatch sends request")
    func hostMismatchSendsRequest() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 1600, height: 1200),
            acknowledgedPixelSize: CGSize(width: 2732, height: 2048)
        )

        #expect(decision == .send)
    }

    @Test("Capped external display match skips request with non-2x point scale")
    func cappedExternalDisplayMatchSkipsRequest() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 3008, height: 1692),
            acknowledgedPixelSize: CGSize(width: 5120, height: 2880),
            pointScale: 1.702127659574468
        )

        #expect(decision == .skipNoOp)
    }

    @Test("Missing host size sends request")
    func missingHostSizeSendsRequest() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 1600, height: 1200),
            acknowledgedPixelSize: .zero
        )

        #expect(decision == .send)
    }

    @Test("Tiny host mismatch can be suppressed with wider tolerance")
    func tinyHostMismatchSkipsWithWiderTolerance() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 1440, height: 1026),
            acknowledgedPixelSize: CGSize(width: 2880, height: 2040),
            pointScale: 2,
            mismatchThresholdPoints: 8
        )

        #expect(decision == .skipNoOp)
    }
}
#endif
