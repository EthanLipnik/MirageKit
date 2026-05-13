//
//  InputCapturingView+PointerClickState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func nextPrimaryClickCount(at location: CGPoint, timestamp: TimeInterval) -> Int {
        let timeSinceLastTap = timestamp - lastTapTime
        let distance = clickDistanceInPoints(from: location, to: lastTapLocation)

        guard lastCompletedClickCount > 0,
              timeSinceLastTap >= 0,
              timeSinceLastTap < Self.multiClickTimeThreshold,
              distance < Self.multiClickDistanceThresholdPoints else {
            return 1
        }

        return lastCompletedClickCount + 1
    }

    func commitPrimaryClick(at location: CGPoint, timestamp: TimeInterval, clickCount: Int) {
        lastTapTime = timestamp
        lastTapLocation = location
        lastCompletedClickCount = clickCount
    }

    func resetPrimaryClickTracking() {
        lastCompletedClickCount = 0
        lastTapTime = 0
    }

    func isDirectPrimaryClickContinuationCandidate(at rawLocation: CGPoint, timestamp: TimeInterval) -> Bool {
        guard cursorLockEnabled || directTouchInputMode == .normal else { return false }
        let location = normalizedLocation(rawLocation)
        return nextPrimaryClickCount(at: location, timestamp: timestamp) > 1
    }

    nonisolated static func directTouchDragActivationExceeded(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragActivationMovementThresholdPoints
    }

    func nextSecondaryClickCount(at location: CGPoint, timestamp: TimeInterval) -> Int {
        let timeSinceLastTap = timestamp - lastRightTapTime
        let distance = clickDistanceInPoints(from: location, to: lastRightTapLocation)

        guard lastCompletedRightClickCount > 0,
              timeSinceLastTap >= 0,
              timeSinceLastTap < Self.multiClickTimeThreshold,
              distance < Self.multiClickDistanceThresholdPoints else {
            return 1
        }

        return lastCompletedRightClickCount + 1
    }

    func commitSecondaryClick(at location: CGPoint, timestamp: TimeInterval, clickCount: Int) {
        lastRightTapTime = timestamp
        lastRightTapLocation = location
        lastCompletedRightClickCount = clickCount
    }

    func resetSecondaryClickTracking() {
        lastCompletedRightClickCount = 0
        lastRightTapTime = 0
    }

    func pointerReleaseLocation() -> CGPoint {
        if pencilButtonDown {
            return pencilCurrentLocation
        }
        if lockedPointerButtonDown {
            return lockedCursorActionPosition()
        }
        if virtualDragActive {
            return trackpadCursorActionPosition()
        }
        if longPressButtonDown || directLongPressButtonDown || directDoubleTapDragButtonDown || directTwoFingerDragButtonDown {
            return lastPanLocation
        }
        if cursorLockEnabled {
            return lockedCursorActionPosition()
        }
        if usesVirtualTrackpad {
            return trackpadCursorPosition()
        }
        if let lastCursorPosition {
            return lastCursorPosition
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    func releaseActivePointerButtonsIfNeeded(reason: String) {
        let shouldReleasePrimaryButton = longPressButtonDown ||
            directLongPressButtonDown ||
            directDoubleTapDragButtonDown ||
            directTwoFingerDragButtonDown ||
            lockedPointerButtonDown ||
            virtualDragActive ||
            pencilButtonDown
        guard shouldReleasePrimaryButton else { return }

        let releaseLocation = pointerReleaseLocation()
        if pencilButtonDown, let stylus = pencilCurrentStylus {
            let sample = MiragePointerSample(
                location: releaseLocation,
                pressure: 0,
                stylus: stylus,
                timestamp: Date.timeIntervalSinceReferenceDate
            )
            sendPencilSampleBatch(
                phase: .cancelled,
                modifiers: keyboardModifiers,
                clickCount: max(1, currentClickCount),
                isButtonPressed: false,
                samples: [sample]
            )
        } else {
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: releaseLocation,
                clickCount: max(1, currentClickCount),
                modifiers: keyboardModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
        }
        MirageLogger.client("Released active primary pointer state (\(reason))")

        longPressButtonDown = false
        directLongPressButtonDown = false
        directDoubleTapDragButtonDown = false
        directTwoFingerDragButtonDown = false
        lockedPointerButtonDown = false
        lockedPointerDraggedSinceDown = false
        virtualDragActive = false
        pencilButtonDown = false
        longPressCancelledForMultiTouch = false
        isDragging = false
    }

    func resetPointerSuppressionState(reason: String) {
        let hadSuppressedGesture = swallowingLongPressForCursorRecapture ||
            swallowingVirtualCursorLongPressForCursorRecapture ||
            swallowingDirectLongPressForCursorRecapture ||
            swallowingDirectDoubleTapDragForCursorRecapture ||
            swallowingDirectTwoFingerDragForCursorRecapture ||
            suppressEscapeKeyUpForCursorUnlock

        swallowingLongPressForCursorRecapture = false
        swallowingVirtualCursorLongPressForCursorRecapture = false
        swallowingDirectLongPressForCursorRecapture = false
        swallowingDirectDoubleTapDragForCursorRecapture = false
        swallowingDirectTwoFingerDragForCursorRecapture = false
        suppressEscapeKeyUpForCursorUnlock = false
        lockedPointerDraggedSinceDown = false
        lockedPointerLastHoverLocation = nil

        guard hadSuppressedGesture else { return }
        MirageLogger.client("Cleared suppressed pointer gesture state (\(reason))")
    }

    func clickDistanceInPoints(from source: CGPoint, to target: CGPoint) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else {
            return .greatestFiniteMagnitude
        }

        let deltaX = (source.x - target.x) * bounds.width
        let deltaY = (source.y - target.y) * bounds.height
        return hypot(deltaX, deltaY)
    }
}
#endif
