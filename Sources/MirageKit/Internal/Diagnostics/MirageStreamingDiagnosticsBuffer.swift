//
//  MirageStreamingDiagnosticsBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import Foundation

package enum MirageStreamingDiagnosticsEventKind: UInt8, Sendable, Equatable {
    case frameArrivalGap
    case decodeGap
    case senderDelay
    case queueDepth
    case pacerSleep
    case frameMarker
}

package struct MirageStreamingDiagnosticsEvent: Sendable, Equatable {
    package let timestampMicroseconds: UInt64
    package let streamID: StreamID
    package let kind: MirageStreamingDiagnosticsEventKind
    package let primaryValue: Int64
    package let secondaryValue: Int64
    package let frameSizeBucket: UInt8
    package let flags: UInt8

    package init(
        timestampMicroseconds: UInt64,
        streamID: StreamID,
        kind: MirageStreamingDiagnosticsEventKind,
        primaryValue: Int64 = 0,
        secondaryValue: Int64 = 0,
        frameSizeBucket: UInt8 = 0,
        flags: UInt8 = 0
    ) {
        self.timestampMicroseconds = timestampMicroseconds
        self.streamID = streamID
        self.kind = kind
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.frameSizeBucket = frameSizeBucket
        self.flags = flags
    }
}

package struct MirageStreamingDiagnosticsSnapshot: Sendable, Equatable {
    package let events: [MirageStreamingDiagnosticsEvent]
    package let droppedEventCount: UInt64
    package let capacity: Int
}

package final class MirageStreamingDiagnosticsBuffer: @unchecked Sendable {
    package static let defaultCapacity = 4_096

    private struct State {
        var events: [MirageStreamingDiagnosticsEvent?]
        var nextIndex: Int = 0
        var count: Int = 0
        var droppedEventCount: UInt64 = 0
    }

    private let capacity: Int
    private let state: MirageDiagnosticsLocked<State>

    package init(capacity: Int = MirageStreamingDiagnosticsBuffer.defaultCapacity) {
        let resolvedCapacity = max(1, capacity)
        self.capacity = resolvedCapacity
        state = MirageDiagnosticsLocked(State(events: Array(repeating: nil, count: resolvedCapacity)))
    }

    package func record(_ event: MirageStreamingDiagnosticsEvent) {
        state.withLock { state in
            if state.count == capacity {
                state.droppedEventCount &+= 1
            } else {
                state.count += 1
            }

            state.events[state.nextIndex] = event
            state.nextIndex = (state.nextIndex + 1) % capacity
        }
    }

    package func recordFrameArrivalGap(
        streamID: StreamID,
        gapMs: Double,
        frameSizeBytes: Int,
        isKeyframe: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .frameArrivalGap,
            primaryValue: Self.clampedMilliseconds(gapMs),
            frameSizeBucket: Self.frameSizeBucket(bytes: frameSizeBytes),
            flags: isKeyframe ? 1 : 0
        ))
    }

    package func recordDecodeGap(
        streamID: StreamID,
        gapMs: Double,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .decodeGap,
            primaryValue: Self.clampedMilliseconds(gapMs)
        ))
    }

    package func recordSenderDelay(
        streamID: StreamID,
        startDelayMs: Double,
        completionDelayMs: Double,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .senderDelay,
            primaryValue: Self.clampedMilliseconds(startDelayMs),
            secondaryValue: Self.clampedMilliseconds(completionDelayMs)
        ))
    }

    package func recordQueueDepth(
        streamID: StreamID,
        queuedBytes: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .queueDepth,
            primaryValue: Int64(max(0, queuedBytes))
        ))
    }

    package func recordPacerSleep(
        streamID: StreamID,
        totalMs: Int,
        maxMs: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .pacerSleep,
            primaryValue: Int64(max(0, totalMs)),
            secondaryValue: Int64(max(0, maxMs))
        ))
    }

    package func recordFrameMarker(
        streamID: StreamID,
        frameSizeBytes: Int,
        isKeyframe: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        record(MirageStreamingDiagnosticsEvent(
            timestampMicroseconds: Self.timestampMicroseconds(now),
            streamID: streamID,
            kind: .frameMarker,
            frameSizeBucket: Self.frameSizeBucket(bytes: frameSizeBytes),
            flags: isKeyframe ? 1 : 0
        ))
    }

    package func snapshot() -> MirageStreamingDiagnosticsSnapshot {
        state.withLock { state in
            var ordered: [MirageStreamingDiagnosticsEvent] = []
            ordered.reserveCapacity(state.count)
            let start = state.count == capacity ? state.nextIndex : 0
            for offset in 0 ..< state.count {
                let index = (start + offset) % capacity
                if let event = state.events[index] {
                    ordered.append(event)
                }
            }
            return MirageStreamingDiagnosticsSnapshot(
                events: ordered,
                droppedEventCount: state.droppedEventCount,
                capacity: capacity
            )
        }
    }

    package func reset() {
        state.withLock { state in
            state.events = [MirageStreamingDiagnosticsEvent?](repeating: nil, count: capacity)
            state.nextIndex = 0
            state.count = 0
            state.droppedEventCount = 0
        }
    }

    package static func frameSizeBucket(bytes: Int) -> UInt8 {
        let clampedBytes = max(0, bytes)
        guard clampedBytes > 0 else { return 0 }
        var bucket = 0
        var value = clampedBytes
        while value > 1, bucket < Int(UInt8.max) {
            value >>= 1
            bucket += 1
        }
        return UInt8(bucket)
    }

    private static func timestampMicroseconds(_ time: CFAbsoluteTime) -> UInt64 {
        UInt64(max(0, time) * 1_000_000)
    }

    private static func clampedMilliseconds(_ value: Double) -> Int64 {
        let sanitized = max(0, value)
        guard sanitized < Double(Int64.max) else { return Int64.max }
        return Int64(sanitized.rounded())
    }
}
