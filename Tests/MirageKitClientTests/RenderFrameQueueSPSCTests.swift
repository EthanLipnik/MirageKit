//
//  RenderFrameQueueSPSCTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for per-stream render queue behavior through MirageFrameCache.
//

@testable import MirageKitClient
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Render Frame Queue SPSC")
struct RenderFrameQueueSPSCTests {
    @Test("Frames dequeue in FIFO order")
    func fifoDequeueOrder() {
        let streamID: StreamID = 301
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for decodeTime in [1.0, 2.0, 3.0] {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: decodeTime,
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 1)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 2)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 3)
        #expect(MirageFrameCache.shared.dequeue(for: streamID) == nil)
    }

    @Test("Latest-frame presentation trims queue to newest frame")
    func latestFramePresentationTrimsQueue() {
        let streamID: StreamID = 302
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for index in 0 ..< 5 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: 1 + Double(index),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, policy: .latest)
        #expect(presented?.sequence == 5)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)
    }

    @Test("Buffered presentation keeps newest bounded window")
    func bufferedPresentationBoundedWindow() {
        let streamID: StreamID = 303
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for index in 0 ..< 7 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: 1 + Double(index),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            policy: .buffered(maxDepth: 3)
        )
        #expect(presented?.sequence == 5)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 2)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 6)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 7)
    }

    @Test("Queue overflow drops oldest entries at fixed capacity")
    func overflowDropsOldestEntries() {
        let streamID: StreamID = 304
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        var observedOverflowDrops = 0
        for index in 0 ..< 30 {
            let result = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: 1 + Double(index),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
            observedOverflowDrops += result.emergencyDrops
        }

        #expect(observedOverflowDrops >= 6)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 24)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 7)
    }

    @Test("Per-stream queues stay isolated")
    func perStreamIsolation() {
        let streamA: StreamID = 305
        let streamB: StreamID = 306
        MirageFrameCache.shared.clear(for: streamA)
        MirageFrameCache.shared.clear(for: streamB)
        defer {
            MirageFrameCache.shared.clear(for: streamA)
            MirageFrameCache.shared.clear(for: streamB)
        }

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamA
        )
        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            metalTexture: nil,
            texture: nil,
            for: streamA
        )
        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamB
        )

        #expect(MirageFrameCache.shared.dequeue(for: streamB)?.sequence == 1)
        #expect(MirageFrameCache.shared.queueDepth(for: streamA) == 2)
        #expect(MirageFrameCache.shared.dequeue(for: streamA)?.sequence == 1)
    }

    @Test("Presentation snapshot reflects markPresented updates")
    func presentationSnapshotUpdates() {
        let streamID: StreamID = 307
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for decodeTime in [1.0, 2.0, 3.0] {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: decodeTime,
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        MirageFrameCache.shared.markPresented(sequence: 2, for: streamID)
        let snapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)

        #expect(snapshot.sequence == 2)
        #expect(snapshot.presentedTime > 0)
    }

    @Test("Render telemetry reports decode and presentation cadence")
    func renderTelemetrySnapshot() {
        let streamID: StreamID = 308
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        MirageFrameCache.shared.setTargetFPS(60, for: streamID)
        for decodeTime in [1.0, 1.01, 1.02] {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: decodeTime,
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, policy: .latest)
        if let presented {
            MirageFrameCache.shared.markPresented(sequence: presented.sequence, for: streamID)
        }

        let telemetry = MirageFrameCache.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.decodeFPS >= 1)
        #expect(telemetry.presentedFPS >= 1)
        #expect(telemetry.uniquePresentedFPS >= 1)
        #expect(telemetry.targetFPS == 60)
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        guard let buffer else {
            Issue.record("Failed to allocate CVPixelBuffer")
            fatalError("Unable to allocate CVPixelBuffer for test")
        }
        return buffer
    }
}
#endif
