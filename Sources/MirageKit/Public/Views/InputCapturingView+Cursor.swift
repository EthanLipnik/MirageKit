//
//  InputCapturingView+Cursor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
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
    public func updateCursor(type: MirageCursorType, isVisible: Bool) {
        // Only update if something changed
        guard type != currentCursorType || isVisible != cursorIsVisible else { return }

        currentCursorType = type
        cursorIsVisible = isVisible

        // Invalidate the pointer interaction to force it to re-query the style
        // This is required because UIPointerInteraction only calls its delegate
        // when the pointer enters a region, not when the underlying state changes
        pointerInteraction?.invalidate()
    }

    func refreshCursorIfNeeded() {
        guard let cursorStore, let streamID else { return }
        guard let snapshot = cursorStore.snapshot(for: streamID) else { return }
        guard snapshot.sequence != cursorSequence else { return }
        cursorSequence = snapshot.sequence
        updateCursor(type: snapshot.cursorType, isVisible: snapshot.isVisible)
    }
}

// MARK: - UIPointerInteractionDelegate

extension InputCapturingView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Return appropriate pointer style based on host cursor state
        guard cursorIsVisible else {
            // Cursor is outside the host window, use default pointer
            return nil
        }
        return currentCursorType.pointerStyle(for: region)
    }
}
#endif
