//
//  RenderCadenceSmoothingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latest-frame cadence behavior.
//

@testable import MirageKitClient
import CoreMedia
import CoreVideo
import MirageKit
import Testing

#if os(macOS)
@Suite("Render Cadence Smoothing")
struct RenderCadenceSmoothingTests {
    @Test("Latest-frame path keeps only one pending frame during steady decode")
    func latestFramePathKeepsSinglePendingFrame() {
        let streamID: StreamID = 401
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        for index in 0 ..< 5 {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: .zero,
                decodeTime: Double(index),
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                for: streamID
            )
        }

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 5)
    }

    @Test("Display-layer backpressure preserves only the newest pending frame")
    func displayLayerBackpressureKeepsNewestPendingFrame() {
        let streamID: StreamID = 402
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.noteDisplayLayerNotReady(for: streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 2,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
            for: streamID
        )

        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.peekPendingFrame(for: streamID)?.sequence == 2)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.pendingFrameCount == 1)
        #expect(telemetry.overwrittenPendingFrames == 1)
        #expect(telemetry.displayLayerNotReadyCount == 1)
    }

    @Test("Repeated submission marks do not create unique forward progress")
    func repeatedSubmissionMarksDoNotRepeatUniqueProgress() {
        let streamID: StreamID = 403
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            mappedPresentationTime: .zero,
            for: streamID
        )
        MirageRenderStreamStore.shared.markSubmitted(
            sequence: 1,
            mappedPresentationTime: .zero,
            for: streamID
        )

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.submittedFPS >= 2)
        #expect(telemetry.uniqueSubmittedFPS >= 1)
        #expect(telemetry.uniqueSubmittedFPS < telemetry.submittedFPS)
    }

    @Test("Taking the only pending frame does not repeat on underflow")
    func underflowDoesNotRepeatPendingFrame() {
        let streamID: StreamID = 404
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: .zero,
            decodeTime: 1,
            presentationTime: .zero,
            for: streamID
        )

        let first = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)
        let second = MirageRenderStreamStore.shared.takePendingFrame(for: streamID)

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
