//
//  ScrollPhysicsCapturingNSView+CursorLock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Cursor Lock

    var shouldHideSystemCursor: Bool {
        guard isInputProcessingActive else { return false }
        return hideSystemCursor ||
            (cursorLockEnabled && syntheticCursorEnabled) ||
            cursorHiddenForTyping
    }

    func updateSystemCursorVisibility() {
        if shouldHideSystemCursor {
            if !cursorHidden {
                Self.cursorSystemHooks.hideCursor()
                cursorHidden = true
            }
        } else if cursorHidden {
            Self.cursorSystemHooks.unhideCursor()
            cursorHidden = false
        }
    }

    var currentNormalizedMouseLocation: CGPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: Self.cursorSystemHooks.mouseLocation())
        let locationInView = convert(windowPoint, from: nil)
        let contentRect = resolvedDesktopPresentationContentRect
        guard contentRect.contains(locationInView) else { return nil }
        return Self.normalizedLocation(locationInView, in: bounds, contentRect: contentRect)
    }

    var unlockedSyntheticCursorPosition: CGPoint? {
        guard syntheticCursorEnabled,
              hideSystemCursor,
              !cursorLockEnabled,
              mirroredSystemCursorVisible else {
            return nil
        }

        return lastMouseLocation ?? currentNormalizedMouseLocation
    }

    func updateLockedCursorViewVisibility() {
        let shouldShow = syntheticCursorEnabled &&
            !cursorHiddenForTyping &&
            ((cursorLockEnabled && lockedCursorVisible) || unlockedSyntheticCursorPosition != nil)
        lockedCursorView.isHidden = !shouldShow
    }

    func hideCursorForTypingUntilPointerMovement() {
        guard !cursorHiddenForTyping else { return }
        cursorHiddenForTyping = true
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
    }

    func revealCursorAfterPointerMovement() {
        guard cursorHiddenForTyping else { return }
        cursorHiddenForTyping = false
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
    }

    func updateCursorLockMode() {
        guard isInputProcessingActive else {
            stopLockedCursorSmoothing()
            restoreCursorLockIfNeeded()
            return
        }

        if cursorLockEnabled {
            beginCursorLockSessionIfNeeded()
            updateSystemCursorVisibility()
            updateCursorLockAnchor()
            warpCursorToAnchor()
            startLockedCursorSmoothingIfNeeded()
            refreshCursorUpdates(force: true)
            setLockedCursorVisible(lockedCursorVisible)
        } else {
            stopLockedCursorSmoothing()
            restoreCursorLockIfNeeded()
            refreshCursorUpdates(force: true)
        }
    }

    func updateCursorLockAnchor() {
        guard let window else { return }
        let localPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(localPoint, to: nil)
        cursorLockAnchor = window.convertPoint(toScreen: windowPoint)
    }

    func beginCursorLockSessionIfNeeded() {
        guard cursorLockRestorePosition == nil else { return }
        cursorLockRestorePosition = Self.cursorSystemHooks.mouseLocation()
        Self.cursorSystemHooks.setAssociationEnabled(false)
    }

    func warpCursorToAnchor() {
        guard cursorLockEnabled else { return }
        guard window != nil else { return }
        warpSystemCursor(toCocoaScreenPosition: cursorLockAnchor)
    }

    func resetCursorLockTransientState() {
        cursorLockAnchor = .zero
        lastMouseLocation = nil
        lastCursorLocalInputTime = 0
        lockedCursorTargetPosition = lockedCursorPosition
        lockedCursorTargetVisible = lockedCursorVisible
        cursorHiddenForTyping = false
        suppressEscapeKeyUpForCursorUnlock = false
    }

    func restoreCursorLockIfNeeded() {
        let restorePosition = cursorLockRestorePosition
        cursorLockRestorePosition = nil
        if restorePosition != nil {
            Self.cursorSystemHooks.setAssociationEnabled(true)
        }
        if let restorePosition {
            warpSystemCursor(toCocoaScreenPosition: restorePosition)
        }
        resetCursorLockTransientState()
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
        applyMirroredSystemCursorAppearance()
    }

    func invalidateHostCursorRects() {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    func applyMirroredSystemCursorAppearance() {
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
        invalidateHostCursorRects()

        guard shouldMirrorHostCursorAppearanceToSystemCursor, mirroredSystemCursorVisible, isMouseInsideView else { return }
        Self.cursorSystemHooks.setCursor(mirroredSystemCursorType.nsCursor)
    }

    var isMouseInsideView: Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: Self.cursorSystemHooks.mouseLocation())
        let locationInView = convert(windowPoint, from: nil)
        return resolvedDesktopPresentationContentRect.contains(locationInView)
    }

    func warpSystemCursor(toCocoaScreenPosition position: CGPoint) {
        Self.cursorSystemHooks.warpCursor(
            Self.globalDisplayCursorPosition(
                fromCocoaScreenPosition: position,
                globalFrameMaxY: Self.globalDisplayFrameMaxY()
            )
        )
    }

    func refreshMirroredSystemCursorIfNeeded(force: Bool = false) {
        guard isInputProcessingActive, let streamID else { return }

        let positionSnapshot = cursorPositionStore?.snapshot(for: streamID)
        let cursorSnapshot = cursorStore?.snapshot(for: streamID)
        let resolvedVisibility = positionSnapshot?.isVisible ?? cursorSnapshot?.isVisible ?? mirroredSystemCursorVisible
        var didUpdate = force

        if let positionSnapshot, force || positionSnapshot.sequence != mirroredSystemCursorPositionSequence {
            mirroredSystemCursorPositionSequence = positionSnapshot.sequence
            mirroredSystemCursorPosition = Self.clampedNormalizedCursorPosition(positionSnapshot.position)
            didUpdate = true
        }

        if let cursorSnapshot, force || cursorSnapshot.sequence != mirroredSystemCursorTypeSequence {
            mirroredSystemCursorTypeSequence = cursorSnapshot.sequence
            let typeChanged = mirroredSystemCursorType != cursorSnapshot.cursorType
            mirroredSystemCursorType = cursorSnapshot.cursorType
            if typeChanged {
                updateLockedCursorImage()
            }
            didUpdate = true
        }

        if mirroredSystemCursorVisible != resolvedVisibility {
            mirroredSystemCursorVisible = resolvedVisibility
            didUpdate = true
        }

        guard didUpdate else { return }
        applyMirroredSystemCursorAppearance()
    }

    nonisolated static func clampedNormalizedCursorPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }

    nonisolated static func normalizedCursorPosition(
        _ position: CGPoint,
        allowsExtendedBounds: Bool
    )
    -> CGPoint {
        LockedCursorPositionResolver.resolve(position, allowsExtendedBounds: allowsExtendedBounds)
    }

    nonisolated static func localPoint(
        forNormalizedCursorPosition position: CGPoint,
        in bounds: CGRect,
        contentRect: CGRect? = nil
    )
    -> CGPoint {
        let resolvedContentRect = contentRect ?? bounds
        return DesktopPresentationGeometry.localPoint(for: position, in: resolvedContentRect)
    }

    nonisolated static func normalizedLocation(
        _ point: CGPoint,
        in bounds: CGRect,
        contentRect: CGRect? = nil
    )
    -> CGPoint {
        let resolvedContentRect = contentRect ?? bounds
        return DesktopPresentationGeometry.normalizedPosition(for: point, in: resolvedContentRect)
    }

    func requestCursorLockRecaptureIfNeeded() -> Bool {
        guard canRecaptureCursorLock else { return false }
        window?.makeFirstResponder(self)
        onCursorLockRecaptureRequested?()
        return true
    }

    func requestCursorLockEscapeIfNeeded(for event: NSEvent) -> Bool {
        guard cursorLockEnabled else { return false }
        let modifiers = MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        guard modifiers.isEmpty else { return false }
        onCursorLockEscapeRequested?()
        return true
    }

    func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = isVisible
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func updateLocalMouseLocation(_ location: CGPoint?) {
        lastMouseLocation = location
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func resolvedLockedCursorEventPosition(_ position: CGPoint) -> CGPoint {
        Self.normalizedCursorPosition(position, allowsExtendedBounds: allowsExtendedCursorBounds)
    }

    var lockedCursorActionPosition: CGPoint {
        resolvedLockedCursorEventPosition(lockedCursorPosition)
    }

    /// Aspect-fit desktop content rect inside this view's current bounds.
    var resolvedDesktopPresentationContentRect: CGRect {
        DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: desktopPresentationReferenceSize,
            in: bounds
        )
    }

    func updateLockedCursorViewPosition() {
        guard !lockedCursorView.isHidden else { return }
        let contentRect = resolvedDesktopPresentationContentRect
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        let cursorPosition = if cursorLockEnabled {
            lockedCursorPosition
        } else if let unlockedSyntheticCursorPosition {
            unlockedSyntheticCursorPosition
        } else {
            mirroredSystemCursorPosition
        }
        let point = Self.localPoint(
            forNormalizedCursorPosition: cursorPosition,
            in: bounds,
            contentRect: contentRect
        )
        let hotspot = mirroredSystemCursorType.nsCursor.hotSpot
        // macOS uses flipped coordinates for the hotspot Y (bottom-left origin)
        lockedCursorView.frame.origin = CGPoint(
            x: point.x - hotspot.x,
            y: point.y - (lockedCursorView.frame.height - hotspot.y)
        )
    }

    func applyLockedCursorDelta(dx: CGFloat, dy: CGFloat) {
        let normSize = hostDisplayPointSize ?? bounds.size
        lockedCursorPosition = LockedCursorPositionResolver.applyRelativeDelta(
            currentPosition: lockedCursorPosition,
            deltaX: dx,
            deltaY: dy,
            normalizationSize: normSize,
            allowsExtendedBounds: allowsExtendedCursorBounds,
            confirmedHostPosition: lockedCursorConfirmedHostPosition
        )
        noteCursorLocalInput()
        setLockedCursorVisible(true)
        lastMouseLocation = lockedCursorPosition
    }

    func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = resolvedLockedCursorEventPosition(position)
        lockedCursorConfirmedHostPosition = lockedCursorTargetPosition
        lockedCursorTargetVisible = isVisible
        guard cursorLockEnabled else { return }
        guard !isCursorLocalInputActive() else { return }
        applyLockedCursorTargetStep()
    }

    func applyLockedCursorTargetStep() {
        setLockedCursorVisible(lockedCursorTargetVisible)
        guard lockedCursorTargetVisible else { return }
        let deltaX = lockedCursorTargetPosition.x - lockedCursorPosition.x
        let deltaY = lockedCursorTargetPosition.y - lockedCursorPosition.y
        let distance = hypot(deltaX, deltaY)
        if distance < Self.lockedCursorStopThreshold { return }
        if distance > Self.lockedCursorSnapThreshold {
            lockedCursorPosition = lockedCursorTargetPosition
        } else {
            lockedCursorPosition = CGPoint(
                x: lockedCursorPosition.x + deltaX * Self.lockedCursorLerpAlpha,
                y: lockedCursorPosition.y + deltaY * Self.lockedCursorLerpAlpha
            )
        }
        lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
        lastMouseLocation = lockedCursorPosition
        updateLockedCursorViewPosition()
    }

    func noteCursorLocalInput() {
        lastCursorLocalInputTime = CACurrentMediaTime()
        if cursorLockEnabled {
            lockedCursorTargetPosition = lockedCursorPosition
            lockedCursorTargetVisible = true
        }
    }

    func isCursorLocalInputActive() -> Bool {
        let now = CACurrentMediaTime()
        return now - lastCursorLocalInputTime < Self.cursorLocalHoldInterval
    }

    func startLockedCursorSmoothingIfNeeded() {
        guard lockedCursorSmoothingTimer == nil else { return }
        lockedCursorSmoothingTimer = Timer.scheduledTimer(
            withTimeInterval: MirageMedia.MirageInteractionCadence.frameInterval120Seconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLockedCursorSmoothing()
            }
        }
    }

    func stopLockedCursorSmoothing() {
        lockedCursorSmoothingTimer?.invalidate()
        lockedCursorSmoothingTimer = nil
    }

    func handleLockedCursorSmoothing() {
        guard isInputProcessingActive, cursorLockEnabled else {
            stopLockedCursorSmoothing()
            return
        }
        guard !isCursorLocalInputActive() else { return }
        applyLockedCursorTargetStep()
    }

    func refreshLockedCursorIfNeeded(force: Bool = false) -> Bool {
        guard isInputProcessingActive, cursorLockEnabled, let cursorPositionStore, let streamID else { return false }
        let now = CACurrentMediaTime()
        if !force, now - lastLockedCursorRefreshTime < Self.lockedCursorRefreshInterval { return false }
        lastLockedCursorRefreshTime = now
        guard let snapshot = cursorPositionStore.snapshot(for: streamID) else { return false }
        guard force || snapshot.sequence != lockedCursorSequence else { return false }
        lockedCursorSequence = snapshot.sequence
        applyLockedCursorHostUpdate(position: snapshot.position, isVisible: snapshot.isVisible)
        return true
    }

    func refreshCursorUpdates(force: Bool) {
        guard isInputProcessingActive else { return }
        refreshMirroredSystemCursorIfNeeded(force: force)
        let updatedFromPosition = refreshLockedCursorIfNeeded(force: force)
        guard cursorLockEnabled else { return }
        if !updatedFromPosition, let cursorStore, let streamID,
           let snapshot = cursorStore.snapshot(for: streamID) {
            setLockedCursorVisible(snapshot.isVisible)
        }
    }
}
#endif
