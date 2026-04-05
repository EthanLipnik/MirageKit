//
//  HostCursorPositionUpdatePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

#if os(macOS)
@MainActor
@Suite("Host Cursor Position Update Policy")
struct HostCursorPositionUpdatePolicyTests {
    @Test("Secondary desktop streams always publish cursor positions")
    func secondaryDesktopStreamPublishesCursorPositions() {
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 42,
            desktopStreamID: 42,
            desktopStreamMode: .secondary,
            desktopCursorPresentation: .clientCursor
        )

        #expect(shouldSend)
    }

    @Test("Host cursor desktop streams publish cursor positions even when mirrored")
    func hostCursorMirroredDesktopPublishesCursorPositions() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: false
        )
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 7,
            desktopStreamID: 7,
            desktopStreamMode: .mirrored,
            desktopCursorPresentation: presentation
        )

        #expect(shouldSend)
    }

    @Test("Mirrored desktop with synthetic cursor skips cursor positions")
    func mirroredDesktopWithSyntheticCursorSkipsCursorPositions() {
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 7,
            desktopStreamID: 7,
            desktopStreamMode: .mirrored,
            desktopCursorPresentation: .clientCursor
        )

        #expect(shouldSend == false)
    }

    @Test("Secondary desktop cursor positions preserve off-display travel")
    func secondaryDesktopCursorPositionPreservesOffDisplayTravel() {
        let position = MirageHostService.resolvedClientCursorPosition(
            CGPoint(x: 1.2, y: -0.1),
            desktopStreamMode: .secondary
        )

        #expect(position == CGPoint(x: 1.2, y: -0.1))
    }

    @Test("Mirrored desktop cursor positions clamp into stream bounds")
    func mirroredDesktopCursorPositionClampsIntoBounds() {
        let position = MirageHostService.resolvedClientCursorPosition(
            CGPoint(x: 1.2, y: -0.1),
            desktopStreamMode: .mirrored
        )

        #expect(position == CGPoint(x: 1, y: 0))
    }

    @Test("Desktop pointer warps stay enabled for move and drag events")
    func desktopMoveAndDragEventsRequireWarp() {
        #expect(MirageHostInputController.shouldWarpDesktopPointerEvent(.mouseMoved))
        #expect(MirageHostInputController.shouldWarpDesktopPointerEvent(.leftMouseDragged))
        #expect(MirageHostInputController.shouldWarpDesktopPointerEvent(.rightMouseDragged))
        #expect(MirageHostInputController.shouldWarpDesktopPointerEvent(.otherMouseDragged))
    }

    @Test("Desktop pointer warp is skipped for release, scroll, and key events")
    func desktopReleaseScrollAndKeyEventsSkipWarp() {
        #expect(!MirageHostInputController.shouldWarpDesktopPointerEvent(.rightMouseUp))
        #expect(!MirageHostInputController.shouldWarpDesktopPointerEvent(.scrollWheel))
        #expect(!MirageHostInputController.shouldWarpDesktopPointerEvent(.keyDown))
    }

    @Test("Desktop right-click events reuse the current host cursor position")
    func desktopRightClickUsesCurrentHostCursorPosition() {
        let requestedPoint = CGPoint(x: 300, y: 200)
        let currentCursorPosition = CGPoint(x: -120, y: 880)

        let downPoint = MirageHostInputController.resolvedDesktopPointerEventPoint(
            .rightMouseDown,
            requestedPoint: requestedPoint,
            currentCursorPosition: currentCursorPosition
        )
        let upPoint = MirageHostInputController.resolvedDesktopPointerEventPoint(
            .rightMouseUp,
            requestedPoint: requestedPoint,
            currentCursorPosition: currentCursorPosition
        )

        #expect(downPoint == currentCursorPosition)
        #expect(upPoint == currentCursorPosition)
    }

    @Test("Desktop left-click events still use the incoming event location")
    func desktopLeftClickUsesRequestedPoint() {
        let requestedPoint = CGPoint(x: 300, y: 200)
        let currentCursorPosition = CGPoint(x: -120, y: 880)

        let downPoint = MirageHostInputController.resolvedDesktopPointerEventPoint(
            .leftMouseDown,
            requestedPoint: requestedPoint,
            currentCursorPosition: currentCursorPosition
        )

        #expect(downPoint == requestedPoint)
    }
}
#endif
