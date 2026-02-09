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

    @Test("Missing host size sends request")
    func missingHostSizeSendsRequest() {
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: CGSize(width: 1600, height: 1200),
            acknowledgedPixelSize: .zero
        )

        #expect(decision == .send)
    }
}
#endif
