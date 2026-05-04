//
//  HostScrollInjectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

@Suite("Host scroll injection")
struct HostScrollInjectionTests {
    @Test("Scroll injection point uses event location when present")
    func scrollInjectionPointUsesEventLocation() {
        let windowFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

        let point = MirageHostInputController.scrollInjectionPoint(
            CGPoint(x: 0.25, y: 0.75),
            in: windowFrame
        )

        #expect(point == CGPoint(x: 300, y: 650))
    }

    @Test("Scroll injection point falls back to target window center")
    func scrollInjectionPointFallsBackToWindowCenter() {
        let windowFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

        let point = MirageHostInputController.scrollInjectionPoint(nil, in: windowFrame)

        #expect(point == CGPoint(x: 500, y: 500))
    }

    @Test("Scroll activation policy starts on gesture begin and wheel events")
    func scrollActivationPolicyStartsOnGestureBeginAndWheelEvents() {
        #expect(MirageHostInputController.shouldActivateWindowForScrollEvent(MirageScrollEvent(
            deltaX: 0,
            deltaY: 0,
            phase: .began
        )))
        #expect(MirageHostInputController.shouldActivateWindowForScrollEvent(MirageScrollEvent(
            deltaX: 0,
            deltaY: 12
        )))
        #expect(!MirageHostInputController.shouldActivateWindowForScrollEvent(MirageScrollEvent(
            deltaX: 0,
            deltaY: 12,
            momentumPhase: .changed
        )))
    }
}
#endif
