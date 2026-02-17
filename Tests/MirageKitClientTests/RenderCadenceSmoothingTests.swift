//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for cadence-repeat behavior without interpolation.
//

@testable import MirageKitClient
import CoreVideo
import MirageKit
import Testing

#if os(macOS)
@Suite("Render Cadence Smoothing")
struct RenderCadenceSmoothingTests {
    @Test("Smoothest repeats latest decoded frame when queue is empty")
    func smoothestRepeatsLatestFrame() {
        let streamID: StreamID = 401
        MirageFrameCache.shared.clear(for: streamID)

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        var selector = PresentationSelector()
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            targetFPS: 60
        )

        let first = selector.dequeueOrRepeat(streamID: streamID, decision: decision)
        let second = selector.dequeueOrRepeat(streamID: streamID, decision: decision)

        #expect(first == 1)
        #expect(second == 1)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Lowest latency does not repeat when queue is empty")
    func lowestLatencyDoesNotRepeat() {
        let streamID: StreamID = 402
        MirageFrameCache.shared.clear(for: streamID)

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        var selector = PresentationSelector()
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .lowestLatency,
            typingBurstActive: false,
            targetFPS: 60
        )

        let first = selector.dequeueOrRepeat(streamID: streamID, decision: decision)
        let second = selector.dequeueOrRepeat(streamID: streamID, decision: decision)

        #expect(first == 1)
        #expect(second == nil)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Cadence repeat preserves sequence identity")
    func cadenceRepeatKeepsSameSequence() {
        let streamID: StreamID = 403
        MirageFrameCache.shared.clear(for: streamID)

        _ = MirageFrameCache.shared.enqueue(
            makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            metalTexture: nil,
            texture: nil,
            for: streamID
        )

        var selector = PresentationSelector()
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            targetFPS: 120
        )

        let first = selector.dequeueOrRepeat(streamID: streamID, decision: decision)
        let repeatA = selector.dequeueOrRepeat(streamID: streamID, decision: decision)
        let repeatB = selector.dequeueOrRepeat(streamID: streamID, decision: decision)

        #expect(first == 1)
        #expect(repeatA == first)
        #expect(repeatB == first)

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

private struct PresentationSelector {
    private var lastSequence: UInt64?

    mutating func dequeueOrRepeat(streamID: StreamID, decision: MirageRenderModeDecision) -> UInt64? {
        if let frame = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            catchUpDepth: decision.presentationKeepDepth,
            preferLatest: decision.preferLatest
        ) {
            lastSequence = frame.sequence
            return frame.sequence
        }

        if decision.allowCadenceRepeat {
            return lastSequence
        }

        return nil
    }
}
#endif
