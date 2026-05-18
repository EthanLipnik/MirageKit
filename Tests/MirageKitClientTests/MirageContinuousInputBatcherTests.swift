//
//  MirageContinuousInputBatcherTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/17/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing

@Suite("Continuous Input Batcher")
struct MirageContinuousInputBatcherTests {
    @Test("Pencil contact samples are emitted in order without trimming")
    func pencilContactSamplesAreEmittedInOrderWithoutTrimming() {
        let batcher = MirageContinuousInputBatcher()
        let streamID: StreamID = 51
        let samples = (0 ..< 80).map { index in
            MiragePointerSample(
                location: CGPoint(x: CGFloat(index), y: 0.5),
                pressure: 0.5,
                stylus: makeStylus(),
                timestamp: TimeInterval(index)
            )
        }

        let accepted = batcher.enqueue(.pointerSampleBatch(MiragePointerSampleBatch(
            phase: .moved,
            isButtonPressed: true,
            samples: samples
        )), streamID: streamID)

        let flushedSamples = batcher.flush().flatMap { $0.inputEvents() }.flatMap { event -> [MiragePointerSample] in
            guard case let .pointerSampleBatch(batch) = event else { return [] }
            return batch.samples
        }
        #expect(accepted)
        #expect(flushedSamples.map(\.location.x) == (0 ..< 80).map(CGFloat.init))
        #expect(batcher.droppedNonPencilSamples == 0)
    }

    @Test("Non-Pencil continuous overload keeps a tiny latest ring")
    func nonPencilContinuousOverloadKeepsTinyLatestRing() {
        let batcher = MirageContinuousInputBatcher()
        let streamID: StreamID = 52

        for index in 0 ..< 80 {
            _ = batcher.enqueue(.mouseMoved(MirageMouseEvent(
                location: CGPoint(x: CGFloat(index), y: 0.5),
                timestamp: TimeInterval(index)
            )), streamID: streamID)
        }

        let timestamps = batcher.flush().flatMap { $0.inputEvents() }.compactMap { event -> TimeInterval? in
            guard case let .mouseMoved(mouseEvent) = event else { return nil }
            return mouseEvent.timestamp
        }
        #expect(timestamps == (16 ..< 80).map(TimeInterval.init))
        #expect(batcher.droppedNonPencilSamples == 16)
    }

    @Test("Full packets request immediate flush")
    func fullPacketsRequestImmediateFlush() {
        let batcher = MirageContinuousInputBatcher()

        for index in 0 ..< MirageContinuousInputBatch.maximumSamplesPerPacket {
            _ = batcher.enqueue(.mouseMoved(MirageMouseEvent(
                location: CGPoint(x: CGFloat(index), y: 0.5),
                timestamp: TimeInterval(index)
            )), streamID: 53)
        }

        #expect(batcher.hasFullPacket)
    }

    @Test("Discrete pointer boundary is not accepted by continuous batcher")
    func discretePointerBoundaryIsNotAcceptedByContinuousBatcher() {
        let batcher = MirageContinuousInputBatcher()
        let event = MirageInputEvent.pointerSampleBatch(MiragePointerSampleBatch(
            phase: .began,
            isButtonPressed: true,
            samples: [
                MiragePointerSample(
                    location: CGPoint(x: 0.5, y: 0.5),
                    pressure: 0.5,
                    stylus: makeStylus()
                ),
            ]
        ))

        #expect(!batcher.enqueue(event, streamID: 54))
        #expect(batcher.isEmpty)
    }
}

private func makeStylus() -> MirageStylusEvent {
    MirageStylusEvent(
        altitudeAngle: 0.7,
        azimuthAngle: 0.2,
        tiltX: 0.1,
        tiltY: 0.2,
        isHovering: false
    )
}
#endif
