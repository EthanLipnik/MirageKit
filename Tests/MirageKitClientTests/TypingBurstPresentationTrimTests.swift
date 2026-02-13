//
//  TypingBurstPresentationTrimTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for typing-burst presentation trimming in the frame cache.
//

@testable import MirageKitClient
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Typing Burst Presentation Trim")
struct TypingBurstPresentationTrimTests {
    @Test("Recent backlog stays FIFO without typing burst")
    func recentBacklogStaysFIFOWithoutTypingBurst() {
        let streamID: StreamID = 201
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

        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, catchUpDepth: 2)
        #expect(presented?.sequence == 1)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 4)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Typing burst trims queue to newest frame")
    func typingBurstTrimsToNewestFrame() {
        let streamID: StreamID = 202
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

        MirageFrameCache.shared.noteTypingBurstActivity(for: streamID)
        let presented = MirageFrameCache.shared.dequeueForPresentation(for: streamID, catchUpDepth: 2)

        #expect(presented?.sequence == 5)
        #expect(MirageFrameCache.shared.queueDepth(for: streamID) == 0)

        MirageFrameCache.shared.clear(for: streamID)
    }

    @Test("Typing burst activity expires to baseline window")
    func typingBurstExpiresBackToBaseline() {
        let streamID: StreamID = 203
        MirageFrameCache.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        MirageFrameCache.shared.noteTypingBurstActivity(for: streamID)

        #expect(MirageFrameCache.shared.isTypingBurstActive(for: streamID, now: now + 0.10))
        #expect(!MirageFrameCache.shared.isTypingBurstActive(for: streamID, now: now + 0.50))

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
