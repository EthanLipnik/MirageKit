//
//  WindowSpaceManager+Placement.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

extension WindowSpaceManager {
    /// Resolves the visible display bounds used for window placement.
    func resolvePlacementDisplayBounds(
        displayID: CGDirectDisplayID,
        fallbackBounds: CGRect
    ) -> CGRect {
        let fallback = fallbackBounds.standardized
        let hasFallback = fallback.width > 0 && fallback.height > 0

        let displayBounds: CGRect = if let modeLogicalResolution = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID)?.logical {
            CGVirtualDisplayBridge.displayBounds(
                displayID,
                knownResolution: modeLogicalResolution
            )
        } else if hasFallback {
            CGVirtualDisplayBridge.displayBounds(
                displayID,
                knownResolution: fallback.size
            )
        } else {
            CGVirtualDisplayBridge.displayBounds(displayID)
        }

        var visibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
            displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            return hasFallback ? fallback : displayBounds
        }
        guard hasFallback else {
            return visibleBounds
        }

        let decision = placementBoundsSelectionDecision(
            cachedBounds: fallback,
            recomputedBounds: visibleBounds,
            displayBounds: displayBounds
        )
        MirageLogger.host(
            "event=placement_bounds_decision outcome=\(decision.outcome.rawValue) " +
                "display=\(displayID) cached=\(fallback) recomputed=\(visibleBounds) " +
                "resolved=\(decision.resolvedBounds) displayBounds=\(displayBounds)"
        )
        return decision.resolvedBounds
    }

    /// Verifies that a moved window reached the expected display space and frame.
    func verifyWindowPlacement(
        _ windowID: WindowID,
        expectedSpaceID: CGSSpaceID,
        displayBounds: CGRect,
        targetOrigin: CGPoint,
        axWindow: AXUIElement?,
        targetContentAspectRatio: CGFloat?
    ) -> Bool {
        let spaces = CGSWindowSpaceBridge.spaces(for: windowID)
        let expectedSpaceObserved = spaces.contains(expectedSpaceID)
        if !spaces.isEmpty, !expectedSpaceObserved {
            MirageLogger.debug(
                .host,
                "Window \(windowID) not yet in expected space \(expectedSpaceID); current spaces=\(spaces)"
            )
        }

        let frame = resolvedWindowFrame(windowID, axWindow: axWindow)
        guard let frame else {
            if !expectedSpaceObserved {
                MirageLogger.debug(
                    .host,
                    "verify_placement window=\(windowID) failed=space_mismatch " +
                        "expected_space=\(expectedSpaceID) current_spaces=\(spaces) frame=nil"
                )
            }
            return expectedSpaceObserved
        }

        let originTolerance: CGFloat = 16
        let originMatches = abs(frame.origin.x - targetOrigin.x) <= originTolerance &&
            abs(frame.origin.y - targetOrigin.y) <= originTolerance
        let expandedBounds = displayBounds.insetBy(dx: -24, dy: -24)
        let intersectsBounds = frame.intersects(expandedBounds)
        let expectedFrame = aspectFittedFrame(displayBounds, targetContentAspectRatio: targetContentAspectRatio)
        let minimumExpectedWidth = max(1, expectedFrame.width - 12)
        let minimumExpectedHeight = max(1, expectedFrame.height - 12)
        let maximumExpectedWidth = expectedFrame.width + 24
        let maximumExpectedHeight = expectedFrame.height + 24
        let sizeMatchesExpectation = frame.width >= minimumExpectedWidth &&
            frame.height >= minimumExpectedHeight &&
            frame.width <= maximumExpectedWidth &&
            frame.height <= maximumExpectedHeight

        if originMatches || intersectsBounds, sizeMatchesExpectation {
            return true
        }

        if expectedSpaceObserved {
            let localExpectedFrame = aspectFittedFrame(
                CGRect(origin: .zero, size: displayBounds.size),
                targetContentAspectRatio: targetContentAspectRatio
            )
            let localCoordinateBounds = localExpectedFrame.insetBy(dx: -24, dy: -24)
            let localOriginMatches = abs(frame.origin.x - localExpectedFrame.origin.x) <= 24 &&
                abs(frame.origin.y - localExpectedFrame.origin.y) <= 24
            let localSizeUpperBoundMatches = frame.width <= (localExpectedFrame.width + 24) &&
                frame.height <= (localExpectedFrame.height + 24)
            if localOriginMatches || frame.intersects(localCoordinateBounds),
               localSizeUpperBoundMatches,
               sizeMatchesExpectation {
                return true
            }
        }

        var failedChecks: [String] = []
        if !expectedSpaceObserved {
            failedChecks.append("space(expected=\(expectedSpaceID),actual=\(spaces))")
        }
        if !originMatches {
            failedChecks.append("origin(expected=\(targetOrigin),actual=\(frame.origin),dx=\(abs(frame.origin.x - targetOrigin.x)),dy=\(abs(frame.origin.y - targetOrigin.y)))")
        }
        if !intersectsBounds {
            failedChecks.append("bounds_intersection(frame=\(frame),display=\(displayBounds))")
        }
        if !sizeMatchesExpectation {
            failedChecks.append("size(actual=\(frame.width)x\(frame.height),expected=\(expectedFrame.width)x\(expectedFrame.height),range=\(minimumExpectedWidth)-\(maximumExpectedWidth)x\(minimumExpectedHeight)-\(maximumExpectedHeight))")
        }
        MirageLogger.debug(
            .host,
            "verify_placement window=\(windowID) failed_checks=[\(failedChecks.joined(separator: ", "))]"
        )

        return false
    }

    /// Fits a window into the visible display frame while preserving optional content aspect ratio.
    func fitWindowToVisibleFrame(
        _ windowID: WindowID,
        visibleFrame: CGRect,
        axWindow: AXUIElement?,
        targetContentAspectRatio: CGFloat?
    )
    async {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return }
        guard let axWindow = axWindow ?? resolveAXWindow(for: windowID) else { return }

        let fitFrame = aspectFittedFrame(
            visibleFrame,
            targetContentAspectRatio: targetContentAspectRatio
        )
        let targetSize = CGSize(width: fitFrame.width, height: fitFrame.height)
        let targetOrigin = fitFrame.origin
        var mutableInitialPoint = targetOrigin
        if let positionValue = AXValueCreate(.cgPoint, &mutableInitialPoint) {
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        }
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin) {
            MirageLogger.debug(.host, "Failed to pre-place window \(windowID) at \(targetOrigin)")
        }

        if isAXAttributeSettable(axWindow, attribute: kAXSizeAttribute as CFString) {
            _ = await resizeWindowViaAccessibility(windowID, to: targetSize, axElement: axWindow)
        }

        var mutablePoint = targetOrigin
        if let positionValue = AXValueCreate(.cgPoint, &mutablePoint) {
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        }
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin) {
            MirageLogger.debug(.host, "Failed to place window \(windowID) at \(targetOrigin)")
        }

        let resolvedFrame = resolvedWindowFrame(windowID, axWindow: axWindow) ?? CGRect(origin: targetOrigin, size: targetSize)
        let coverageRect = resolvedFrame.intersection(visibleFrame)
        let coverageHeight = max(0, coverageRect.height)
        let coverageWidth = max(0, coverageRect.width)
        let minimumCoverageHeight = max(1, fitFrame.height - 6)
        let minimumCoverageWidth = max(1, fitFrame.width - 6)
        if coverageHeight < minimumCoverageHeight || coverageWidth < minimumCoverageWidth {
            MirageLogger.debug(
                .host,
                "Window \(windowID) best-fit content coverage within visible frame: \(Int(coverageWidth))x\(Int(coverageHeight))"
            )
        }
    }

    /// Returns a centered aspect-fit frame inside `frame` when an aspect ratio is requested.
    func aspectFittedFrame(
        _ frame: CGRect,
        targetContentAspectRatio: CGFloat?
    ) -> CGRect {
        guard let requestedAspect = targetContentAspectRatio,
              requestedAspect.isFinite,
              requestedAspect > 0,
              frame.width > 0,
              frame.height > 0 else {
            return frame
        }

        let containerAspect = frame.width / frame.height
        guard abs(containerAspect - requestedAspect) > 0.0001 else { return frame }

        var fittedWidth = frame.width
        var fittedHeight = frame.height

        if containerAspect > requestedAspect {
            fittedWidth = floor(frame.height * requestedAspect)
        } else {
            fittedHeight = floor(frame.width / requestedAspect)
        }

        fittedWidth = max(1, fittedWidth)
        fittedHeight = max(1, fittedHeight)

        let originX = frame.minX + (frame.width - fittedWidth) * 0.5
        let originY = frame.minY + (frame.height - fittedHeight) * 0.5

        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }
}

#endif
