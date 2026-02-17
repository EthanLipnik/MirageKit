//
//  RenderFrameQueueSPSCTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for per-stream SPSC queue behavior through MirageFrameCache.
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

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Presentation fast-path keeps newest depth when preferLatest is enabled")
    func newestFrameFastPath() {
        let streamID: StreamID = 302
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 5 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + 1 + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            catchUpDepth: 2,
            preferLatest: true
        )

        #expect(presented?.sequence == 4)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 1)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 5)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Queue overflow drops oldest entries at fixed capacity")
    func overflowDropsOldestEntries() {
        let streamID: StreamID = 303
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        var observedOverflowDrops = 0

        for index in 0 ..< 18 {
            let result = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + 1 + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
            observedOverflowDrops += result.emergencyDrops
        }

        #expect(observedOverflowDrops >= 2)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 16)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 3)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Per-stream queues stay isolated")
    func perStreamIsolation() {
        let streamA: StreamID = 304
        let streamB: StreamID = 305
        MirageFrameCache.shared.clear(for: streamA)
        MirageFrameCache.shared.clear(for: streamB)

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

        MirageFrameCache.shared.clear(for: streamA)
        MirageFrameCache.shared.clear(for: streamB)
    }

    @Test("Presentation snapshot reflects markPresented updates")
    func presentationSnapshotUpdates() {
        let streamID: StreamID = 306
        MirageFrameCache.shared.clear(for: streamID)

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

        MirageFrameCache.shared.clear(for: streamID)
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
