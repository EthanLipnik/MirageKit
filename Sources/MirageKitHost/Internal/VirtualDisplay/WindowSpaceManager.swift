//
//  WindowSpaceManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

/// Manages window movement between displays/spaces for Mirage streams
/// Handles moving windows to virtual displays and restoring them on stream end
actor WindowSpaceManager {
    // MARK: - Singleton

    static let shared = WindowSpaceManager()

    private init() {}

    // MARK: - Types

    struct TrafficLightVisibilitySnapshot: Sendable {
        let closeHidden: Bool?
        let minimizeHidden: Bool?
        let zoomHidden: Bool?

        var hasRecordedState: Bool {
            closeHidden != nil || minimizeHidden != nil || zoomHidden != nil
        }
    }

    struct WindowBindingOwner: Sendable {
        let streamID: StreamID
        let windowID: WindowID
        let displayID: CGDirectDisplayID
        let generation: UInt64
    }

    /// Saved state for restoring a window to its original position
    struct SavedWindowState: Sendable {
        let windowID: WindowID
        let originalFrame: CGRect
        let originalSpaceIDs: [CGSSpaceID]
        let trafficLightVisibilitySnapshot: TrafficLightVisibilitySnapshot?
        let owner: WindowBindingOwner?
        let savedAt: Date
    }

    /// Error types for window operations
    enum WindowSpaceError: Error, LocalizedError {
        case windowNotFound(WindowID)
        case noOriginalState(WindowID)
        case moveFailed(WindowID, String)
        case ownerConflict(WindowID, existingStreamID: StreamID, requestedStreamID: StreamID)
        case ownerMismatch(WindowID, expectedStreamID: StreamID, actualStreamID: StreamID)

        var errorDescription: String? {
            switch self {
            case let .windowNotFound(id):
                "Window \(id) not found"
            case let .noOriginalState(id):
                "No saved state for window \(id)"
            case let .moveFailed(id, reason):
                "Failed to move window \(id): \(reason)"
            case let .ownerConflict(id, existingStreamID, requestedStreamID):
                "Window \(id) already owned by stream \(existingStreamID); requested stream \(requestedStreamID)"
            case let .ownerMismatch(id, expectedStreamID, actualStreamID):
                "Window \(id) restore owner mismatch expected stream \(expectedStreamID), actual stream \(actualStreamID)"
            }
        }
    }

    enum RestoreOwnerValidationResult: Sendable, Equatable {
        case allowed
        case ownerMismatch(expectedStreamID: StreamID, actualStreamID: StreamID)
    }

    nonisolated static func validateRestoreOwner(
        expectedOwner: WindowBindingOwner?,
        savedOwner: WindowBindingOwner?
    ) -> RestoreOwnerValidationResult {
        guard let expectedOwner else { return .allowed }
        guard let savedOwner else {
            return .ownerMismatch(
                expectedStreamID: expectedOwner.streamID,
                actualStreamID: StreamID(0)
            )
        }
        guard savedOwner.streamID == expectedOwner.streamID else {
            return .ownerMismatch(
                expectedStreamID: expectedOwner.streamID,
                actualStreamID: savedOwner.streamID
            )
        }
        return .allowed
    }

    // MARK: - State

    /// Saved window states keyed by window ID
    private var savedStates: [WindowID: SavedWindowState] = [:]

    // MARK: - Window Movement

    /// Move a window to a virtual display's space
    /// - Parameters:
    ///   - windowID: The window to move
    ///   - spaceID: The target space ID (from virtual display)
    ///   - displayID: The virtual display ID (for activating the display space)
    ///   - displayBounds: The bounds of the virtual display
    ///   - targetContentAspectRatio: Optional aspect ratio to fit inside display bounds for app streams.
    func moveWindow(
        _ windowID: WindowID,
        toSpaceID spaceID: CGSSpaceID,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        targetContentAspectRatio: CGFloat? = nil,
        owner: WindowBindingOwner? = nil
    )
    async throws {
        // Get current window info
        guard let windowInfo = getWindowInfo(windowID) else { throw WindowSpaceError.windowNotFound(windowID) }

        if savedStates[windowID] == nil {
            let currentSpaces = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
            let axWindow = resolveAXWindow(for: windowID)
            let trafficLightVisibilitySnapshot = hideTrafficLightsIfSupported(
                windowID: windowID,
                axWindow: axWindow
            )
            let savedState = SavedWindowState(
                windowID: windowID,
                originalFrame: windowInfo.frame,
                originalSpaceIDs: currentSpaces,
                trafficLightVisibilitySnapshot: trafficLightVisibilitySnapshot,
                owner: owner,
                savedAt: Date()
            )
            savedStates[windowID] = savedState
            MirageLogger.host("Saving window \(windowID) state: frame=\(windowInfo.frame), spaces=\(currentSpaces)")
        } else {
            if let owner,
               let existingOwner = savedStates[windowID]?.owner,
               existingOwner.streamID != owner.streamID {
                throw WindowSpaceError.ownerConflict(
                    windowID,
                    existingStreamID: existingOwner.streamID,
                    requestedStreamID: owner.streamID
                )
            }
            if let owner,
               let existing = savedStates[windowID],
               existing.owner == nil {
                savedStates[windowID] = SavedWindowState(
                    windowID: existing.windowID,
                    originalFrame: existing.originalFrame,
                    originalSpaceIDs: existing.originalSpaceIDs,
                    trafficLightVisibilitySnapshot: existing.trafficLightVisibilitySnapshot,
                    owner: owner,
                    savedAt: existing.savedAt
                )
            }
            MirageLogger.host("Window \(windowID) already has saved state; preserving original state during move")
        }

        let resolvedDisplayBounds = resolvePlacementDisplayBounds(
            displayID: displayID,
            fallbackBounds: displayBounds
        )
        let targetOrigin = resolvedDisplayBounds.origin
        let resolvedAXWindow = resolveAXWindow(for: windowID)
        let maxAttempts = 6

        for attempt in 1 ... maxAttempts {
            let didActivateSpaceBeforeMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
            if !didActivateSpaceBeforeMove {
                MirageLogger.host("Failed to set current space \(spaceID) for display \(displayID) before move attempt \(attempt)")
            }

            CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            let didMoveWindow = CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin)
            if !didMoveWindow {
                MirageLogger.debug(.host, "Failed to move window \(windowID) to position \(targetOrigin) on attempt \(attempt)")
            }
            if !raiseWindow(windowID, axWindow: resolvedAXWindow) {
                MirageLogger.debug(.host, "Failed to raise window \(windowID) on move attempt \(attempt)")
            }

            let didActivateSpaceAfterMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
            if !didActivateSpaceAfterMove {
                MirageLogger.host("Failed to set current space \(spaceID) for display \(displayID) after move attempt \(attempt)")
            }

            await fitWindowToVisibleFrame(
                windowID,
                visibleFrame: resolvedDisplayBounds,
                axWindow: resolvedAXWindow,
                targetContentAspectRatio: targetContentAspectRatio
            )

            if verifyWindowPlacement(
                windowID,
                expectedSpaceID: spaceID,
                displayBounds: resolvedDisplayBounds,
                targetOrigin: targetOrigin,
                axWindow: resolvedAXWindow,
                targetContentAspectRatio: targetContentAspectRatio
            ) {
                ensureTrafficLightsHidden(windowID: windowID)
                MirageLogger.host("Moved window \(windowID) to space \(spaceID) at \(targetOrigin) (attempt \(attempt))")
                return
            }

            if attempt < maxAttempts {
                MirageLogger.host(
                    "Window \(windowID) placement not yet confirmed on attempt \(attempt)/\(maxAttempts); retrying"
                )
                try? await Task.sleep(for: .milliseconds(Int64(80 * attempt)))
            }
        }

        throw WindowSpaceError.moveFailed(
            windowID,
            "Placement verification failed for space \(spaceID) on display \(displayID)"
        )
    }

    private func resolvePlacementDisplayBounds(
        displayID: CGDirectDisplayID,
        fallbackBounds: CGRect
    ) -> CGRect {
        let fallback = fallbackBounds.standardized
        let hasFallback = fallback.width > 0 && fallback.height > 0

        let displayBounds: CGRect
        if let modeLogicalResolution = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID)?.logical {
            displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                displayID,
                knownResolution: modeLogicalResolution
            )
        } else if hasFallback {
            displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                displayID,
                knownResolution: fallback.size
            )
        } else {
            displayBounds = CGVirtualDisplayBridge.getDisplayBounds(displayID)
        }

        var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
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

        let sizeTolerance: CGFloat = 12
        let widthClose = abs(visibleBounds.width - fallback.width) <= sizeTolerance
        let heightClose = abs(visibleBounds.height - fallback.height) <= sizeTolerance
        if widthClose, heightClose {
            return visibleBounds
        }

        let originTolerance: CGFloat = 24
        let originClose = abs(visibleBounds.minX - fallback.minX) <= originTolerance &&
            abs(visibleBounds.minY - fallback.minY) <= originTolerance
        let displayContainsVisible = displayBounds.insetBy(dx: -1, dy: -1).contains(visibleBounds)
        let fallbackArea = max(1, fallback.width * fallback.height)
        let visibleArea = max(1, visibleBounds.width * visibleBounds.height)
        let areaGrowthRatio = (visibleArea / fallbackArea) - 1
        let nonShrinkingCandidate = visibleBounds.width >= (fallback.width - sizeTolerance) &&
            visibleBounds.height >= (fallback.height - sizeTolerance)

        // Accept recomputed bounds when they look like a legitimate visible-frame expansion
        // on the same display, rather than cross-display coordinate drift.
        if originClose,
           displayContainsVisible,
           nonShrinkingCandidate,
           areaGrowthRatio >= 0.08 {
            MirageLogger.host(
                "Adopting recomputed placement bounds for display \(displayID) after visible-frame growth: " +
                    "cached=\(fallback), recomputed=\(visibleBounds), display=\(displayBounds)"
            )
            return visibleBounds
        }

        // Virtual-display NSScreen visible-frame reads can drift to unrelated display geometry
        // during space transitions. Keep the calibrated per-stream bounds unless recomputed
        // bounds closely match.
        MirageLogger.host(
            "Using cached placement bounds for display \(displayID) due visible-bounds mismatch: " +
                "cached=\(fallback), recomputed=\(visibleBounds), display=\(displayBounds)"
        )
        return fallback
    }

    private func verifyWindowPlacement(
        _ windowID: WindowID,
        expectedSpaceID: CGSSpaceID,
        displayBounds: CGRect,
        targetOrigin: CGPoint,
        axWindow: AXUIElement?,
        targetContentAspectRatio: CGFloat?
    ) -> Bool {
        let spaces = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
        let expectedSpaceObserved = spaces.contains(expectedSpaceID)
        if !spaces.isEmpty, !expectedSpaceObserved {
            MirageLogger.debug(
                .host,
                "Window \(windowID) not yet in expected space \(expectedSpaceID); current spaces=\(spaces)"
            )
        }

        let frame = resolvedWindowFrame(windowID, axWindow: axWindow)
        guard let frame else {
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

        if (originMatches || intersectsBounds), sizeMatchesExpectation {
            return true
        }

        // Some CGS window queries can report local per-space coordinates. Accept that form only
        // when space membership confirms the window is in the expected target space.
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
            if (localOriginMatches || frame.intersects(localCoordinateBounds)),
               localSizeUpperBoundMatches,
               sizeMatchesExpectation {
                return true
            }
        }

        return false
    }

    /// Restore a window to its original position and space
    /// - Parameter windowID: The window to restore
    func restoreWindow(
        _ windowID: WindowID,
        expectedOwner: WindowBindingOwner? = nil
    ) async throws {
        guard let savedState = savedStates[windowID] else {
            MirageLogger.debug(.host, "No saved state for window \(windowID), cannot restore")
            throw WindowSpaceError.noOriginalState(windowID)
        }
        switch Self.validateRestoreOwner(expectedOwner: expectedOwner, savedOwner: savedState.owner) {
        case .allowed:
            break
        case let .ownerMismatch(expectedStreamID, actualStreamID):
            throw WindowSpaceError.ownerMismatch(
                windowID,
                expectedStreamID: expectedStreamID,
                actualStreamID: actualStreamID
            )
        }
        savedStates.removeValue(forKey: windowID)

        MirageLogger.host("Restoring window \(windowID) to original state")

        // Move back to original spaces
        if !savedState.originalSpaceIDs.isEmpty {
            for spaceID in savedState.originalSpaceIDs {
                CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            }
        }

        // Restore original position
        if let axWindow = resolveAXWindow(for: windowID) {
            _ = await resizeWindowViaAccessibility(
                windowID,
                to: savedState.originalFrame.size,
                axElement: axWindow
            )
        }
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: savedState.originalFrame.origin) {
            MirageLogger.debug(.host, "Failed to restore window \(windowID) position")
        }

        restoreTrafficLightsIfNeeded(savedState.trafficLightVisibilitySnapshot, windowID: windowID)
        MirageLogger.host("Restored window \(windowID) to frame \(savedState.originalFrame)")
    }

    /// Restore a window without throwing (for cleanup scenarios)
    func restoreWindowSilently(
        _ windowID: WindowID,
        expectedOwner: WindowBindingOwner? = nil
    ) async {
        do {
            try await restoreWindow(windowID, expectedOwner: expectedOwner)
        } catch {
            MirageLogger.debug(.host, "Failed to restore window \(windowID): \(error)")
        }
    }

    // MARK: - Window Positioning

    /// Position a window within a display bounds
    /// - Parameters:
    ///   - windowID: The window to position
    ///   - position: Target position within display
    func positionWindow(_ windowID: WindowID, at position: CGPoint) {
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: position) { MirageLogger.debug(.host, "Failed to position window \(windowID) at \(position)") }
    }

    /// Center a window on a display
    /// - Parameters:
    ///   - windowID: The window to center
    ///   - displayBounds: The display bounds
    func centerWindow(_ windowID: WindowID, on displayBounds: CGRect) {
        guard let windowInfo = getWindowInfo(windowID) else { return }

        let windowSize = windowInfo.frame.size
        let centerX = displayBounds.origin.x + (displayBounds.width - windowSize.width) / 2
        let centerY = displayBounds.origin.y + (displayBounds.height - windowSize.height) / 2

        positionWindow(windowID, at: CGPoint(x: centerX, y: centerY))
    }

    private func hideTrafficLightsIfSupported(
        windowID: WindowID,
        axWindow: AXUIElement?
    )
    -> TrafficLightVisibilitySnapshot? {
        guard let axWindow else {
            MirageLogger.debug(.host, "Traffic lights hide unsupported for window \(windowID): AX window unavailable")
            return nil
        }

        let closeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            windowID: windowID
        )
        let minimizeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            windowID: windowID
        )
        let zoomHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            windowID: windowID
        )

        let snapshot = TrafficLightVisibilitySnapshot(
            closeHidden: closeHidden,
            minimizeHidden: minimizeHidden,
            zoomHidden: zoomHidden
        )

        if snapshot.hasRecordedState {
            MirageLogger.host("Applied traffic light hiding for streamed window \(windowID)")
            return snapshot
        }

        MirageLogger.debug(.host, "Traffic lights hide unsupported for window \(windowID): no settable AXHidden buttons")
        return nil
    }

    private func hideTrafficLightButtonIfSupported(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        windowID: WindowID
    )
    -> Bool? {
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): missing \(buttonLabel) button"
            )
            return nil
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard let existingValue = axBooleanAttributeValue(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): \(buttonLabel) AXHidden unavailable"
            )
            return nil
        }

        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return nil
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: true) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return nil
        }

        MirageLogger.host("Hid \(buttonLabel) traffic light for streamed window \(windowID)")
        return existingValue
    }

    private func restoreTrafficLightsIfNeeded(_ snapshot: TrafficLightVisibilitySnapshot?, windowID: WindowID) {
        guard let snapshot, snapshot.hasRecordedState else { return }
        guard let axWindow = resolveAXWindow(for: windowID) else {
            MirageLogger.debug(.host, "Traffic lights restore skipped for window \(windowID): AX window unavailable")
            return
        }

        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            hiddenValue: snapshot.closeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            hiddenValue: snapshot.minimizeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            hiddenValue: snapshot.zoomHidden,
            windowID: windowID
        )

        MirageLogger.host("Restored traffic light visibility for streamed window \(windowID)")
    }

    private func fitWindowToVisibleFrame(
        _ windowID: WindowID,
        visibleFrame: CGRect,
        axWindow: AXUIElement?,
        targetContentAspectRatio: CGFloat?
    )
    async {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return }
        guard let axWindow = axWindow ?? resolveAXWindow(for: windowID) else { return }

        let shouldCompensateTopChrome = false
        let inferredInset: CGFloat = 0

        func fitFrameForInset(_ inset: CGFloat) -> CGRect {
            let unconstrained = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY - inset,
                width: visibleFrame.width,
                height: visibleFrame.height + inset
            )
            return aspectFittedFrame(
                unconstrained,
                targetContentAspectRatio: targetContentAspectRatio
            )
        }

        func effectiveContentRect(for frame: CGRect, fallbackInset: CGFloat) -> CGRect {
            guard shouldCompensateTopChrome else {
                return frame
            }

            let measuredInset = normalizedInset(inferredTopChromeInset(for: axWindow, currentFrame: frame))
            let resolvedInset = measuredInset > 0 ? measuredInset : normalizedInset(fallbackInset)
            let contentHeight = max(1, frame.height - resolvedInset)
            return CGRect(
                x: frame.minX,
                y: frame.minY + resolvedInset,
                width: frame.width,
                height: contentHeight
            )
        }

        func normalizedInset(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return min(120, max(0, ceil(value)))
        }

        var candidateInsets: [CGFloat]
        if shouldCompensateTopChrome {
            candidateInsets = [
                normalizedInset(inferredInset),
                40,
                56,
                72,
                0,
            ]
        } else {
            candidateInsets = [0]
        }
        var uniqueInsets: [CGFloat] = []
        for inset in candidateInsets {
            if !uniqueInsets.contains(where: { abs($0 - inset) <= 0.5 }) {
                uniqueInsets.append(inset)
            }
        }
        candidateInsets = uniqueInsets

        let coverageTargetFrame = aspectFittedFrame(
            visibleFrame,
            targetContentAspectRatio: targetContentAspectRatio
        )
        let minimumCoverageHeight = max(1, coverageTargetFrame.height - 6)
        let minimumCoverageWidth = max(1, coverageTargetFrame.width - 6)
        var bestCoverageHeight: CGFloat = -1
        var bestCoverageWidth: CGFloat = -1
        var bestOrigin: CGPoint?
        var bestSize: CGSize?
        var bestInset: CGFloat = 0

        for inset in candidateInsets {
            let fitFrame = fitFrameForInset(inset)
            let targetSize = CGSize(width: fitFrame.width, height: fitFrame.height)
            if isAXAttributeSettable(axWindow, attribute: kAXSizeAttribute as CFString) {
                _ = await resizeWindowViaAccessibility(windowID, to: targetSize, axElement: axWindow)
            }

            let fittedSize = targetSize
            let targetOrigin = CGPoint(
                x: fitFrame.minX + (fitFrame.width - fittedSize.width) * 0.5,
                y: fitFrame.minY
            )

            var mutablePoint = targetOrigin
            if let positionValue = AXValueCreate(.cgPoint, &mutablePoint) {
                _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
            }
            if !CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin) {
                MirageLogger.debug(.host, "Failed to place window \(windowID) at \(targetOrigin)")
            }

            let observedFrame = resolvedWindowFrame(windowID, axWindow: axWindow)
            let requestedFrame = CGRect(origin: targetOrigin, size: fittedSize)
            let resolvedFrame: CGRect
            if let observedFrame {
                resolvedFrame = observedFrame
            } else {
                resolvedFrame = requestedFrame
            }
            let coverageRect = effectiveContentRect(for: resolvedFrame, fallbackInset: inset).intersection(visibleFrame)
            let coverageHeight = max(0, coverageRect.height)
            let coverageWidth = max(0, coverageRect.width)
            if coverageHeight > bestCoverageHeight ||
                (abs(coverageHeight - bestCoverageHeight) <= 0.5 && coverageWidth > bestCoverageWidth) {
                bestCoverageHeight = coverageHeight
                bestCoverageWidth = coverageWidth
                bestOrigin = targetOrigin
                bestSize = fittedSize
                bestInset = inset
            }

            if coverageHeight >= minimumCoverageHeight, coverageWidth >= minimumCoverageWidth {
                return
            }
        }

        if let bestOrigin {
            if let bestSize, isAXAttributeSettable(axWindow, attribute: kAXSizeAttribute as CFString) {
                _ = await resizeWindowViaAccessibility(windowID, to: bestSize, axElement: axWindow)
            }
            var mutablePoint = bestOrigin
            if let positionValue = AXValueCreate(.cgPoint, &mutablePoint) {
                _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
            }
            _ = CGSWindowSpaceBridge.moveWindow(windowID, to: bestOrigin)
            MirageLogger.debug(
                .host,
                "Window \(windowID) best-fit content coverage within visible frame: \(Int(bestCoverageWidth))x\(Int(bestCoverageHeight)) (inset=\(Int(bestInset)))"
            )
        }
    }

    private func aspectFittedFrame(
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
            // Container is wider than requested, constrain width.
            fittedWidth = floor(frame.height * requestedAspect)
        } else {
            // Container is taller than requested, constrain height.
            fittedHeight = floor(frame.width / requestedAspect)
        }

        fittedWidth = max(1, fittedWidth)
        fittedHeight = max(1, fittedHeight)

        let originX = frame.minX + (frame.width - fittedWidth) * 0.5
        let originY = frame.minY + (frame.height - fittedHeight) * 0.5

        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }

    private func raiseWindow(_ windowID: WindowID, axWindow: AXUIElement?) -> Bool {
        let didRaiseWithCGS = CGSWindowSpaceBridge.bringWindowToFront(windowID)
        if didRaiseWithCGS {
            return true
        }
        guard let axWindow else { return false }
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    private func inferredTopChromeInset(
        for axWindow: AXUIElement,
        currentFrame: CGRect?
    ) -> CGFloat {
        guard let windowFrame = currentFrame else { return 0 }
        guard let closeButton = axElementAttributeValue(axWindow, attribute: kAXCloseButtonAttribute as CFString),
              let closeButtonFrame = axWindowFrame(closeButton) else {
            return 0
        }
        let inferredInset = (closeButtonFrame.maxY - windowFrame.minY) + 6
        guard inferredInset.isFinite else { return 0 }
        return min(140, max(0, ceil(inferredInset)))
    }

    private func ensureTrafficLightsHidden(windowID: WindowID) {
        guard var savedState = savedStates[windowID] else { return }
        guard let axWindow = resolveAXWindow(for: windowID) else { return }
        let existingSnapshot = savedState.trafficLightVisibilitySnapshot
        let attemptedSnapshot = hideTrafficLightsIfSupported(
            windowID: windowID,
            axWindow: axWindow
        )

        guard existingSnapshot == nil || existingSnapshot?.hasRecordedState == false else { return }
        guard let attemptedSnapshot, attemptedSnapshot.hasRecordedState else { return }

        savedState = SavedWindowState(
            windowID: savedState.windowID,
            originalFrame: savedState.originalFrame,
            originalSpaceIDs: savedState.originalSpaceIDs,
            trafficLightVisibilitySnapshot: attemptedSnapshot,
            owner: savedState.owner,
            savedAt: savedState.savedAt
        )
        savedStates[windowID] = savedState
    }

    private func restoreTrafficLightButtonIfNeeded(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        hiddenValue: Bool?,
        windowID: WindowID
    ) {
        guard let hiddenValue else { return }
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore skipped for window \(windowID): missing \(buttonLabel) button"
            )
            return
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore skipped for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: hiddenValue) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return
        }
    }

    private func resolveAXWindow(for windowID: WindowID) -> AXUIElement? {
        guard let windowInfo = getWindowInfo(windowID) else { return nil }
        guard let ownerPID = windowInfo.ownerPID else { return nil }

        let appElement = AXUIElementCreateApplication(ownerPID)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let axWindowsValue = windowsRef,
              let axWindows = axWindowsValue as? [AXUIElement],
              !axWindows.isEmpty else {
            return nil
        }

        if axWindows.count == 1 {
            return axWindows[0]
        }

        // Prefer exact window-ID matching so traffic-light changes and size/position writes
        // target the streamed window even when an app has multiple similarly sized windows.
        for axWindow in axWindows {
            var candidateWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &candidateWindowID) == .success,
               WindowID(candidateWindowID) == windowID {
                return axWindow
            }
        }

        let targetFrame = windowInfo.frame
        for axWindow in axWindows {
            guard let frame = axWindowFrame(axWindow) else { continue }
            if abs(frame.origin.x - targetFrame.origin.x) <= 24,
               abs(frame.origin.y - targetFrame.origin.y) <= 24,
               abs(frame.size.width - targetFrame.size.width) <= 24,
               abs(frame.size.height - targetFrame.size.height) <= 24 {
                return axWindow
            }
        }

        return axWindows.first
    }

    private func axWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func resolvedWindowFrame(_ windowID: WindowID, axWindow: AXUIElement?) -> CGRect? {
        if let axWindow {
            if let axFrame = axWindowFrame(axWindow) {
                return axFrame
            }
        }
        if let compositorFrame = getWindowInfo(windowID)?.frame {
            return compositorFrame
        }
        return nil
    }

    private func axElementAttributeValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func axBooleanAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        return nil
    }

    private func isAXAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func setAXBooleanAttributeValue(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
        let targetValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute, targetValue) == .success
    }

    // MARK: - State Queries

    /// Check if we have saved state for a window
    func hasSavedState(for windowID: WindowID) -> Bool {
        savedStates[windowID] != nil
    }

    /// Get the saved state for a window
    func getSavedState(for windowID: WindowID) -> SavedWindowState? {
        savedStates[windowID]
    }

    /// Get all windows with saved states
    func windowsWithSavedStates() -> [WindowID] {
        Array(savedStates.keys)
    }

    /// Get all window IDs that have been moved to the shared virtual display
    /// Alias for windowsWithSavedStates() with clearer semantics for shared display usage
    func getMovedWindowIDs() -> [WindowID] {
        Array(savedStates.keys)
    }

    // MARK: - Cleanup

    /// Clear saved state for a window without restoring
    /// Use when the window has been closed
    func clearSavedState(for windowID: WindowID) {
        savedStates.removeValue(forKey: windowID)
    }

    /// Restore all windows and clear all saved states
    /// Called during host shutdown
    func restoreAllWindows() async {
        let windowIDs = Array(savedStates.keys)
        for windowID in windowIDs {
            await restoreWindowSilently(windowID)
        }
        MirageLogger.host("Restored all \(windowIDs.count) windows")
    }

    // MARK: - Helpers

    /// Get information about a window from CGWindowList
    private func getWindowInfo(_ windowID: WindowID) -> (frame: CGRect, title: String?, ownerPID: pid_t?)? {
        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]

        guard let info = windowList?.first else { return nil }

        guard let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }

        let frame = CGRect(x: x, y: y, width: width, height: height)
        let title = info[kCGWindowName] as? String
        let ownerPID = (info[kCGWindowOwnerPID] as? NSNumber).map { pid_t($0.int32Value) }

        return (frame, title, ownerPID)
    }

    /// Get all windows on a specific display
    func getWindowsOnDisplay(_ displayID: CGDirectDisplayID) -> [WindowID] {
        let displayBounds = CGDisplayBounds(displayID)

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else { return [] }

        var windowsOnDisplay: [WindowID] = []

        for info in windowList {
            guard let windowID = info[kCGWindowNumber] as? WindowID,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"] else {
                continue
            }

            // Check if window origin is within display bounds
            let windowOrigin = CGPoint(x: x, y: y)
            if displayBounds.contains(windowOrigin) { windowsOnDisplay.append(windowID) }
        }

        return windowsOnDisplay
    }
}

// MARK: - Accessibility Integration

extension WindowSpaceManager {
    /// Resize a window using Accessibility API
    /// This is more reliable than CGS APIs for some apps
    func resizeWindowViaAccessibility(
        _ windowID: WindowID,
        to size: CGSize,
        axElement: AXUIElement? = nil
    )
    async -> Bool {
        // If no AX element provided, we can't resize via accessibility
        guard let element = axElement else {
            MirageLogger.debug(.host, "No AXUIElement provided for window \(windowID)")
            return false
        }

        // Set size
        var mutableSize = size
        var sizeValue = AXValueCreate(.cgSize, &mutableSize)
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue as CFTypeRef)

        guard result == .success else {
            MirageLogger.debug(.host, "Failed to resize window \(windowID) via Accessibility: \(result)")
            return false
        }

        let tolerance: CGFloat = 3
        let maxAttempts = 6
        for attempt in 1 ... maxAttempts {
            let compositorFrame = getWindowInfo(windowID)?.frame
            let axFrame = axWindowFrame(element)
            let compositorMatches = if let compositorFrame {
                abs(compositorFrame.width - size.width) <= tolerance &&
                    abs(compositorFrame.height - size.height) <= tolerance
            } else {
                false
            }
            let axMatches = if let axFrame {
                abs(axFrame.width - size.width) <= tolerance &&
                    abs(axFrame.height - size.height) <= tolerance
            } else {
                false
            }

            if compositorMatches || (compositorFrame == nil && axMatches) {
                let observedCompositor = compositorFrame.map { "\($0.size)" } ?? "unknown"
                let observedAX = axFrame.map { "\($0.size)" } ?? "unknown"
                MirageLogger.host(
                    "Resized window \(windowID) to \(size) via Accessibility (compositor=\(observedCompositor), ax=\(observedAX), attempt \(attempt))"
                )
                return true
            }
            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        let observedCompositorSizeText = if let compositorFrame = getWindowInfo(windowID)?.frame {
            "\(compositorFrame.size)"
        } else {
            "unknown"
        }
        let observedAXSizeText = axWindowFrame(element).map { "\($0.size)" } ?? "unknown"
        MirageLogger.debug(
            .host,
            "Accessibility resize for window \(windowID) did not converge to \(size); compositor=\(observedCompositorSizeText), ax=\(observedAXSizeText)"
        )
        return false
    }
}

#endif
