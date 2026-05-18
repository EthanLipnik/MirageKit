//
//  ContinuousInputBatchCodecTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/17/26.
//

@testable import MirageKit
import CoreGraphics
import Foundation
import Testing

@Suite("Continuous Input Batch Codec")
struct ContinuousInputBatchCodecTests {
    @Test("Mouse movement batch round trips through compact codec")
    func mouseMovementBatchRoundTripsThroughCompactCodec() throws {
        let event = MirageInputEvent.mouseMoved(MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.25, y: 0.75),
            modifiers: .shift,
            timestamp: 10
        ))
        let batch = try #require(MirageContinuousInputBatch.batches(from: event, streamID: 7)?.first)

        let decoded = try MirageContinuousInputBatch.deserialize(batch.withSequence(42).serialize())
        let decodedEvent = try #require(decoded.inputEvents().first)

        #expect(decoded.streamID == 7)
        #expect(decoded.sequence == 42)
        #expect(decoded.kind == .mouseMoved)
        guard case let .mouseMoved(mouseEvent) = decodedEvent else {
            Issue.record("Expected decoded mouse movement")
            return
        }
        #expect(approximatelyEqual(mouseEvent.location.x, 0.25))
        #expect(approximatelyEqual(mouseEvent.location.y, 0.75))
        #expect(mouseEvent.modifiers == .shift)
        #expect(approximatelyEqual(mouseEvent.timestamp, 10))
    }

    @Test("Pencil contact samples preserve order and stylus fields")
    func pencilContactSamplesPreserveOrderAndStylusFields() throws {
        let firstStylus = makeStylus(altitude: 0.7, azimuth: 0.2, hovering: false)
        let secondStylus = makeStylus(altitude: 0.8, azimuth: 0.3, hovering: false)
        let event = MirageInputEvent.pointerSampleBatch(MiragePointerSampleBatch(
            phase: .moved,
            modifiers: .command,
            clickCount: 1,
            isButtonPressed: true,
            samples: [
                MiragePointerSample(
                    location: CGPoint(x: 0.1, y: 0.2),
                    pressure: 0.4,
                    stylus: firstStylus,
                    timestamp: 20
                ),
                MiragePointerSample(
                    location: CGPoint(x: 0.3, y: 0.4),
                    pressure: 0.6,
                    stylus: secondStylus,
                    timestamp: 20.001
                ),
            ],
            timestamp: 20
        ))
        let batch = try #require(MirageContinuousInputBatch.batches(from: event, streamID: 9)?.first)

        let decoded = try MirageContinuousInputBatch.deserialize(batch.serialize())
        let decodedEvent = try #require(decoded.inputEvents().first)

        #expect(decoded.isPencilContactBatch)
        guard case let .pointerSampleBatch(pointerBatch) = decodedEvent else {
            Issue.record("Expected decoded pointer batch")
            return
        }
        #expect(pointerBatch.samples.count == 2)
        #expect(pointerBatch.phase == .moved)
        #expect(pointerBatch.modifiers == .command)
        #expect(approximatelyEqual(pointerBatch.samples[0].location.x, 0.1))
        #expect(approximatelyEqual(pointerBatch.samples[1].location.x, 0.3))
        #expect(approximatelyEqual(pointerBatch.samples[0].pressure, 0.4))
        #expect(approximatelyEqual(pointerBatch.samples[1].stylus.altitudeAngle, 0.8))
        #expect(approximatelyEqual(pointerBatch.samples[1].stylus.azimuthAngle, 0.3))
    }

    @Test("Scroll and gesture continuous events round trip")
    func scrollAndGestureContinuousEventsRoundTrip() throws {
        let location = CGPoint(x: 0.4, y: 0.6)
        let events: [MirageInputEvent] = [
            .scrollWheel(MirageScrollEvent(
                deltaX: 1.25,
                deltaY: -2.5,
                location: location,
                phase: .changed,
                momentumPhase: .none,
                modifiers: .option,
                isPrecise: true,
                timestamp: 30
            )),
            .magnify(MirageMagnifyEvent(
                magnification: 0.125,
                location: location,
                phase: .changed,
                modifiers: .control,
                timestamp: 31
            )),
            .rotate(MirageRotateEvent(
                rotation: 12.5,
                location: location,
                phase: .changed,
                modifiers: .shift,
                timestamp: 32
            )),
            .swipe(MirageSwipeEvent(
                deltaX: -3,
                deltaY: 4,
                location: location,
                phase: .changed,
                modifiers: .command,
                timestamp: 33
            )),
        ]

        let decodedEvents = try events.map { event -> MirageInputEvent in
            let batch = try #require(MirageContinuousInputBatch.batches(from: event, streamID: 12)?.first)
            return try #require(MirageContinuousInputBatch.deserialize(batch.serialize()).inputEvents().first)
        }

        guard case let .scrollWheel(scrollEvent) = decodedEvents[0] else {
            Issue.record("Expected scroll event")
            return
        }
        #expect(approximatelyEqual(scrollEvent.deltaX, 1.25))
        #expect(approximatelyEqual(scrollEvent.deltaY, -2.5))
        #expect(scrollEvent.phase == .changed)
        #expect(scrollEvent.isPrecise)

        guard case let .magnify(magnifyEvent) = decodedEvents[1],
              case let .rotate(rotateEvent) = decodedEvents[2],
              case let .swipe(swipeEvent) = decodedEvents[3] else {
            Issue.record("Expected decoded gesture events")
            return
        }
        #expect(approximatelyEqual(magnifyEvent.magnification, 0.125))
        #expect(approximatelyEqual(rotateEvent.rotation, 12.5))
        #expect(approximatelyEqual(swipeEvent.deltaX, -3))
        #expect(approximatelyEqual(swipeEvent.deltaY, 4))
    }

    @Test("Discrete pointer and scroll boundaries do not become continuous batches")
    func discretePointerAndScrollBoundariesDoNotBecomeContinuousBatches() {
        let pointerBegan = MirageInputEvent.pointerSampleBatch(MiragePointerSampleBatch(
            phase: .began,
            isButtonPressed: true,
            samples: [
                MiragePointerSample(
                    location: CGPoint(x: 0.5, y: 0.5),
                    pressure: 0.5,
                    stylus: makeStylus(altitude: 0.7, azimuth: 0.2, hovering: false)
                ),
            ]
        ))
        let scrollEnded = MirageInputEvent.scrollWheel(MirageScrollEvent(
            deltaX: 0,
            deltaY: 0,
            phase: .ended
        ))

        #expect(MirageContinuousInputBatch.batches(from: pointerBegan, streamID: 1) == nil)
        #expect(MirageContinuousInputBatch.batches(from: scrollEnded, streamID: 1) == nil)
    }
}

private func makeStylus(
    altitude: CGFloat,
    azimuth: CGFloat,
    hovering: Bool
) -> MirageStylusEvent {
    MirageStylusEvent(
        altitudeAngle: altitude,
        azimuthAngle: azimuth,
        tiltX: 0.1,
        tiltY: -0.2,
        rollAngle: 0.25,
        zOffset: hovering ? 0.05 : nil,
        isHovering: hovering
    )
}

private func approximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.0001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func approximatelyEqual(
    _ lhs: TimeInterval,
    _ rhs: TimeInterval,
    tolerance: TimeInterval = 0.0001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}
