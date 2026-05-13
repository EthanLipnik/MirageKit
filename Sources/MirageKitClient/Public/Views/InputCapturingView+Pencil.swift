//
//  InputCapturingView+Pencil.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    // MARK: - Pencil Input

    /// Installs the platform Pencil interaction used for squeeze/double-tap actions.
    func setupPencilInteraction() {
        #if os(iOS)
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        addInteraction(interaction)
        pencilInteraction = interaction
        #endif
    }

    /// Installs the touch recognizer that routes Pencil contact before general direct-touch gestures.
    func setupPencilContactGestureRecognizer() {
        let gesture = PencilContactGestureRecognizer()
        gesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.isStylusTouch = { [weak self] touch in
            self?.isStylusTouch(touch) ?? false
        }
        gesture.onTouchesBegan = { [weak self] touches in
            self?.handlePencilTouchesBegan(touches)
        }
        gesture.onTouchesMoved = { [weak self] touches, event in
            self?.handlePencilTouchesMoved(touches, event: event)
        }
        gesture.onTouchesEnded = { [weak self] touches in
            self?.handlePencilTouchesEnded(touches)
        }
        gesture.onTouchesCancelled = { [weak self] touches in
            self?.handlePencilTouchesCancelled(touches)
        }
        pencilContactGesture = gesture
        addGestureRecognizer(gesture)
    }

    /// Clears active Pencil contact state after cancellation, reset, or teardown.
    func resetPencilGestureState() {
        activePencilTouchID = nil
        pencilButtonDown = false
        pencilCurrentLocation = .zero
        pencilCurrentStylus = nil
        lastPencilPressure = 0
        lastPencilMoveSampleTimestamp = 0
        lastPencilMoveSampleLocation = nil
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesBegan(touchSplit.stylus)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesBegan(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesMoved(touchSplit.stylus, event: event)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesMoved(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesEnded(touchSplit.stylus)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesEnded(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesCancelled(touchSplit.stylus)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesCancelled(touchSplit.nonStylus, with: event)
        }
    }

    func splitStylusTouches(_ touches: Set<UITouch>) -> (stylus: Set<UITouch>, nonStylus: Set<UITouch>) {
        var stylusTouches = Set<UITouch>()
        var nonStylusTouches = Set<UITouch>()

        for touch in touches {
            if isStylusTouch(touch) {
                stylusTouches.insert(touch)
            } else {
                nonStylusTouches.insert(touch)
            }
        }

        return (stylusTouches, nonStylusTouches)
    }

    func isStylusTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        guard touch.type == .direct else { return false }

        // Some iPadOS builds report Pencil contact as direct while still exposing
        // stylus-only metrics. Prefer those metrics over touch.type for routing.
        if touch.maximumPossibleForce > 1.0 { return true }
        if touch.force > 1.0 { return true }
        if touch.estimatedProperties.contains(.force) ||
            touch.estimatedProperties.contains(.azimuth) ||
            touch.estimatedProperties.contains(.altitude) {
            return true
        }
        if touch.estimatedPropertiesExpectingUpdates.contains(.force) ||
            touch.estimatedPropertiesExpectingUpdates.contains(.azimuth) ||
            touch.estimatedPropertiesExpectingUpdates.contains(.altitude) {
            return true
        }
        return false
    }

    func handlePencilTouchesBegan(_ touches: Set<UITouch>) {
        guard !touches.isEmpty else { return }
        requestResponderRecovery(.interaction)
        if let touch = touches.first, activePencilTouchID == nil {
            activePencilTouchID = ObjectIdentifier(touch)
            beginPencilInteraction(for: touch)
        }
    }

    func handlePencilTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard !touches.isEmpty else { return }
        guard let activePencilTouchID else { return }
        if let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            updatePencilInteraction(for: touch, event: event)
        }
    }

    func handlePencilTouchesEnded(_ touches: Set<UITouch>) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            endPencilInteraction(for: touch)
        }
    }

    func handlePencilTouchesCancelled(_ touches: Set<UITouch>) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            cancelPencilInteraction(for: touch)
        }
    }

    func beginPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let stylus = stylusEvent(from: touch)
        let pressure = normalizedPencilPressure(for: touch)
        pencilCurrentLocation = location
        pencilCurrentStylus = stylus
        lastPencilPressure = pressure
        lastPencilMoveSampleTimestamp = touch.timestamp
        lastPencilMoveSampleLocation = location
        updatePointerLocationForLocalContact(location)

        let now = CACurrentMediaTime()
        currentClickCount = nextPrimaryClickCount(at: location, timestamp: now)
        let sample = pointerSampleForPencil(
            location: location,
            pressure: max(lastPencilPressure, 0.01),
            stylus: stylus,
            timestamp: touch.timestamp
        )
        sendPencilSampleBatch(
            phase: .began,
            modifiers: currentPencilModifiers(),
            clickCount: currentClickCount,
            isButtonPressed: true,
            samples: [sample]
        )
        pencilButtonDown = true
        isDragging = false
        lastPanLocation = location
    }

    func updatePencilInteraction(for touch: UITouch, event: UIEvent?) {
        let touches = event?.coalescedTouches(for: touch) ?? [touch]
        var batchSamples: [MiragePointerSample] = []
        var moved = false

        for sampleTouch in touches {
            let rawLocation = sampleTouch.preciseLocation(in: self)
            let location = normalizedLocation(rawLocation)
            let pressure = normalizedPencilPressure(for: sampleTouch)
            let stylus = stylusEvent(from: sampleTouch)
            guard shouldProcessPencilMoveSample(sampleTouch, location: location) else { continue }
            pencilCurrentLocation = location
            pencilCurrentStylus = stylus
            updatePointerLocationForLocalContact(location)

            guard pencilButtonDown else { continue }

            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
                moved = true
            }
            batchSamples.append(pointerSampleForPencil(
                location: location,
                pressure: pressure,
                stylus: stylus,
                timestamp: sampleTouch.timestamp
            ))
            lastPanLocation = location
        }

        guard pencilButtonDown, !batchSamples.isEmpty else { return }
        sendPencilSampleBatch(
            phase: .moved,
            modifiers: currentPencilModifiers(),
            isButtonPressed: true,
            samples: batchSamples
        )

        if moved {
            if !isDragging { resetPrimaryClickTracking() }
            revealCursorAfterPointerMovement()
            isDragging = true
        }
    }

    func shouldProcessPencilMoveSample(_ sample: UITouch, location: CGPoint) -> Bool {
        if sample.timestamp < lastPencilMoveSampleTimestamp { return false }
        if sample.timestamp == lastPencilMoveSampleTimestamp,
           lastPencilMoveSampleLocation == location {
            return false
        }
        lastPencilMoveSampleTimestamp = sample.timestamp
        lastPencilMoveSampleLocation = location
        return true
    }

    func endPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let stylus = stylusEvent(from: touch)
        pencilCurrentLocation = location
        pencilCurrentStylus = stylus
        updatePointerLocationForLocalContact(location)

        let modifiers = currentPencilModifiers()
        if pencilButtonDown {
            let sample = pointerSampleForPencil(
                location: location,
                pressure: 0,
                stylus: stylus,
                timestamp: touch.timestamp
            )
            sendPencilSampleBatch(
                phase: .ended,
                modifiers: modifiers,
                clickCount: max(1, currentClickCount),
                isButtonPressed: false,
                samples: [sample]
            )
            if !isDragging {
                commitPrimaryClick(
                    at: location,
                    timestamp: CACurrentMediaTime(),
                    clickCount: max(1, currentClickCount)
                )
            }
        }

        isDragging = false
        resetPencilGestureState()
    }

    func cancelPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let stylus = stylusEvent(from: touch)
        pencilCurrentLocation = location
        pencilCurrentStylus = stylus
        updatePointerLocationForLocalContact(location)

        if pencilButtonDown {
            let sample = pointerSampleForPencil(
                location: location,
                pressure: 0,
                stylus: stylus,
                timestamp: touch.timestamp
            )
            sendPencilSampleBatch(
                phase: .cancelled,
                modifiers: currentPencilModifiers(),
                clickCount: 1,
                isButtonPressed: false,
                samples: [sample]
            )
        }

        isDragging = false
        resetPencilGestureState()
    }

    func currentPencilModifiers() -> MirageModifierFlags {
        syncModifiersForInput()
        let snapshot = keyboardModifiers
        sendModifierSnapshotIfNeeded(snapshot)
        return snapshot
    }

    func normalizedPencilPressure(for touch: UITouch) -> CGFloat {
        let maxForce = touch.maximumPossibleForce
        if maxForce > 0 {
            let normalized = min(max(touch.force / maxForce, 0), 1)
            if normalized > 0 {
                lastPencilPressure = normalized
                return normalized
            }

            if isDragging, lastPencilPressure > 0 { return lastPencilPressure }
            return 0.01
        }

        if isDragging, lastPencilPressure > 0 { return lastPencilPressure }
        return 1
    }

    func stylusEvent(from touch: UITouch) -> MirageStylusEvent {
        let altitude = min(max(touch.altitudeAngle, 0), .pi / 2)
        let azimuth = touch.azimuthAngle(in: self)
        let azimuthUnitVector = touch.azimuthUnitVector(in: self)
        let tiltMagnitude = min(max(cos(altitude), 0), 1)
        let tiltX = min(max(azimuthUnitVector.dx * tiltMagnitude, -1), 1)
        let tiltY = min(max(azimuthUnitVector.dy * tiltMagnitude, -1), 1)
        let rollAngle: CGFloat?
        #if os(iOS)
        if #available(iOS 17.5, *) {
            rollAngle = touch.rollAngle
        } else {
            rollAngle = nil
        }
        #else
        rollAngle = nil
        #endif

        return MirageStylusEvent(
            altitudeAngle: altitude,
            azimuthAngle: azimuth,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: rollAngle
        )
    }

    func pointerSampleForPencil(
        location: CGPoint,
        pressure: CGFloat,
        stylus: MirageStylusEvent,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> MiragePointerSample {
        MiragePointerSample(
            location: location,
            pressure: min(max(pressure, 0), 1),
            stylus: stylus,
            timestamp: timestamp
        )
    }

    func sendPencilSampleBatch(
        phase: MiragePointerSampleBatchPhase,
        modifiers: MirageModifierFlags,
        clickCount: Int = 1,
        isButtonPressed: Bool,
        samples: [MiragePointerSample]
    ) {
        guard !samples.isEmpty else { return }
        let batch = MiragePointerSampleBatch(
            phase: phase,
            button: .left,
            modifiers: modifiers,
            clickCount: clickCount,
            isButtonPressed: isButtonPressed,
            samples: samples
        )
        onInputEvent?(.pointerSampleBatch(batch))
    }

}

#endif
