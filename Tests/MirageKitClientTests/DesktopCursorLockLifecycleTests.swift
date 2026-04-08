//
//  DesktopCursorLockLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitClient
import AppKit
import Testing

#if os(macOS)
@MainActor
@Suite("Desktop Cursor Lock Lifecycle")
struct DesktopCursorLockLifecycleTests {
    @Test("Disabling cursor lock restores cursor association and visibility")
    func disablingCursorLockRestoresAssociationAndVisibility() {
        let restoreLocation = CGPoint(x: 1340, y: 720)
        var associations: [Bool] = []
        var warps: [CGPoint] = []
        var hideCount = 0
        var unhideCount = 0

        withCursorSystemHooks(
            .init(
                mouseLocation: { restoreLocation },
                setAssociationEnabled: { associations.append($0) },
                warpCursor: { warps.append($0) },
                hideCursor: { hideCount += 1 },
                unhideCursor: { unhideCount += 1 }
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                view.cursorLockEnabled = true
                view.cursorLockEnabled = false
            }
        }

        #expect(associations == [false, true])
        #expect(hideCount == 1)
        #expect(unhideCount == 1)
        #expect(warps.last == restoreLocation)
    }

    @Test("Disabling input restores the pre-lock cursor position")
    func disablingInputRestoresPreLockCursorPosition() {
        let restoreLocation = CGPoint(x: 980, y: 410)
        var associations: [Bool] = []
        var warps: [CGPoint] = []

        withCursorSystemHooks(
            .init(
                mouseLocation: { restoreLocation },
                setAssociationEnabled: { associations.append($0) },
                warpCursor: { warps.append($0) },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                view.cursorLockEnabled = true
                view.inputEnabled = false
            }
        }

        #expect(associations == [false, true])
        #expect(warps.last == restoreLocation)
    }

    @Test("Leaving real Mac cursor mode re-evaluates system cursor visibility")
    func leavingRealMacCursorModeReevaluatesSystemCursorVisibility() {
        let streamID: StreamID = 12
        let cursorStore = MirageClientCursorStore()
        let cursorPositionStore = MirageClientCursorPositionStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .arrow, isVisible: false)
        cursorPositionStore.updatePosition(streamID: streamID, position: CGPoint(x: 0.5, y: 0.5), isVisible: false)

        var hideCount = 0
        var unhideCount = 0

        withCursorSystemHooks(
            .init(
                mouseLocation: { .zero },
                setAssociationEnabled: { _ in },
                warpCursor: { _ in },
                hideCursor: { hideCount += 1 },
                unhideCursor: { unhideCount += 1 }
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                view.streamID = streamID
                view.cursorStore = cursorStore
                view.cursorPositionStore = cursorPositionStore

                view.syntheticCursorEnabled = false
                #expect(hideCount == 1)

                view.syntheticCursorEnabled = true
            }
        }

        #expect(unhideCount == 1)
    }

    private func makeMountedView() -> (NSWindow, ScrollPhysicsCapturingNSView) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let view = ScrollPhysicsCapturingNSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        window.contentView = view
        return (window, view)
    }

    private func withCursorSystemHooks(
        _ hooks: ScrollPhysicsCapturingNSView.CursorSystemHooks,
        perform body: () -> Void
    ) {
        let previousHooks = ScrollPhysicsCapturingNSView.cursorSystemHooks
        ScrollPhysicsCapturingNSView.cursorSystemHooks = hooks
        defer {
            ScrollPhysicsCapturingNSView.cursorSystemHooks = previousHooks
        }
        body()
    }
}
#endif
