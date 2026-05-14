//
//  MirageSampleBufferPresentationPipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Testing

@MainActor
@Suite("Sample Buffer Presentation Pipeline")
struct MirageSampleBufferPresentationPipelineTests {
    @Test("Configuration drives aspect-fit video gravity")
    func configurationDrivesAspectFitVideoGravity() {
        let layer = AVSampleBufferDisplayLayer()
        let pipeline = makePipeline(displayLayer: layer)

        pipeline.applyConfiguration(configuration(prefersLocalAspectFitPresentation: true))
        #expect(layer.videoGravity == .resizeAspect)

        pipeline.applyConfiguration(configuration(prefersLocalAspectFitPresentation: false))
        #expect(layer.videoGravity == .resize)
    }

    @Test("Drawable metrics are deduplicated and capped through shared pipeline")
    func drawableMetricsAreDeduplicatedAndCapped() {
        let layer = AVSampleBufferDisplayLayer()
        let pipeline = makePipeline(displayLayer: layer)
        var reportedMetrics: [MirageDrawableMetrics] = []
        pipeline.onDrawableMetricsChanged = { reportedMetrics.append($0) }
        pipeline.applyConfiguration(configuration(maxDrawableSize: CGSize(width: 120, height: 80)))

        pipeline.publishDrawableMetricsIfChanged(
            viewSize: CGSize(width: 200, height: 100),
            scaleFactor: 2
        )
        pipeline.publishDrawableMetricsIfChanged(
            viewSize: CGSize(width: 200, height: 100),
            scaleFactor: 2
        )

        #expect(reportedMetrics.first?.pixelSize == CGSize(width: 120, height: 60))
        #expect(reportedMetrics.count == 1)
    }

    @Test("Presentation recovery handler is registered for configured stream")
    func presentationRecoveryHandlerIsRegisteredForConfiguredStream() {
        let streamID: StreamID = 244
        let layer = AVSampleBufferDisplayLayer()
        var startCount = 0
        var stopCount = 0
        let pipeline = makePipeline(
            displayLayer: layer,
            startDisplayClock: { _, _ in startCount += 1 },
            stopDisplayClock: { stopCount += 1 }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            pipeline.applyConfiguration(configuration(streamID: nil))
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        pipeline.applyConfiguration(configuration(streamID: streamID))
        #expect(startCount == 1)

        let didRequestRecovery = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)

        #expect(didRequestRecovery)
        #expect(startCount >= 2)
        #expect(stopCount == 0)
    }

    @Test("Presenter rebases sequence state after render-store clear")
    func presenterRebasesSequenceStateAfterRenderStoreClear() {
        let streamID: StreamID = 245
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        presenter.setStreamID(streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: 1,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)

        MirageRenderStreamStore.shared.clear(for: streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: 2,
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
    }

    @Test("Presenter does not rebase when latest sequence matches submitted sequence")
    func presenterDoesNotRebaseWhenLatestSequenceMatchesSubmittedSequence() {
        let streamID: StreamID = 246
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        presenter.setStreamID(streamID)
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: 1,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(MirageRenderStreamStore.shared.latestCursor(for: streamID).sequence == 1)
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .noPendingFrame)
    }

    private func makePipeline(
        displayLayer: AVSampleBufferDisplayLayer,
        startDisplayClock: @escaping MirageSampleBufferPresentationPipeline.StartDisplayClock = { _, _ in },
        stopDisplayClock: @escaping () -> Void = {}
    )
        -> MirageSampleBufferPresentationPipeline {
        MirageSampleBufferPresentationPipeline(
            displayLayer: displayLayer,
            platformName: "test",
            canStartDisplayClock: { true },
            startDisplayClock: startDisplayClock,
            stopDisplayClock: stopDisplayClock,
            updateDisplayClockTargetFPS: { _ in },
            requestPlatformLayout: {}
        )
    }

    private func configuration(
        streamID: StreamID? = nil,
        maxDrawableSize: CGSize? = nil,
        prefersLocalAspectFitPresentation: Bool = false
    )
    -> MirageStreamRenderConfiguration {
        MirageStreamRenderConfiguration(
            mediaStreamID: streamID,
            contentRectOverride: nil,
            presentationTier: .activeLive,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation
        )
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
