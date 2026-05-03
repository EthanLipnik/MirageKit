//
//  MirageHostInputController+Tablet.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Tablet field mapping for stylus-backed pointer events.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Tablet Mapping Helpers

    func appliesTabletSubtype(_ event: MirageMouseEvent) -> Bool {
        event.stylus != nil
    }

    func applyTabletFieldsIfNeeded(
        _ cgEvent: CGEvent,
        from event: MirageMouseEvent,
        type: CGEventType? = nil,
        point: CGPoint? = nil
    ) {
        guard let stylus = event.stylus else { return }
        let pointerButtons: Int64?
        if let type {
            pointerButtons = isPointerButtonActive(for: type) ? tabletButtonMask(for: event.button) : 0
        } else {
            pointerButtons = nil
        }
        applyTabletFields(
            cgEvent,
            from: event,
            stylus: stylus,
            point: point,
            pointerButtons: pointerButtons
        )
    }

    func postStylusAwarePointerEvent(
        _ cgEvent: CGEvent,
        from event: MirageMouseEvent,
        type: CGEventType,
        at screenPoint: CGPoint
    ) {
        if let stylus = event.stylus {
            postTabletProximityIfNeeded(entering: true, at: screenPoint)
            postTabletPointerEvent(from: event, stylus: stylus, type: type, at: screenPoint)
            if isPointerButtonRelease(for: type) {
                postTabletProximityIfNeeded(entering: false, at: screenPoint)
            }
        } else {
            postTabletProximityIfNeeded(entering: false, at: screenPoint)
            postEvent(cgEvent)
        }
    }

    private func applyTabletFields(
        _ cgEvent: CGEvent,
        from event: MirageMouseEvent,
        stylus: MirageStylusEvent,
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
        cgEvent.setIntegerValueField(.tabletEventDeviceID, value: syntheticTabletDeviceID)
    }

    private func postTabletPointerEvent(
        from event: MirageMouseEvent,
        stylus: MirageStylusEvent,
        type: CGEventType,
        at screenPoint: CGPoint
    ) {
        guard let tabletEvent = makeTabletPointerEvent(
            from: event,
            stylus: stylus,
            type: type,
            at: screenPoint
        ) else { return }
        postEvent(tabletEvent)
    }

    func postTabletPointerSample(
        _ sample: MiragePointerSample,
        batch: MiragePointerSampleBatch,
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

    func makeTabletPointerEvent(
        from event: MirageMouseEvent,
        stylus: MirageStylusEvent,
        type: CGEventType,
        at screenPoint: CGPoint
    ) -> CGEvent? {
        guard let tabletEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: screenPoint,
            mouseButton: event.button.cgMouseButton
        ) else {
            return nil
        }

        tabletEvent.type = .tabletPointer
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

    func makeTabletPointerEvent(
        from sample: MiragePointerSample,
        batch: MiragePointerSampleBatch,
        type: CGEventType,
        at screenPoint: CGPoint
    ) -> CGEvent? {
        let event = MirageMouseEvent(
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

    func postTabletProximityIfNeeded(entering: Bool, at screenPoint: CGPoint) {
        guard tabletProximityActive != entering else { return }
        guard let proximityEvent = makeTabletProximityEvent(entering: entering, at: screenPoint) else { return }

        postEvent(proximityEvent)
        tabletProximityActive = entering
    }

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
        proximityEvent.setIntegerValueField(.tabletProximityEventPointerType, value: syntheticTabletPointerType)
        proximityEvent.setIntegerValueField(.tabletProximityEventPointerID, value: syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventDeviceID, value: syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventSystemTabletID, value: syntheticTabletDeviceID)
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorID, value: syntheticTabletVendorID)
        proximityEvent.setIntegerValueField(.tabletProximityEventTabletID, value: syntheticTabletProductID)
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorPointerType, value: syntheticTabletPointerType)
        proximityEvent.setIntegerValueField(
            .tabletProximityEventVendorPointerSerialNumber,
            value: syntheticTabletPointerSerialNumber
        )
        proximityEvent.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: syntheticTabletUniqueID)
        proximityEvent.setIntegerValueField(.tabletProximityEventCapabilityMask, value: syntheticTabletCapabilityMask)
        return proximityEvent
    }

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

    private func isPointerButtonRelease(for type: CGEventType) -> Bool {
        switch type {
        case .leftMouseUp,
             .rightMouseUp,
             .otherMouseUp:
            true
        default:
            false
        }
    }

    private func tabletButtonMask(for button: MirageMouseButton) -> Int64 {
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

    private var syntheticTabletDeviceID: Int64 { 1 }
    private var syntheticTabletPointerType: Int64 { 1 }
    private var syntheticTabletVendorID: Int64 { 0x4D52 }
    private var syntheticTabletProductID: Int64 { 0x0001 }
    private var syntheticTabletPointerSerialNumber: Int64 { 1 }
    private var syntheticTabletUniqueID: Int64 { 0x4D4952414745 }
    private var syntheticTabletCapabilityMask: Int64 {
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
}

#endif
