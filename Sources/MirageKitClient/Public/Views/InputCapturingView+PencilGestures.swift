//
//  InputCapturingView+PencilGestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    /// Resolves the location used for a Pencil gesture that synthesizes a secondary click.
    func resolvedPencilSecondaryClickLocation(hoverLocation: CGPoint?) -> CGPoint {
        if let hoverLocation {
            let location = normalizedLocation(hoverLocation)
            if cursorLockEnabled {
                lockedCursorPosition = location
                noteLockedCursorLocalInput()
                setLockedCursorVisible(true)
                updateLockedCursorViewPosition()
            }
            if usesVisibleVirtualCursor {
                updateVirtualCursorPosition(location, updateVisibility: true)
            }
            lastCursorPosition = location
            return location
        }

        if cursorLockEnabled { return lockedCursorActionPosition() }
        if let lastCursorPosition { return lastCursorPosition }
        if usesVirtualTrackpad { return virtualCursorPosition }
        return CGPoint(x: 0.5, y: 0.5)
    }

    /// Emits a right-click pair for a Pencil gesture at a normalized stream location.
    func sendPencilSecondaryClick(at location: CGPoint) {
        let now = CACurrentMediaTime()
        let clickCount = nextSecondaryClickCount(at: location, timestamp: now)
        currentRightClickCount = clickCount

        let modifiers = currentPencilModifiers()
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: clickCount,
            modifiers: modifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
        commitSecondaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    /// Runs the configured action for a Pencil hardware gesture.
    func performPencilGesture(
        _ kind: MiragePencilGestureKind,
        hoverLocation: CGPoint?
    ) {
        let action = pencilGestureConfiguration.action(for: kind)
        performPencilGestureAction(action, hoverLocation: hoverLocation)
    }

    /// Applies a resolved Pencil gesture action.
    func performPencilGestureAction(
        _ action: MiragePencilGestureAction,
        hoverLocation: CGPoint?
    ) {
        switch action {
        case .none:
            return
        case .secondaryClick:
            let location = resolvedPencilSecondaryClickLocation(hoverLocation: hoverLocation)
            sendPencilSecondaryClick(at: location)
        case .toggleDictation,
             .remoteShortcut:
            onPencilGestureAction?(action)
        }
    }
}

#if os(iOS)
extension InputCapturingView: UIPencilInteractionDelegate {
    /// Handles the Apple Pencil double-tap interaction.
    public func pencilInteraction(
        _: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        performPencilGesture(.doubleTap, hoverLocation: tap.hoverPose?.location)
    }

    /// Handles the Apple Pencil squeeze interaction when the gesture ends.
    public func pencilInteraction(
        _: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .ended else { return }
        performPencilGesture(.squeeze, hoverLocation: squeeze.hoverPose?.location)
    }
}
#endif

#endif
