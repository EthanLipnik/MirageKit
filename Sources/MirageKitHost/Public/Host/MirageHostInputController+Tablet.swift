//
//  MirageHostInputController+Tablet.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Tablet field mapping for stylus-backed pointer events.
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
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Tablet Mapping Helpers

    /// Returns whether a mouse event should be tagged as tablet/stylus input.
    func appliesTabletSubtype(_ event: MirageInput.MirageMouseEvent) -> Bool {
        event.stylus != nil
    }

    /// Applies tablet fields to a CoreGraphics event when the Mirage event carries stylus data.
    func applyTabletFieldsIfNeeded(
        _ cgEvent: CGEvent,
        from event: MirageInput.MirageMouseEvent,
        type: CGEventType? = nil,
        point: CGPoint? = nil
    ) {
        guard let stylus = event.stylus else { return }
        let pointerButtons: Int64? = if let type {
            isPointerButtonActive(for: type) ? tabletButtonMask(for: event.button) : 0
        } else {
            nil
        }
        applyTabletFields(
            cgEvent,
            from: event,
            stylus: stylus,
            point: point,
            pointerButtons: pointerButtons
        )
    }

    /// Posts a pointer event while maintaining synthetic tablet proximity state.
    func postStylusAwarePointerEvent(
        _ cgEvent: CGEvent,
        from event: MirageInput.MirageMouseEvent,
        type: CGEventType,
        at screenPoint: CGPoint
    ) {
        if let stylus = event.stylus {
            postTabletProximityIfNeeded(entering: true, at: screenPoint)
            applyTabletFields(
                cgEvent,
                from: event,
                stylus: stylus,
                point: screenPoint,
                pointerButtons: isPointerButtonActive(for: type) ? tabletButtonMask(for: event.button) : 0
            )
            postEvent(cgEvent)
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                postTabletProximityIfNeeded(entering: false, at: screenPoint)
            }
        } else {
            postTabletProximityIfNeeded(entering: false, at: screenPoint)
            postEvent(cgEvent)
        }
    }

    /// Applies synthetic tablet fields for pressure, tilt, rotation, position, and buttons.
    private func applyTabletFields(
        _ cgEvent: CGEvent,
        from event: MirageInput.MirageMouseEvent,
        stylus: MirageInput.MirageStylusEvent,
        point: CGPoint?,
        pointerButtons: Int64?
    ) {
        cgEvent.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        let pressure = Double(min(max(event.pressure, 0), 1))
        cgEvent.setDoubleValueField(.mouseEventPressure, value: pressure)
        cgEvent.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        cgEvent.setDoubleValueField(.tabletEventTiltX, value: Double(min(max(stylus.tiltX, -1), 1)))
        cgEvent.setDoubleValueField(.tabletEventTiltY, value: Double(min(max(stylus.tiltY, -1), 1)))
        if let rollAngle = stylus.rollAngle {
            cgEvent.setDoubleValueField(.tabletEventRotation, value: Double(rollAngle))
        }
        cgEvent.setDoubleValueField(.tabletEventTangentialPressure, value: 0)

        if let point {
            cgEvent.setIntegerValueField(.tabletEventPointX, value: Int64(point.x.rounded()))
            cgEvent.setIntegerValueField(.tabletEventPointY, value: Int64(point.y.rounded()))
        }
        if let pointerButtons {
            cgEvent.setIntegerValueField(.tabletEventPointButtons, value: pointerButtons)
        }
        cgEvent.setIntegerValueField(.tabletEventDeviceID, value: Self.syntheticTabletDeviceID)
    }

    /// Posts one batched stylus sample as a synthetic tablet pointer event.
    func postTabletPointerSample(
        _ sample: MirageInput.MiragePointerSample,
        batch: MirageInput.MiragePointerSampleBatch,
        type: CGEventType,
        at screenPoint: CGPoint
    ) {
        postTabletProximityIfNeeded(entering: true, at: screenPoint)
        guard let tabletEvent = makeTabletPointerEvent(
            from: sample,
            batch: batch,
            type: type,
            at: screenPoint
        ) else { return }
        postEvent(tabletEvent)
    }

    /// Builds a synthetic tablet pointer event from a Mirage mouse event.
    func makeTabletPointerEvent(
        from event: MirageInput.MirageMouseEvent,
        stylus: MirageInput.MirageStylusEvent,
        type: CGEventType,
        at screenPoint: CGPoint
    ) -> CGEvent? {
        guard let tabletEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: screenPoint,
            mouseButton: event.button.cgMouseButton
        ) else {
            return nil
        }

        applyPointerEventMetadata(tabletEvent, from: event, type: type)
        let pointerButtons: Int64 = isPointerButtonActive(for: type) ? tabletButtonMask(for: event.button) : 0
        applyTabletFields(
            tabletEvent,
            from: event,
            stylus: stylus,
            point: screenPoint,
            pointerButtons: pointerButtons
        )
        return tabletEvent
    }

    /// Builds a synthetic tablet pointer event from a batched pointer sample.
    func makeTabletPointerEvent(
        from sample: MirageInput.MiragePointerSample,
        batch: MirageInput.MiragePointerSampleBatch,
        type: CGEventType,
        at screenPoint: CGPoint
    ) -> CGEvent? {
        let event = MirageInput.MirageMouseEvent(
            button: batch.button,
            location: sample.location,
            clickCount: batch.clickCount,
            modifiers: batch.modifiers,
            pressure: sample.pressure,
            stylus: sample.stylus,
            timestamp: sample.timestamp
        )
        return makeTabletPointerEvent(
            from: event,
            stylus: sample.stylus,
            type: type,
            at: screenPoint
        )
    }

    /// Posts tablet proximity enter/exit events when proximity state changes.
    func postTabletProximityIfNeeded(entering: Bool, at screenPoint: CGPoint) {
        guard tabletProximityActive != entering else { return }
        guard let proximityEvent = makeTabletProximityEvent(entering: entering, at: screenPoint) else { return }

        postEvent(proximityEvent)
        tabletProximityActive = entering
    }

    /// Builds a synthetic tablet proximity event at a host screen point.
    func makeTabletProximityEvent(entering: Bool, at screenPoint: CGPoint) -> CGEvent? {
        guard let proximityEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) else {
            return nil
        }

        proximityEvent.type = .tabletProximity
        proximityEvent.setIntegerValueField(
            .mouseEventSubtype,
            value: Int64(CGEventMouseSubtype.tabletProximity.rawValue)
        )
        proximityEvent.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        proximityEvent.setIntegerValueField(.tabletProximityEventPointerType, value: Self.syntheticTabletPointerType)
        proximityEvent.setIntegerValueField(.tabletProximityEventPointerID, value: Self.syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventSystemTabletID, value: Self.syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorID, value: Self.syntheticTabletVendorID)
        proximityEvent.setIntegerValueField(.tabletProximityEventTabletID, value: Self.syntheticTabletProductID)
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorPointerType, value: Self.syntheticTabletPointerType)
        proximityEvent.setIntegerValueField(
            .tabletProximityEventVendorPointerSerialNumber,
            value: Self.syntheticTabletPointerSerialNumber
        )
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Self.syntheticTabletUniqueID)
        proximityEvent.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.syntheticTabletCapabilityMask)
        return proximityEvent
    }

    /// Returns whether a CoreGraphics pointer event has an active button state.
    private func isPointerButtonActive(for type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown,
             .leftMouseDragged,
             .rightMouseDown,
             .rightMouseDragged,
             .otherMouseDown,
             .otherMouseDragged:
            true
        default:
            false
        }
    }

    /// Maps Mirage mouse buttons to the tablet button bitmask.
    private func tabletButtonMask(for button: MirageInput.MirageMouseButton) -> Int64 {
        switch button {
        case .left:
            1 << 0
        case .right:
            1 << 1
        case .middle:
            1 << 2
        case .button3:
            1 << 3
        case .button4:
            1 << 4
        }
    }

    private static let syntheticTabletDeviceID: Int64 = 1
    private static let syntheticTabletPointerType: Int64 = 1
    private static let syntheticTabletVendorID: Int64 = 0x4D52
    private static let syntheticTabletProductID: Int64 = 0x0001
    private static let syntheticTabletPointerSerialNumber: Int64 = 1
    private static let syntheticTabletUniqueID: Int64 = 0x4D49_5241_4745
    private static let syntheticTabletCapabilityMask: Int64 =
        0x0001 | // device ID
        0x0002 | // absolute X
        0x0004 | // absolute Y
        0x0040 | // buttons
        0x0080 | // tilt X
        0x0100 | // tilt Y
        0x0400 | // pressure
        0x0800 | // tangential pressure
        0x2000 // rotation
}

#endif
