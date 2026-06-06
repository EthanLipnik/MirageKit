//
//  AppStreamInputOverlayRoutingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing
import MirageCore
import MirageInput
import MirageMedia

@Suite("App Stream Input Overlay Routing")
struct AppStreamInputOverlayRoutingTests {
    @Test("Pointer events hit-test overlays and rewrite normalized location")
    func pointerEventsHitTestOverlaysAndRewriteNormalizedLocation() throws {
        let parentWindow = makeWindow(id: 1)
        let overlayWindow = makeWindow(id: 2)
        let result = AppStreamInputOverlayRouting.route(
            event: .mouseMoved(MirageInput.MirageMouseEvent(location: CGPoint(x: 0.5, y: 0.5))),
            parentWindow: parentWindow,
            regions: [
                AppStreamInputOverlayRegion(
                    window: overlayWindow,
                    normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                    zIndex: 1,
                    receivesKeyboardFocus: false
                ),
            ]
        )

        #expect(result.window.id == overlayWindow.id)
        guard case let .mouseMoved(event) = result.event else {
            Issue.record("Expected mouseMoved event")
            return
        }
        #expect(event.location == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("Overlapping overlay hit tests use frontmost z index")
    func overlappingOverlayHitTestsUseFrontmostZIndex() {
        let parentWindow = makeWindow(id: 1)
        let backOverlay = makeWindow(id: 2)
        let frontOverlay = makeWindow(id: 3)
        let result = AppStreamInputOverlayRouting.route(
            event: .mouseDown(MirageInput.MirageMouseEvent(location: CGPoint(x: 0.4, y: 0.4))),
            parentWindow: parentWindow,
            regions: [
                AppStreamInputOverlayRegion(
                    window: backOverlay,
                    normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
                    zIndex: 1,
                    receivesKeyboardFocus: false
                ),
                AppStreamInputOverlayRegion(
                    window: frontOverlay,
                    normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
                    zIndex: 2,
                    receivesKeyboardFocus: false
                ),
            ]
        )

        #expect(result.window.id == frontOverlay.id)
    }

    @Test("Key and focus events route to active modal overlay")
    func keyAndFocusEventsRouteToActiveModalOverlay() {
        let parentWindow = makeWindow(id: 1)
        let modalOverlay = makeWindow(id: 2)
        let keyResult = AppStreamInputOverlayRouting.route(
            event: .keyDown(MirageInput.MirageKeyEvent(keyCode: 36)),
            parentWindow: parentWindow,
            regions: [
                AppStreamInputOverlayRegion(
                    window: modalOverlay,
                    normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    zIndex: 1,
                    receivesKeyboardFocus: true
                ),
            ]
        )
        let focusResult = AppStreamInputOverlayRouting.route(
            event: .windowFocus,
            parentWindow: parentWindow,
            regions: [
                AppStreamInputOverlayRegion(
                    window: modalOverlay,
                    normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    zIndex: 1,
                    receivesKeyboardFocus: true
                ),
            ]
        )

        #expect(keyResult.window.id == modalOverlay.id)
        #expect(focusResult.window.id == modalOverlay.id)
    }

    @Test("Events outside overlays fall back to parent window")
    func eventsOutsideOverlaysFallBackToParentWindow() {
        let parentWindow = makeWindow(id: 1)
        let overlayWindow = makeWindow(id: 2)
        let result = AppStreamInputOverlayRouting.route(
            event: .scrollWheel(MirageInput.MirageScrollEvent(deltaX: 0, deltaY: -12, location: CGPoint(x: 0.9, y: 0.9))),
            parentWindow: parentWindow,
            regions: [
                AppStreamInputOverlayRegion(
                    window: overlayWindow,
                    normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    zIndex: 1,
                    receivesKeyboardFocus: false
                ),
            ]
        )

        #expect(result.window.id == parentWindow.id)
    }

    private func makeWindow(id: WindowID) -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: id,
            title: "Window \(id)",
            application: MirageMedia.MirageApplication(
                id: 100,
                bundleIdentifier: "com.example.app",
                name: "Example"
            ),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            windowLayer: 0
        )
    }
}
#endif
