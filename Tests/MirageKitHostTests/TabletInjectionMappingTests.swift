//
//  TabletInjectionMappingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Host tablet-field injection coverage for stylus-backed mouse events.
//

@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Testing

@Suite("Tablet Injection Mapping")
struct TabletInjectionMappingTests {
    @Test("Stylus events apply tablet subtype and fields")
    func stylusEventAppliesTabletFields() throws {
        let controller = MirageHostInputController()
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )

        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 6,
            tiltX: 0.3,
            tiltY: -0.25
        )
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.5, y: 0.5),
            pressure: 0.72,
            stylus: stylus
        )

        controller.applyTabletFieldsIfNeeded(cgEvent, from: mouseEvent)

        #expect(controller.appliesTabletSubtype(mouseEvent))
        #expect(cgEvent.getIntegerValueField(.mouseEventSubtype) == Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        #expect(abs(cgEvent.getDoubleValueField(.mouseEventPressure) - 0.72) < 0.02)
        #expect(abs(cgEvent.getDoubleValueField(.tabletEventPointPressure) - 0.72) < 0.02)
        #expect(abs(cgEvent.getDoubleValueField(.tabletEventTiltX) - 0.3) < 0.02)
        #expect(abs(cgEvent.getDoubleValueField(.tabletEventTiltY) - (-0.25)) < 0.02)
    }

    @Test("Non-stylus events do not apply tablet subtype")
    func nonStylusEventLeavesTabletSubtypeDefault() throws {
        let controller = MirageHostInputController()
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )

        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.1, y: 0.2),
            pressure: 1.0
        )

        controller.applyTabletFieldsIfNeeded(cgEvent, from: mouseEvent)

        #expect(!controller.appliesTabletSubtype(mouseEvent))
        #expect(cgEvent.getIntegerValueField(.mouseEventSubtype) == 0)
    }

    @Test("Tablet pointer events are created as tablet event types")
    func tabletPointerEventCreationUsesTabletType() throws {
        let controller = MirageHostInputController()
        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 6,
            tiltX: 0.2,
            tiltY: 0.1
        )
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.5, y: 0.5),
            pressure: 0.66,
            stylus: stylus
        )

        let tabletEvent = try #require(
            controller.makeTabletPointerEvent(
                from: mouseEvent,
                stylus: stylus,
                type: .leftMouseDragged,
                at: CGPoint(x: 300, y: 200)
            )
        )

        #expect(tabletEvent.type == .tabletPointer)
        #expect(abs(tabletEvent.getDoubleValueField(.tabletEventPointPressure) - 0.66) < 0.02)
        #expect(tabletEvent.getIntegerValueField(.tabletEventPointButtons) == 1)
    }

    @Test("Pointer sample batches create tablet pointer events without mouse subtype path")
    func pointerSampleBatchCreatesTabletPointerEvent() throws {
        let controller = MirageHostInputController()
        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 6,
            tiltX: -0.2,
            tiltY: 0.35
        )
        let sample = MiragePointerSample(
            location: CGPoint(x: 0.2, y: 0.8),
            pressure: 0.55,
            stylus: stylus,
            timestamp: 2
        )
        let batch = MiragePointerSampleBatch(
            phase: .moved,
            modifiers: [.shift],
            clickCount: 1,
            isButtonPressed: true,
            samples: [sample],
            timestamp: 2
        )

        let tabletEvent = try #require(
            controller.makeTabletPointerEvent(
                from: sample,
                batch: batch,
                type: MirageHostInputController.pointerEventType(for: batch),
                at: CGPoint(x: 640, y: 480)
            )
        )

        #expect(tabletEvent.type == .tabletPointer)
        #expect(abs(tabletEvent.getDoubleValueField(.tabletEventPointPressure) - 0.55) < 0.02)
        #expect(tabletEvent.getIntegerValueField(.tabletEventPointButtons) == 1)
        #expect(tabletEvent.getIntegerValueField(.tabletEventPointX) == 640)
        #expect(tabletEvent.getIntegerValueField(.tabletEventPointY) == 480)
    }

    @Test("Ended and cancelled batches map to button release")
    func pointerSampleBatchBoundaryPhasesMapToRelease() {
        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 6,
            tiltX: 0,
            tiltY: 0
        )
        let sample = MiragePointerSample(
            location: .zero,
            pressure: 0,
            stylus: stylus
        )
        let ended = MiragePointerSampleBatch(
            phase: .ended,
            isButtonPressed: false,
            samples: [sample]
        )
        let cancelled = MiragePointerSampleBatch(
            phase: .cancelled,
            isButtonPressed: false,
            samples: [sample]
        )

        #expect(MirageHostInputController.pointerEventType(for: ended) == .leftMouseUp)
        #expect(MirageHostInputController.pointerEventType(for: cancelled) == .leftMouseUp)
    }

    @Test("Tablet proximity events are created as tablet proximity types")
    func tabletProximityEventCreationUsesTabletType() throws {
        let controller = MirageHostInputController()
        let enteringEvent = try #require(controller.makeTabletProximityEvent(entering: true, at: CGPoint(x: 0, y: 0)))
        let leavingEvent = try #require(controller.makeTabletProximityEvent(entering: false, at: CGPoint(x: 0, y: 0)))

        #expect(enteringEvent.type == .tabletProximity)
        #expect(enteringEvent.getIntegerValueField(.tabletProximityEventEnterProximity) == 1)
        #expect(leavingEvent.type == .tabletProximity)
        #expect(leavingEvent.getIntegerValueField(.tabletProximityEventEnterProximity) == 0)
    }
}
