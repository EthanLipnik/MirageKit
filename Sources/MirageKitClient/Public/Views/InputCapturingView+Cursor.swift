//
//  InputCapturingView+Cursor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func hideCursorForTypingUntilPointerMovement() {
        guard !cursorHiddenForTyping else { return }
        cursorHiddenForTyping = true
        pointerInteraction?.invalidate()
        updateLockedCursorViewVisibility()
    }

    func revealCursorAfterPointerMovement() {
        guard cursorHiddenForTyping else { return }
        cursorHiddenForTyping = false
        refreshCursorUpdates(force: true)
        pointerInteraction?.invalidate()
        updateLockedCursorViewVisibility()
    }

    func setupPointerInteraction() {
        // Add pointer interaction for cursor customization
        let interaction = UIPointerInteraction(delegate: self)
        pointerInteraction = interaction
        addInteraction(interaction)
    }

    // MARK: - Cursor Updates

    /// Update cursor appearance based on host cursor state
    /// - Parameters:
    ///   - type: The cursor type from the host
    ///   - isVisible: Whether the cursor is within the host window bounds
    public func updateCursor(type: MirageCursorType, isVisible: Bool, force: Bool = false) {
        // Only update if something changed
        let typeChanged = type != currentCursorType
        guard force || typeChanged || isVisible != cursorIsVisible else { return }

        currentCursorType = type
        cursorIsVisible = isVisible

        if typeChanged { updateCursorImage() }
        updateVirtualCursorViewPosition()
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()

        // Invalidate the pointer interaction to force it to re-query the style
        // This is required because UIPointerInteraction only calls its delegate
        // when the pointer enters a region, not when the underlying state changes
        pointerInteraction?.invalidate()
    }

    func refreshCursorIfNeeded(force: Bool = false) {
        guard let cursorStore, let streamID else { return }
        let now = CACurrentMediaTime()
        if !force, now - lastCursorRefreshTime < cursorRefreshInterval { return }
        lastCursorRefreshTime = now
        guard let snapshot = cursorStore.snapshot(for: streamID) else { return }
        guard force || snapshot.sequence != cursorSequence else { return }
        cursorSequence = snapshot.sequence
        updateCursor(type: snapshot.cursorType, isVisible: snapshot.isVisible, force: force)
        refreshLockedCursorIfNeeded(force: force)
    }

    @discardableResult
    func refreshLockedCursorIfNeeded(force: Bool = false) -> Bool {
        guard cursorLockEnabled, let cursorPositionStore, let streamID else { return false }
        let now = CACurrentMediaTime()
        if !force, now - lastLockedCursorRefreshTime < lockedCursorRefreshInterval { return false }
        lastLockedCursorRefreshTime = now
        guard let snapshot = cursorPositionStore.snapshot(for: streamID) else { return false }
        guard force || snapshot.sequence != lockedCursorSequence else { return false }
        lockedCursorSequence = snapshot.sequence
        applyLockedCursorHostUpdate(position: snapshot.position, isVisible: snapshot.isVisible)
        return true
    }
}

// MARK: - UIPointerInteractionDelegate

extension InputCapturingView: UIPointerInteractionDelegate {
    public func pointerInteraction(_: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Return appropriate pointer style based on host cursor state
        if hideSystemCursor || cursorLockEnabled || cursorHiddenForTyping {
            return .hidden()
        }
        guard syntheticCursorEnabled else { return nil }
        guard cursorIsVisible else {
            // Cursor is outside the host window, use default pointer
            return nil
        }
        if currentCursorType == .arrow {
            return nil
        }
        return currentCursorType.pointerStyle(for: region)
    }
}

extension InputCapturingView: MirageCursorUpdateHandling {
    func refreshCursorUpdates(force: Bool) {
        refreshCursorIfNeeded(force: force)
        let updatedFromPosition = refreshLockedCursorIfNeeded(force: force)
        if cursorLockEnabled, !updatedFromPosition,
           let cursorStore, let streamID,
           let snapshot = cursorStore.snapshot(for: streamID) {
            setLockedCursorVisible(snapshot.isVisible)
        }
    }
}
#endif
