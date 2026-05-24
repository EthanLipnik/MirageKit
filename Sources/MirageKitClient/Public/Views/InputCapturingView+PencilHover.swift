//
//  InputCapturingView+PencilHover.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func stylusHoverEvent(from gesture: UIHoverGestureRecognizer) -> MirageStylusEvent? {
        guard gesture.zOffset > 0 else { return nil }

        let altitude = min(max(gesture.altitudeAngle, 0), .pi / 2)
        let azimuth = gesture.azimuthAngle(in: self)
        let azimuthUnitVector = gesture.azimuthUnitVector(in: self)
        let tiltMagnitude = min(max(cos(altitude), 0), 1)
        let tiltX = min(max(azimuthUnitVector.dx * tiltMagnitude, -1), 1)
        let tiltY = min(max(azimuthUnitVector.dy * tiltMagnitude, -1), 1)
        let rollAngle: CGFloat?
        #if os(iOS)
        rollAngle = gesture.rollAngle
        #else
        rollAngle = nil
        #endif

        return MirageStylusEvent(
            altitudeAngle: altitude,
            azimuthAngle: azimuth,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: rollAngle,
            zOffset: gesture.zOffset,
            isHovering: true
        )
    }

    func sendPencilHoverBatch(
        location: CGPoint,
        stylus: MirageStylusEvent,
        modifiers: MirageModifierFlags,
        now: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    ) {
        lastPencilHoverLocation = location
        lastPencilHoverStylus = stylus

        guard shouldForwardPencilHover(location: location, now: now) else { return }
        let timestamp = Date.timeIntervalSinceReferenceDate
        let sample = MiragePointerSample(
            location: location,
            pressure: 0,
            stylus: stylus,
            timestamp: timestamp
        )
        let batch = MiragePointerSampleBatch(
            phase: .hover,
            button: .left,
            modifiers: modifiers,
            clickCount: 0,
            isButtonPressed: false,
            samples: [sample],
            timestamp: timestamp
        )
        onInputEvent?(.pointerSampleBatch(batch))
        lastPencilHoverForwardTime = now
        lastPencilHoverForwardLocation = location
    }

    func shouldForwardPencilHover(
        location: CGPoint,
        now: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard let lastLocation = lastPencilHoverForwardLocation else { return true }

        let elapsed = now - lastPencilHoverForwardTime
        guard elapsed >= Self.pencilHoverMinimumInterval else { return false }

        let distance = clickDistanceInPoints(from: location, to: lastLocation)
        return distance >= Self.pencilHoverMinimumDistancePoints
    }

    func sendPencilHoverExitIfNeeded() {
        guard lastPencilHoverForwardLocation != nil,
              let location = lastPencilHoverLocation,
              let stylus = lastPencilHoverStylus else {
            clearPencilHoverState()
            return
        }

        let timestamp = Date.timeIntervalSinceReferenceDate
        let sample = MiragePointerSample(
            location: location,
            pressure: 0,
            stylus: MirageStylusEvent(
                altitudeAngle: stylus.altitudeAngle,
                azimuthAngle: stylus.azimuthAngle,
                tiltX: stylus.tiltX,
                tiltY: stylus.tiltY,
                rollAngle: stylus.rollAngle,
                zOffset: stylus.zOffset,
                isHovering: true
            ),
            timestamp: timestamp
        )
        let batch = MiragePointerSampleBatch(
            phase: .cancelled,
            button: .left,
            modifiers: keyboardModifiers,
            clickCount: 0,
            isButtonPressed: false,
            samples: [sample],
            timestamp: timestamp
        )
        onInputEvent?(.pointerSampleBatch(batch))
        clearPencilHoverState()
    }

    func clearPencilHoverState() {
        lastPencilHoverForwardTime = 0
        lastPencilHoverForwardLocation = nil
        lastPencilHoverLocation = nil
        lastPencilHoverStylus = nil
    }
}
#endif
