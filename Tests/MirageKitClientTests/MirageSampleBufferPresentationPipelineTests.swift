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
@Suite("Sample Buffer Presentation Pipeline", .serialized)
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

        let first = pipeline.reportDrawableMetricsIfChanged(
            viewSize: CGSize(width: 200, height: 100),
            scaleFactor: 2
        )
        let duplicate = pipeline.reportDrawableMetricsIfChanged(
            viewSize: CGSize(width: 200, height: 100),
            scaleFactor: 2
        )

        #expect(first?.pixelSize == CGSize(width: 120, height: 60))
        #expect(duplicate == nil)
        #expect(reportedMetrics.count == 1)
    }

    @Test("Presentation recovery handler is registered for configured stream")
    func presentationRecoveryHandlerIsRegisteredForConfiguredStream() async throws {
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
        try await Task.sleep(for: .milliseconds(20))

        #expect(didRequestRecovery)
        #expect(startCount == 1)
        #expect(stopCount == 0)
    }

    @Test("Presenter resets timing after render-store generation boundary")
    func presenterResetsTimingAfterRenderStoreGenerationBoundary() {
        let streamID: StreamID = 9245
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        presenter.setStreamID(streamID)
        let now = CFAbsoluteTimeGetCurrent()
        MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)

        MirageRenderStreamStore.shared.clear(for: streamID)
        MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
    }

    @Test("Presenter submits retained frame once for a presenter cursor")
    func presenterSubmitsRetainedFrameOnceForPresenterCursor() {
        let streamID: StreamID = 9246
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        presenter.setStreamID(streamID)
        let now = CFAbsoluteTimeGetCurrent()
        MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
        #expect(MirageRenderStreamStore.shared.pendingFrameCount(for: streamID) == 1)
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .noPendingFrame)
    }

    @Test("Lowest latency presenter submits latest frame only in one pass")
    func lowestLatencyPresenterSubmitsLatestFrameOnlyInOnePass() {
        let streamID: StreamID = 9249
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 60, latencyMode: .lowestLatency)
        )
        presenter.setStreamID(streamID)

        let now = CFAbsoluteTimeGetCurrent()
        var lastCursor = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        for index in 0 ..< 2 {
            lastCursor = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: makePixelBuffer(),
                contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                decodeTime: now + Double(index) * 0.001,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                for: streamID
            ).cursor
        }

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0, source: .rendererReady) == .submitted)

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(snapshot.cursor == lastCursor)
        #expect(telemetry.presentationPassFPS >= 1)
        #expect(telemetry.framesSubmittedPerPassAverage == 1)
        #expect(telemetry.framesSubmittedPerPassMax == 1)
        #expect(telemetry.uniqueLayerEnqueueFPS == 1)
        #expect(telemetry.displayImmediatelySubmittedCount == 1)
        #expect(telemetry.rendererReadyDrainPassCount == 1)
        #expect(telemetry.rendererReadyDrainSubmittedCount == 1)
    }

    @Test("Smoothest presenter drains until one fresh frame remains")
    func smoothestPresenterDrainsUntilOneFreshFrameRemains() {
        let streamID: StreamID = 9250
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }
        MirageRenderStreamStore.shared.setCadenceTarget(
            for: streamID,
            target: MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 60, latencyMode: .smoothest)
        )
        presenter.setStreamID(streamID)

        let now = CFAbsoluteTimeGetCurrent()
        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now,
            presentationTime: .zero,
            for: streamID
        )
        let second = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now + 0.001,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        let third = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now + 0.002,
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )

        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(snapshot.cursor == second.cursor)
        #expect(first.cursor.sequence == 1)
        #expect(third.cursor.sequence == 3)
        #expect(MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: second.cursor))
        #expect(telemetry.smoothestOneFrameHoldCount == 1)
        #expect(telemetry.framesSubmittedPerPassMax == 2)
        #expect(telemetry.displayImmediatelySubmittedCount == 1)
    }

    @Test("Repeated identical layout does not trigger duplicate immediate submission")
    func repeatedIdenticalLayoutDoesNotTriggerDuplicateImmediateSubmission() async throws {
        let streamID: StreamID = 9247
        let layer = AVSampleBufferDisplayLayer()
        var displayTickHandler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?
        let pipeline = makePipeline(
            displayLayer: layer,
            startDisplayClock: { _, handler in
                displayTickHandler = handler
            }
        )
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            pipeline.applyConfiguration(configuration(streamID: nil))
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        pipeline.applyConfiguration(configuration(streamID: streamID))
        let now = CFAbsoluteTimeGetCurrent()
        let first = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: now,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        pipeline.layoutDisplayLayer(bounds: CGRect(x: 0, y: 0, width: 8, height: 8), scale: 1)
        displayTickHandler?(1)

        let firstSnapshot = try await waitForSubmission(streamID: streamID, cursor: first.cursor)
        #expect(firstSnapshot.cursor == first.cursor)

        let second = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )
        pipeline.layoutDisplayLayer(
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            scale: 1,
            metricsContext: MirageDrawableMetricsContext(
                screenPointSize: CGSize(width: 16, height: 16),
                screenScale: 2,
                screenNativePixelSize: CGSize(width: 32, height: 32),
                screenNativeScale: 2
            )
        )

        let secondSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        #expect(secondSnapshot.cursor == first.cursor)
        #expect(MirageRenderStreamStore.shared.hasFrameForPresentation(for: streamID, after: first.cursor))
        #expect(second.cursor.isAfter(first.cursor))
    }

    @Test("Presenter caches contentsRect and preserves rect reset behavior")
    func presenterCachesContentsRectAndPreservesRectResetBehavior() {
        let streamID: StreamID = 9248
        let layer = AVSampleBufferDisplayLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let presenter = MirageSampleBufferPresenter(displayLayer: layer)
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer {
            presenter.setStreamID(nil)
            MirageRenderStreamStore.shared.clear(for: streamID)
        }

        presenter.setStreamID(streamID)
        let now = CFAbsoluteTimeGetCurrent()
        MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 0, y: 0, width: 4, height: 8),
            decodeTime: now,
            presentationTime: CMTime(value: 1, timescale: 60),
            for: streamID
        )
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
        #expect(layer.contentsRect == CGRect(x: 0, y: 0, width: 0.5, height: 1))

        MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: makePixelBuffer(),
            contentRect: CGRect(x: 4, y: 0, width: 4, height: 8),
            decodeTime: CFAbsoluteTimeGetCurrent(),
            presentationTime: CMTime(value: 2, timescale: 60),
            for: streamID
        )
        #expect(presenter.submitPendingFrameIfPossible(referenceTime: 0) == .submitted)
        #expect(layer.contentsRect == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

        presenter.resetPresentationState()
        #expect(layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
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
            logicalStreamID: streamID,
            mediaStreamID: streamID,
            contentRectOverride: nil,
            presentationTier: .activeLive,
            preferredMaximumRenderFPS: nil,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
            containerSizingMode: .viewBounds
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

    private func waitForSubmission(
        streamID: StreamID,
        cursor: MirageRenderCursor,
        timeout: Duration = .seconds(1)
    ) async throws -> MirageRenderStreamStore.SubmissionSnapshot {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
            if snapshot.cursor == cursor {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
    }
}
#endif
