//
//  HostScrollEventFactoryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import AppKit
import CoreGraphics
import MirageKit
import Testing
import MirageInput

@Suite("Host Scroll Event Factory")
struct HostScrollEventFactoryTests {
    @Test("Native precise scroll events expose AppKit scrolling deltas")
    func nativePreciseScrollEventsExposeAppKitScrollingDeltas() throws {
        let event = MirageInput.MirageScrollEvent(
            deltaX: -2.5,
            deltaY: 4.75,
            phase: .changed,
            momentumPhase: .changed,
            isPrecise: true
        )

        let cgEvent = try #require(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: -2,
            integerDeltaY: 4
        ))
        let nsEvent = try #require(NSEvent(cgEvent: cgEvent))

        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 4)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -2)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.changed.rawValue))
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventMomentumPhase) == Int64(CGMomentumScrollPhase.continuous.rawValue))
        #expect(nsEvent.hasPreciseScrollingDeltas)
        #expect(nsEvent.scrollingDeltaY == 4)
        #expect(nsEvent.scrollingDeltaX == -2)
    }

    @Test("Native sub-pixel scroll events preserve phase while waiting for integer movement")
    func nativeSubPixelScrollEventsPreservePhaseWhileWaitingForIntegerMovement() throws {
        let event = MirageInput.MirageScrollEvent(
            deltaX: 0.25,
            deltaY: -0.5,
            phase: .changed,
            isPrecise: true
        )

        let cgEvent = try #require(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: 0,
            integerDeltaY: 0
        ))
        let nsEvent = try #require(NSEvent(cgEvent: cgEvent))

        #expect(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.changed.rawValue))
        #expect(nsEvent.scrollingDeltaY == 0)
        #expect(nsEvent.scrollingDeltaX == 0)
    }

    @Test("Phase-less precise scroll events keep constructor movement fields")
    func phaseLessPreciseScrollEventsKeepConstructorMovementFields() throws {
        let event = MirageInput.MirageScrollEvent(
            deltaX: -2.5,
            deltaY: 4.75,
            isPrecise: true
        )

        let cgEvent = try #require(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: -2,
            integerDeltaY: 4
        ))
        let nsEvent = try #require(NSEvent(cgEvent: cgEvent))

        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 4)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -2)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase) == 0)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
        #expect(nsEvent.scrollingDeltaY == 4)
        #expect(nsEvent.scrollingDeltaX == -2)
    }

    @Test("Phase-less precise sub-pixel scroll events wait for integer fallback")
    func phaseLessPreciseSubPixelScrollEventsWaitForIntegerFallback() {
        let event = MirageInput.MirageScrollEvent(
            deltaX: 0.25,
            deltaY: -0.5,
            isPrecise: true
        )

        #expect(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: 0,
            integerDeltaY: 0
        ) == nil)
    }

    @Test("Boundary phase scroll events are preserved without movement")
    func boundaryPhaseScrollEventsArePreservedWithoutMovement() throws {
        let event = MirageInput.MirageScrollEvent(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            momentumPhase: .ended,
            isPrecise: true
        )

        let cgEvent = try #require(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: 0,
            integerDeltaY: 0
        ))

        #expect(cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.ended.rawValue))
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventMomentumPhase) == Int64(CGMomentumScrollPhase.end.rawValue))
    }

    @Test("Integer fallback accumulation keeps horizontal and vertical scrolling")
    func integerFallbackAccumulationKeepsHorizontalAndVerticalScrolling() {
        var horizontalRemainder: CGFloat = 0
        var verticalRemainder: CGFloat = 0

        let firstHorizontal = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: 0.6,
            remainder: &horizontalRemainder
        )
        let firstVertical = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: -1.4,
            remainder: &verticalRemainder
        )
        let secondHorizontal = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: 0.6,
            remainder: &horizontalRemainder
        )
        let secondVertical = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: -0.8,
            remainder: &verticalRemainder
        )

        #expect(firstHorizontal == 0)
        #expect(firstVertical == -1)
        #expect(secondHorizontal == 1)
        #expect(secondVertical == -1)
        #expect(abs(horizontalRemainder - 0.2) < 0.000001)
        #expect(abs(verticalRemainder + 0.2) < 0.000001)
    }
}
#endif
