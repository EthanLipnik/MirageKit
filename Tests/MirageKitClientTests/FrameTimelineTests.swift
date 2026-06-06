//
//  FrameTimelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Coverage for internal per-frame realtime timeline diagnostics.
//

@testable import MirageKitClient
import CoreGraphics
import CoreMedia
import CoreVideo
import MirageKit
import Testing
import MirageCore
import MirageDiagnostics

@Suite("Frame Timeline")
struct FrameTimelineTests {
    @Test("Render store marks timeline display acceptance")
    func renderStoreMarksTimelineDisplayAcceptance() throws {
        let streamID: StreamID = 7_701
        MirageRenderStreamStore.shared.clear(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        let timeline = MirageDiagnostics.FrameTimeline(
            streamID: streamID,
            frameNumber: 42,
            dependencyEpoch: MirageDiagnostics.DependencyEpoch(3),
            isKeyframe: true,
            encodedByteCount: 4096,
            fragmentCount: 4,
            receivedFragmentCount: 4,
            firstPacketReceiveTime: now - 0.004,
            lastPacketReceiveTime: now - 0.003,
            reassemblyCompleteTime: now - 0.002,
            decodeSubmitTime: now - 0.001,
            decodeCallbackTime: now,
            queueAgeMs: 4
        )

        let result = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: try makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 16, height: 16),
            decodeTime: now,
            presentationTime: CMTime(value: 42, timescale: 60),
            remotePresentationTime: CMTime(value: 42, timescale: 60),
            generation: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
            hostEpoch: timeline.dependencyEpoch.rawValue,
            dimensionToken: 9,
            frameNumber: timeline.frameNumber,
            queueEpoch: 5,
            timeline: timeline,
            for: streamID
        )
        #expect(result.didEnqueue)

        MirageRenderStreamStore.shared.markSubmitted(
            cursor: result.cursor,
            remotePresentationTime: CMTime(value: 42, timescale: 60),
            mappedPresentationTime: CMTime(value: 42, timescale: 60),
            for: streamID
        )

        let accepted = MirageRenderStreamStore.shared.latestAcceptedFrameTimeline(for: streamID)
        let rendered = MirageRenderStreamStore.shared.renderedFrameTelemetry(for: streamID)
        #expect(accepted?.streamID == streamID)
        #expect(accepted?.frameNumber == 42)
        #expect(accepted?.dependencyEpoch == MirageDiagnostics.DependencyEpoch(3))
        #expect(accepted?.renderEnqueueTime != nil)
        #expect(accepted?.displayPresentationAcceptedTime != nil)
        #expect(rendered.renderedFrameNumber == 42)
        #expect(rendered.renderedFrameSubmittedTime > 0)

        MirageRenderStreamStore.shared.clear(for: streamID)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }
}
