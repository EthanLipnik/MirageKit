//
//  MirageContinuousInputBatch.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/17/26.
//

import CoreGraphics
import Foundation

/// Compact wire representation for high-rate continuous input samples.
package struct MirageContinuousInputBatch: Equatable, Sendable {
    package enum Kind: UInt8, Sendable {
        case mouseMoved = 1
        case mouseDragged = 2
        case rightMouseDragged = 3
        case otherMouseDragged = 4
        case pointerSampleBatch = 5
        case scroll = 6
        case magnify = 7
        case rotate = 8
        case swipe = 9
    }

    package struct Sample: Equatable, Sendable {
        package let timestamp: TimeInterval
        package let location: CGPoint?
        package let valueX: CGFloat
        package let valueY: CGFloat
        package let pressure: CGFloat
        package let stylus: MirageStylusEvent?

        package init(
            timestamp: TimeInterval,
            location: CGPoint?,
            valueX: CGFloat = 0,
            valueY: CGFloat = 0,
            pressure: CGFloat = 1,
            stylus: MirageStylusEvent? = nil
        ) {
            self.timestamp = timestamp
            self.location = location
            self.valueX = valueX
            self.valueY = valueY
            self.pressure = pressure
            self.stylus = stylus
        }
    }

    package static let maximumSamplesPerPacket = 16

    package let streamID: StreamID
    package let sequence: UInt64
    package let kind: Kind
    package let pointerPhase: MiragePointerSampleBatchPhase?
    package let scrollPhase: MirageScrollPhase
    package let momentumPhase: MirageScrollPhase
    package let button: MirageMouseButton
    package let modifiers: MirageModifierFlags
    package let clickCount: Int
    package let isButtonPressed: Bool
    package let isPrecise: Bool
    package let baseTimestamp: TimeInterval
    package let samples: [Sample]

    package init(
        streamID: StreamID,
        sequence: UInt64 = 0,
        kind: Kind,
        pointerPhase: MiragePointerSampleBatchPhase? = nil,
        scrollPhase: MirageScrollPhase = .none,
        momentumPhase: MirageScrollPhase = .none,
        button: MirageMouseButton = .left,
        modifiers: MirageModifierFlags = [],
        clickCount: Int = 0,
        isButtonPressed: Bool = false,
        isPrecise: Bool = false,
        samples: [Sample]
    ) {
        self.streamID = streamID
        self.sequence = sequence
        self.kind = kind
        self.pointerPhase = pointerPhase
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.button = button
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.isButtonPressed = isButtonPressed
        self.isPrecise = isPrecise
        self.samples = samples
        baseTimestamp = samples.first?.timestamp ?? Date.timeIntervalSinceReferenceDate
    }

    package var isPencilContactBatch: Bool {
        kind == .pointerSampleBatch && pointerPhase != .hover
    }

    package var isEmpty: Bool {
        samples.isEmpty
    }

    package func withSequence(_ sequence: UInt64) -> MirageContinuousInputBatch {
        MirageContinuousInputBatch(
            streamID: streamID,
            sequence: sequence,
            kind: kind,
            pointerPhase: pointerPhase,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            button: button,
            modifiers: modifiers,
            clickCount: clickCount,
            isButtonPressed: isButtonPressed,
            isPrecise: isPrecise,
            samples: samples
        )
    }

    package func canAppend(_ other: MirageContinuousInputBatch) -> Bool {
        streamID == other.streamID &&
            kind == other.kind &&
            pointerPhase == other.pointerPhase &&
            scrollPhase == other.scrollPhase &&
            momentumPhase == other.momentumPhase &&
            button == other.button &&
            modifiers == other.modifiers &&
            clickCount == other.clickCount &&
            isButtonPressed == other.isButtonPressed &&
            isPrecise == other.isPrecise &&
            samples.count + other.samples.count <= Self.maximumSamplesPerPacket
    }

    package func appending(_ other: MirageContinuousInputBatch) -> MirageContinuousInputBatch? {
        guard canAppend(other) else { return nil }
        return MirageContinuousInputBatch(
            streamID: streamID,
            sequence: sequence,
            kind: kind,
            pointerPhase: pointerPhase,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            button: button,
            modifiers: modifiers,
            clickCount: clickCount,
            isButtonPressed: isButtonPressed,
            isPrecise: isPrecise,
            samples: samples + other.samples
        )
    }

    package func split(maxSamples: Int = maximumSamplesPerPacket) -> [MirageContinuousInputBatch] {
        let maxSamples = max(1, maxSamples)
        guard samples.count > maxSamples else { return [self] }
        var batches: [MirageContinuousInputBatch] = []
        batches.reserveCapacity((samples.count + maxSamples - 1) / maxSamples)
        var index = 0
        while index < samples.count {
            let end = Swift.min(index + maxSamples, samples.count)
            batches.append(MirageContinuousInputBatch(
                streamID: streamID,
                sequence: sequence,
                kind: kind,
                pointerPhase: pointerPhase,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                button: button,
                modifiers: modifiers,
                clickCount: clickCount,
                isButtonPressed: isButtonPressed,
                isPrecise: isPrecise,
                samples: Array(samples[index ..< end])
            ))
            index = end
        }
        return batches
    }

    package static func batches(
        from event: MirageInputEvent,
        streamID: StreamID
    ) -> [MirageContinuousInputBatch]? {
        switch event {
        case let .mouseMoved(event):
            return [mouseBatch(streamID: streamID, kind: .mouseMoved, event: event, isButtonPressed: false)]
        case let .mouseDragged(event):
            return [mouseBatch(streamID: streamID, kind: .mouseDragged, event: event, isButtonPressed: true)]
        case let .rightMouseDragged(event):
            return [mouseBatch(streamID: streamID, kind: .rightMouseDragged, event: event, isButtonPressed: true)]
        case let .otherMouseDragged(event):
            return [mouseBatch(streamID: streamID, kind: .otherMouseDragged, event: event, isButtonPressed: true)]
        case let .pointerSampleBatch(batch):
            guard batch.phase == .moved || batch.phase == .hover else { return nil }
            let samples = batch.samples.map {
                Sample(
                    timestamp: $0.timestamp,
                    location: $0.location,
                    pressure: $0.pressure,
                    stylus: $0.stylus
                )
            }
            return MirageContinuousInputBatch(
                streamID: streamID,
                kind: .pointerSampleBatch,
                pointerPhase: batch.phase,
                button: batch.button,
                modifiers: batch.modifiers,
                clickCount: batch.clickCount,
                isButtonPressed: batch.isButtonPressed,
                samples: samples
            ).split()
        case let .scrollWheel(event):
            guard !event.isBoundaryScrollEvent else { return nil }
            return [MirageContinuousInputBatch(
                streamID: streamID,
                kind: .scroll,
                scrollPhase: event.phase,
                momentumPhase: event.momentumPhase,
                modifiers: event.modifiers,
                isPrecise: event.isPrecise,
                samples: [
                    Sample(
                        timestamp: event.timestamp,
                        location: event.location,
                        valueX: event.deltaX,
                        valueY: event.deltaY,
                        pressure: 0
                    ),
                ]
            )]
        case let .magnify(event):
            guard event.phase == .none || event.phase == .changed else { return nil }
            return [MirageContinuousInputBatch(
                streamID: streamID,
                kind: .magnify,
                scrollPhase: event.phase,
                modifiers: event.modifiers,
                samples: [
                    Sample(
                        timestamp: event.timestamp,
                        location: event.location,
                        valueX: event.magnification,
                        pressure: 0
                    ),
                ]
            )]
        case let .rotate(event):
            guard event.phase == .none || event.phase == .changed else { return nil }
            return [MirageContinuousInputBatch(
                streamID: streamID,
                kind: .rotate,
                scrollPhase: event.phase,
                modifiers: event.modifiers,
                samples: [
                    Sample(
                        timestamp: event.timestamp,
                        location: event.location,
                        valueX: event.rotation,
                        pressure: 0
                    ),
                ]
            )]
        case let .swipe(event):
            guard event.phase == .none || event.phase == .changed else { return nil }
            return [MirageContinuousInputBatch(
                streamID: streamID,
                kind: .swipe,
                scrollPhase: event.phase,
                modifiers: event.modifiers,
                samples: [
                    Sample(
                        timestamp: event.timestamp,
                        location: event.location,
                        valueX: event.deltaX,
                        valueY: event.deltaY,
                        pressure: 0
                    ),
                ]
            )]
        default:
            return nil
        }
    }

    package func inputEvents() -> [MirageInputEvent] {
        switch kind {
        case .mouseMoved:
            return samples.compactMap { sample in
                guard let location = sample.location else { return nil }
                return .mouseMoved(mouseEvent(from: sample, location: location))
            }
        case .mouseDragged:
            return samples.compactMap { sample in
                guard let location = sample.location else { return nil }
                return .mouseDragged(mouseEvent(from: sample, location: location))
            }
        case .rightMouseDragged:
            return samples.compactMap { sample in
                guard let location = sample.location else { return nil }
                return .rightMouseDragged(mouseEvent(from: sample, location: location))
            }
        case .otherMouseDragged:
            return samples.compactMap { sample in
                guard let location = sample.location else { return nil }
                return .otherMouseDragged(mouseEvent(from: sample, location: location))
            }
        case .pointerSampleBatch:
            let pointerSamples = samples.compactMap { sample -> MiragePointerSample? in
                guard let location = sample.location,
                      let stylus = sample.stylus else {
                    return nil
                }
                return MiragePointerSample(
                    location: location,
                    pressure: sample.pressure,
                    stylus: stylus,
                    timestamp: sample.timestamp
                )
            }
            guard !pointerSamples.isEmpty else { return [] }
            return [
                .pointerSampleBatch(MiragePointerSampleBatch(
                    phase: pointerPhase ?? .moved,
                    button: button,
                    modifiers: modifiers,
                    clickCount: clickCount,
                    isButtonPressed: isButtonPressed,
                    samples: pointerSamples,
                    timestamp: baseTimestamp
                )),
            ]
        case .scroll:
            return samples.map {
                .scrollWheel(MirageScrollEvent(
                    deltaX: $0.valueX,
                    deltaY: $0.valueY,
                    location: $0.location,
                    phase: scrollPhase,
                    momentumPhase: momentumPhase,
                    modifiers: modifiers,
                    isPrecise: isPrecise,
                    timestamp: $0.timestamp
                ))
            }
        case .magnify:
            return samples.map {
                .magnify(MirageMagnifyEvent(
                    magnification: $0.valueX,
                    location: $0.location,
                    phase: scrollPhase,
                    modifiers: modifiers,
                    timestamp: $0.timestamp
                ))
            }
        case .rotate:
            return samples.map {
                .rotate(MirageRotateEvent(
                    rotation: $0.valueX,
                    location: $0.location,
                    phase: scrollPhase,
                    modifiers: modifiers,
                    timestamp: $0.timestamp
                ))
            }
        case .swipe:
            return samples.map {
                .swipe(MirageSwipeEvent(
                    deltaX: $0.valueX,
                    deltaY: $0.valueY,
                    location: $0.location,
                    phase: scrollPhase,
                    modifiers: modifiers,
                    timestamp: $0.timestamp
                ))
            }
        }
    }

    private static func mouseBatch(
        streamID: StreamID,
        kind: Kind,
        event: MirageMouseEvent,
        isButtonPressed: Bool
    ) -> MirageContinuousInputBatch {
        MirageContinuousInputBatch(
            streamID: streamID,
            kind: kind,
            button: event.button,
            modifiers: event.modifiers,
            clickCount: event.clickCount,
            isButtonPressed: isButtonPressed,
            samples: [
                Sample(
                    timestamp: event.timestamp,
                    location: event.location,
                    pressure: event.pressure,
                    stylus: event.stylus
                ),
            ]
        )
    }

    private func mouseEvent(from sample: Sample, location: CGPoint) -> MirageMouseEvent {
        MirageMouseEvent(
            button: button,
            location: location,
            clickCount: clickCount,
            modifiers: modifiers,
            pressure: sample.pressure,
            stylus: sample.stylus,
            timestamp: sample.timestamp
        )
    }
}
