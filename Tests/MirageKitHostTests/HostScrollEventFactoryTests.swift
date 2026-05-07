//
//  HostScrollEventFactoryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

#if os(macOS)
@Suite("Host Scroll Event Factory")
struct HostScrollEventFactoryTests {
    @Test("Precise scroll events carry continuous metadata and both axis deltas")
    func preciseScrollEventCarriesContinuousMetadataAndBothAxisDeltas() throws {
        let event = MirageScrollEvent(
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

        #expect(cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == 4.75)
        #expect(cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == -2.5)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 4)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -2)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.changed.rawValue))
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventMomentumPhase) == Int64(CGMomentumScrollPhase.continuous.rawValue))
    }

    @Test("Precise sub-pixel scroll events are preserved")
    func preciseSubPixelScrollEventsArePreserved() throws {
        let event = MirageScrollEvent(
            deltaX: 0.25,
            deltaY: -0.5,
            isPrecise: true
        )

        let cgEvent = try #require(MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: 0,
            integerDeltaY: 0
        ))

        #expect(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        #expect(cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -0.5)
        #expect(cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0.25)
    }

    @Test("Boundary phase scroll events are preserved without movement")
    func boundaryPhaseScrollEventsArePreservedWithoutMovement() throws {
        let event = MirageScrollEvent(
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
