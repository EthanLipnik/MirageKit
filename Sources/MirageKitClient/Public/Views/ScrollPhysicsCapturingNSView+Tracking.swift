//
//  ScrollPhysicsCapturingNSView+Tracking.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    /// Normalize mouse location to 0-1 range within view bounds
    func normalizedLocation(from event: NSEvent) -> CGPoint {
        let locationInView = convert(event.locationInWindow, from: nil)
        let contentRect = resolvedDesktopPresentationContentRect
        guard contentRect.width > 0, contentRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return Self.normalizedLocation(locationInView, in: bounds, contentRect: contentRect)
    }

    /// Enable tracking area for mouse moved events
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        guard isInputProcessingActive else { return }

        // Add new tracking area for the entire view
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard shouldMirrorHostCursorAppearanceToSystemCursor, mirroredSystemCursorVisible else { return }
        addCursorRect(resolvedDesktopPresentationContentRect, cursor: mirroredSystemCursorType.nsCursor)
    }
}
#endif
