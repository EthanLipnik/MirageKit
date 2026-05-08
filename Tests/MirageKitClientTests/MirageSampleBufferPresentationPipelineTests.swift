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
}
#endif
