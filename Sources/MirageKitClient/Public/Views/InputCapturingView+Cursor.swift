//
//  InputCapturingView+Cursor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    var cursorHiddenByLocalInput: Bool {
        cursorHiddenForTyping || cursorHiddenForDirectTouch
    }

    func hideCursorForTypingUntilPointerMovement() {
        guard !cursorHiddenForTyping else { return }
        cursorHiddenForTyping = true
        invalidatePointerInteraction(reason: "hideForTyping")
        updateLockedCursorViewVisibility()
    }

    func hideCursorForDirectTouchIfNeeded() {
        guard directTouchInputMode == .normal else { return }
        guard !cursorHiddenForDirectTouch else { return }
        cursorHiddenForDirectTouch = true
        invalidatePointerInteraction(reason: "hideForDirectTouch")
        updateLockedCursorViewVisibility()
    }

    func clearDirectTouchCursorSuppression(reason: String) {
        guard cursorHiddenForDirectTouch else { return }
        cursorHiddenForDirectTouch = false
        invalidatePointerInteraction(reason: reason)
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func revealCursorAfterPointerMovement() {
        guard cursorHiddenForTyping else { return }
        cursorHiddenForTyping = false
        refreshCursorUpdates(force: true)
        invalidatePointerInteraction(reason: "revealAfterPointerMovement")
        updateLockedCursorViewVisibility()
    }

    func revealCursorAfterCursorDrivenMovement() {
        guard cursorHiddenForTyping || cursorHiddenForDirectTouch else { return }
        cursorHiddenForTyping = false
        cursorHiddenForDirectTouch = false
        refreshCursorUpdates(force: true)
        invalidatePointerInteraction(reason: "revealAfterCursorDrivenMovement")
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
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
    public func updateCursor(type: MirageWire.MirageCursorType, isVisible: Bool, force: Bool = false) {
        let effectiveIsVisible = effectiveCursorVisibility(hostVisibility: isVisible)
        // Only update if something changed
        let typeChanged = type != currentCursorType
        guard force || typeChanged || effectiveIsVisible != cursorIsVisible else { return }

        currentCursorType = type
        cursorIsVisible = effectiveIsVisible

        if typeChanged { updateCursorImage() }
        updateVirtualCursorViewPosition()
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()

        // Invalidate the pointer interaction to force it to re-query the style
        // This is required because UIPointerInteraction only calls its delegate
        // when the pointer enters a region, not when the underlying state changes
        invalidatePointerInteraction(reason: "cursorUpdate")
    }

    func invalidatePointerInteraction(reason: String) {
        let invalidateStart = CFAbsoluteTimeGetCurrent()
        pointerInteraction?.invalidate()
        MirageCursorLatencyProbe.pointerInteractionInvalidate(
            reason: reason,
            streamID: streamID,
            cursorType: currentCursorType,
            durationMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: invalidateStart)
        )
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
        _ = refreshLockedCursorIfNeeded(force: force)
    }

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
    public func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
        // Return appropriate pointer style based on host cursor state
        if hideSystemCursor || cursorLockEnabled || cursorHiddenByLocalInput {
            return .hidden()
        }
        let shouldStyleVisibleSystemPointer = !syntheticCursorEnabled && !hideSystemCursor
        guard syntheticCursorEnabled || shouldStyleVisibleSystemPointer else { return nil }
        guard cursorIsVisible else {
            // Cursor is outside the host window, use default pointer
            return nil
        }
        if currentCursorType == .arrow {
            return nil
        }
        return currentCursorType.pointerStyle()
    }
}

extension InputCapturingView: MirageCursorUpdateHandling {
    func refreshCursorUpdates(force: Bool) {
        refreshCursorIfNeeded(force: force)
        let updatedFromPosition = refreshLockedCursorIfNeeded(force: force)
        if cursorLockEnabled, !updatedFromPosition,
           let cursorStore, let streamID,
           let snapshot = cursorStore.snapshot(for: streamID) {
            setLockedCursorVisible(effectiveCursorVisibility(hostVisibility: snapshot.isVisible))
        }
    }
}
#endif
