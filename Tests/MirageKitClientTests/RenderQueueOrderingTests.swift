//
//  RenderQueueOrderingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Coverage for ordered per-stream render queue behavior.
//

@testable import MirageKitClient
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Render Queue Ordering")
struct RenderQueueOrderingTests {
    @Test("Frames dequeue in strict FIFO order")
    func strictFIFOOrder() {
        let streamID: StreamID = 101
        MirageFrameCache.shared.clear(for: streamID)

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 3,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 1)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 2)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 3)
        #expect(MirageFrameCache.shared.dequeue(for: streamID) == nil)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Normal capacity enqueues do not trigger queue drops")
    func noDropUnderNormalCapacity() {
        let streamID: StreamID = 102
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        var maxEmergencyDrops = 0
        for index in 0 ..< 8 {
            let result = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
            maxEmergencyDrops = max(maxEmergencyDrops, result.emergencyDrops)
        }

        #expect(maxEmergencyDrops == 0)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 8)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Sustained backlog arms emergency trim and drops to safe depth")
    func emergencyTrimDropsToSafeDepth() {
        let streamID: StreamID = 103
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        var emergencyDropObserved = false
        for index in 0 ..< 13 {
            let result = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
            if result.emergencyDrops > 0 {
                emergencyDropObserved = true
            }
        }

        #expect(emergencyDropObserved)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 4)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 10)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Per-stream queues remain isolated")
    func perStreamIsolation() {
        let streamA: StreamID = 104
        let streamB: StreamID = 105
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

    @Test("Presentation dequeue trims backlog to keep depth")
    func presentationDequeueRespectsKeepDepth() {
        let streamID: StreamID = 106
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 5 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now - (0.250 + (Double(index) * 0.005)),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, catchUpDepth: 2)
        #expect(presented?.sequence == 4)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 1)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 5)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Presentation dequeue keeps deep recent backlog in FIFO order")
    func presentationDequeuePreservesDeepRecentBacklog() {
        let streamID: StreamID = 108
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 7 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + 1 + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, catchUpDepth: 2)
        #expect(presented?.sequence == 1)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 6)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 2)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Presentation dequeue keeps shallow recent backlog in FIFO order")
    func presentationDequeuePreservesShallowRecentBacklog() {
        let streamID: StreamID = 107
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        for index in 0 ..< 4 {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: now + 1 + (Double(index) * 0.001),
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, catchUpDepth: 2)
        #expect(presented?.sequence == 1)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 3)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 2)

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
