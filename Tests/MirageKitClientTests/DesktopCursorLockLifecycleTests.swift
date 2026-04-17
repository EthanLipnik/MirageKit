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
        #expect(
            warps.last ==
                ScrollPhysicsCapturingNSView.globalDisplayCursorPosition(
                    fromCocoaScreenPosition: restoreLocation,
                    globalFrameMaxY: ScrollPhysicsCapturingNSView.globalDisplayFrameMaxY()
                )
        )
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
        #expect(
            warps.last ==
                ScrollPhysicsCapturingNSView.globalDisplayCursorPosition(
                    fromCocoaScreenPosition: restoreLocation,
                    globalFrameMaxY: ScrollPhysicsCapturingNSView.globalDisplayFrameMaxY()
                )
        )
    }

    @Test("Unlocked real Mac cursor mode does not hide or warp the system cursor")
    func unlockedRealMacCursorModeDoesNotHideOrWarpSystemCursor() {
        let streamID: StreamID = 12
        let cursorStore = MirageClientCursorStore()
        let cursorPositionStore = MirageClientCursorPositionStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .arrow, isVisible: false)
        cursorPositionStore.updatePosition(streamID: streamID, position: CGPoint(x: 0.5, y: 0.5), isVisible: false)

        var warps: [CGPoint] = []
        var hideCount = 0
        var unhideCount = 0

        withCursorSystemHooks(
            .init(
                mouseLocation: { .zero },
                setAssociationEnabled: { _ in },
                warpCursor: { warps.append($0) },
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
                view.refreshCursorUpdates(force: true)
                view.layoutSubtreeIfNeeded()

                view.syntheticCursorEnabled = true
            }
        }

        #expect(warps.isEmpty)
        #expect(hideCount == 0)
        #expect(unhideCount == 0)
    }

    @Test("Unlocked real Mac cursor mode applies host cursor type without warping")
    func unlockedRealMacCursorModeAppliesHostCursorTypeWithoutWarping() {
        let streamID: StreamID = 13
        let cursorStore = MirageClientCursorStore()
        let cursorPositionStore = MirageClientCursorPositionStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .closedHand, isVisible: true)
        cursorPositionStore.updatePosition(streamID: streamID, position: CGPoint(x: 0.2, y: 0.8), isVisible: true)

        var appliedCursorTypes: [MirageCursorType] = []
        var mouseLocation = CGPoint.zero
        var warps: [CGPoint] = []

        withCursorSystemHooks(
            .init(
                mouseLocation: { mouseLocation },
                setAssociationEnabled: { _ in },
                warpCursor: { warps.append($0) },
                setCursor: { cursor in
                    if let type = MirageCursorType(from: cursor) {
                        appliedCursorTypes.append(type)
                    }
                },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                mouseLocation = window.convertPoint(toScreen: CGPoint(x: 240, y: 180))
                view.streamID = streamID
                view.cursorStore = cursorStore
                view.cursorPositionStore = cursorPositionStore
                view.syntheticCursorEnabled = false
                view.refreshCursorUpdates(force: true)
                view.layoutSubtreeIfNeeded()
            }
        }

        #expect(appliedCursorTypes.contains(.closedHand))
        #expect(warps.isEmpty)
    }

    @Test("Mirage cursor mode applies host cursor type updates to the macOS cursor")
    func mirageCursorModeAppliesHostCursorTypeUpdates() {
        let streamID: StreamID = 14
        let cursorStore = MirageClientCursorStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .closedHand, isVisible: true)

        var appliedCursorTypes: [MirageCursorType] = []
        var mouseLocation = CGPoint.zero

        withCursorSystemHooks(
            .init(
                mouseLocation: { mouseLocation },
                setAssociationEnabled: { _ in },
                warpCursor: { _ in },
                setCursor: { cursor in
                    if let type = MirageCursorType(from: cursor) {
                        appliedCursorTypes.append(type)
                    }
                },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                mouseLocation = window.convertPoint(toScreen: CGPoint(x: 240, y: 180))
                view.streamID = streamID
                view.cursorStore = cursorStore
                view.syntheticCursorEnabled = true
                view.refreshCursorUpdates(force: true)
            }
        }

        #expect(appliedCursorTypes.contains(.closedHand))
    }

    @Test("Mirage cursor mode shows the synthetic cursor when unlocked")
    func mirageCursorModeShowsSyntheticCursorWhenUnlocked() throws {
        let streamID: StreamID = 15
        let cursorStore = MirageClientCursorStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .arrow, isVisible: true)

        let localPoint = CGPoint(x: 240, y: 180)
        var mouseLocation = CGPoint.zero

        withCursorSystemHooks(
            .init(
                mouseLocation: { mouseLocation },
                setAssociationEnabled: { _ in },
                warpCursor: { _ in },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                let windowPoint = view.convert(localPoint, to: nil)
                mouseLocation = window.convertPoint(toScreen: windowPoint)

                view.hideSystemCursor = true
                view.streamID = streamID
                view.cursorStore = cursorStore
                view.syntheticCursorEnabled = true
                view.refreshCursorUpdates(force: true)
                view.layoutSubtreeIfNeeded()

                let cursorView = view.contentView.subviews.first as? NSImageView
                let cursor = NSCursor.arrow
                let expectedOrigin = CGPoint(
                    x: localPoint.x - cursor.hotSpot.x,
                    y: localPoint.y - (cursor.image.size.height - cursor.hotSpot.y)
                )

                #expect(cursorView != nil)
                #expect(cursorView?.isHidden == false)
                #expect(abs((cursorView?.frame.origin.x ?? .zero) - expectedOrigin.x) < 0.001)
                #expect(abs((cursorView?.frame.origin.y ?? .zero) - expectedOrigin.y) < 0.001)
            }
        }
    }

    @Test("Real Mac cursor lock keeps the system cursor visible")
    func realMacCursorLockKeepsSystemCursorVisible() {
        var hideCount = 0

        withCursorSystemHooks(
            .init(
                mouseLocation: { .zero },
                setAssociationEnabled: { _ in },
                warpCursor: { _ in },
                hideCursor: { hideCount += 1 },
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                view.syntheticCursorEnabled = false
                view.cursorLockEnabled = true
            }
        }

        #expect(hideCount == 0)
    }

    @Test("Real Mac cursor lock applies host cursor updates to the macOS cursor")
    func realMacCursorLockAppliesHostCursorUpdates() {
        let streamID: StreamID = 16
        let cursorStore = MirageClientCursorStore()
        cursorStore.updateCursor(streamID: streamID, cursorType: .closedHand, isVisible: true)

        var appliedCursorTypes: [MirageCursorType] = []
        var mouseLocation = CGPoint.zero

        withCursorSystemHooks(
            .init(
                mouseLocation: { mouseLocation },
                setAssociationEnabled: { _ in },
                warpCursor: { _ in },
                setCursor: { cursor in
                    if let type = MirageCursorType(from: cursor) {
                        appliedCursorTypes.append(type)
                    }
                },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                mouseLocation = window.convertPoint(toScreen: CGPoint(x: 240, y: 180))
                view.cursorLockEnabled = true
                view.cursorStore = cursorStore
                view.syntheticCursorEnabled = false
                view.streamID = streamID
            }
        }

        #expect(appliedCursorTypes.contains(.closedHand))
    }

    @Test("Real Mac cursor lock warps using global display coordinates")
    func realMacCursorLockWarpsUsingGlobalDisplayCoordinates() {
        var warps: [CGPoint] = []

        withCursorSystemHooks(
            .init(
                mouseLocation: { .zero },
                setAssociationEnabled: { _ in },
                warpCursor: { warps.append($0) },
                hideCursor: {},
                unhideCursor: {}
            )
        ) {
            let (window, view) = makeMountedView()
            withExtendedLifetime(window) {
                view.syntheticCursorEnabled = false
                let localPoint = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                let windowPoint = view.convert(localPoint, to: nil)
                let cocoaScreenPoint = window.convertPoint(toScreen: windowPoint)
                let expectedWarp = ScrollPhysicsCapturingNSView.globalDisplayCursorPosition(
                    fromCocoaScreenPosition: cocoaScreenPoint,
                    globalFrameMaxY: ScrollPhysicsCapturingNSView.globalDisplayFrameMaxY()
                )

                view.cursorLockEnabled = true

                #expect(warps.last == expectedWarp)
            }
        }
    }

    @Test("Global display cursor conversion flips Cocoa Y")
    func globalDisplayCursorConversionFlipsCocoaY() {
        let converted = ScrollPhysicsCapturingNSView.globalDisplayCursorPosition(
            fromCocoaScreenPosition: CGPoint(x: 320, y: 140),
            globalFrameMaxY: 900
        )

        #expect(converted == CGPoint(x: 320, y: 760))
    }

    @Test("Locked cursor delta keeps AppKit negative-up Y motion aligned with stream space")
    func lockedCursorDeltaKeepsAppKitNegativeUpYMotionAlignedWithStreamSpace() {
        let updated = LockedCursorPositionResolver.applyRelativeDelta(
            currentPosition: CGPoint(x: 0.5, y: 0.5),
            deltaX: 120,
            deltaY: -120,
            normalizationSize: CGSize(width: 1200, height: 1200),
            allowsExtendedBounds: false
        )

        #expect(updated == CGPoint(x: 0.6, y: 0.4))
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
