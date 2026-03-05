//
//  HostInputFastPointerThrottleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Coverage for input-event classification used by host stall-window coalescing.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import CoreGraphics
import Testing

@Suite("Host Input Fast Pointer Throttle")
struct HostInputFastPointerThrottleTests {
    @Test("Only pointer move and drag events are eligible for stall-window throttling")
    func onlyMoveAndDragEventsAreThrottled() {
        let mouseEvent = MirageMouseEvent(location: CGPoint(x: 0.5, y: 0.5), timestamp: 0)

        #expect(MirageHostService.shouldThrottlePointerEventForStallWindow(.mouseMoved(mouseEvent)))
        #expect(MirageHostService.shouldThrottlePointerEventForStallWindow(.mouseDragged(mouseEvent)))
        #expect(MirageHostService.shouldThrottlePointerEventForStallWindow(.rightMouseDragged(mouseEvent)))
        #expect(MirageHostService.shouldThrottlePointerEventForStallWindow(.otherMouseDragged(mouseEvent)))

        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.mouseDown(mouseEvent)))
        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.mouseUp(mouseEvent)))
        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.rightMouseDown(mouseEvent)))
        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.otherMouseDown(mouseEvent)))
        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.scrollWheel(
            MirageScrollEvent(deltaX: 0, deltaY: 1, location: CGPoint(x: 0.5, y: 0.5))
        )))
        #expect(!MirageHostService.shouldThrottlePointerEventForStallWindow(.windowFocus))
    }
}
#endif
