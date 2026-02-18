//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for decode-synchronous frame selection behavior.
//

@testable import MirageKitClient
import CoreVideo
import MirageKit
import Testing

#if os(macOS)
@Suite("Render Cadence Smoothing")
struct RenderCadenceSmoothingTests {
    @Test("Healthy decode presents newest frame without added buffer delay")
    func healthyDecodePresentsNewestFrame() {
        let streamID: StreamID = 401
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for decodeTime in [1.0, 2.0, 3.0, 4.0, 5.0] {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: decodeTime,
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let frame = MirageFrameCache.shared.dequeueForPresentation(for: streamID, policy: .latest)
        #expect(frame?.sequence == 5)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)
    }

    @Test("Stress buffering keeps bounded newest window")
    func stressBufferKeepsBoundedNewestWindow() {
        let streamID: StreamID = 402
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        for decodeTime in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] {
            _ = MirageFrameCache.shared.enqueue(
                makePixelBuffer(),
                contentRect: .zero,
                decodeTime: decodeTime,
                metalTexture: nil,
                texture: nil,
                for: streamID
            )
        }

        let first = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            policy: .buffered(maxDepth: 3)
        )
        #expect(first?.sequence == 4)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 2)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 5)
        #expect(MirageFrameCache.shared.dequeue(for: streamID)?.sequence == 6)
    }

    @Test("Underflow does not repeat previously presented frames")
    func underflowDoesNotRepeat() {
        let streamID: StreamID = 403
        MirageFrameCache.shared.clear(for: streamID)
        defer { MirageFrameCache.shared.clear(for: streamID) }

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        let first = MirageFrameCache.shared.dequeueForPresentation(for: streamID, policy: .latest)
        let second = MirageFrameCache.shared.dequeueForPresentation(for: streamID, policy: .latest)

        #expect(first?.sequence == 1)
        #expect(second == nil)
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
