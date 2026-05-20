//
//  MirageSampleBufferPresentationPipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Shared AVSampleBufferDisplayLayer presentation pipeline for client platforms.
//

import AVFoundation
import CoreGraphics
import Foundation
import MirageKit
import QuartzCore

/// Rendering inputs that bind a sample-buffer view to a Mirage media stream.
struct MirageStreamRenderConfiguration: Equatable {
    var mediaStreamID: StreamID?
    var contentRectOverride: CGRect?
    var presentationTier: StreamPresentationTier
    var maxDrawableSize: CGSize?
    var prefersLocalAspectFitPresentation: Bool

    static let empty = MirageStreamRenderConfiguration(
        mediaStreamID: nil,
        contentRectOverride: nil,
        presentationTier: .activeLive,
        maxDrawableSize: nil,
        prefersLocalAspectFitPresentation: false
    )
}

/// Platform display metrics used to cap drawable size and report render scale.
struct MirageDrawableMetricsContext: Equatable {
    var screenPointSize: CGSize?
    var screenScale: CGFloat?
    var screenNativePixelSize: CGSize?
    var screenNativeScale: CGFloat?

    static let empty = MirageDrawableMetricsContext()
}

/// Coordinates decoded-frame presentation, display-clock cadence, and layer recovery.
@MainActor
final class MirageSampleBufferPresentationPipeline {
    typealias DisplayTickHandler = @MainActor (CFTimeInterval) -> Void
    typealias StartDisplayClock = (Int, @escaping DisplayTickHandler) -> Void

    var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    var onRefreshRateOverrideChange: ((Int) -> Void)?

    private let displayLayer: AVSampleBufferDisplayLayer
    private let canStartDisplayClock: () -> Bool
    private let startDisplayClock: StartDisplayClock
    private let stopDisplayClock: () -> Void
    private let updateDisplayClockTargetFPS: (Int) -> Void
    private let requestPlatformLayout: () -> Void
    private let platformName: String

    private var presenter: MirageSampleBufferPresenter!
    private var presentationScheduler: MirageRenderPresentationScheduler!
    private var displayLayerReadinessRetryTask: Task<Void, Never>?
    private var configuration: MirageStreamRenderConfiguration = .empty
    private var maxRenderFPS: Int = 60
    private var appliedRefreshRateLock: Int = 0
    private var lastReportedDrawableMetrics: MirageDrawableMetrics?

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    init(
        displayLayer: AVSampleBufferDisplayLayer,
        platformName: String,
        canStartDisplayClock: @escaping () -> Bool,
        startDisplayClock: @escaping StartDisplayClock,
        stopDisplayClock: @escaping () -> Void,
        updateDisplayClockTargetFPS: @escaping (Int) -> Void,
        requestPlatformLayout: @escaping () -> Void
    ) {
        self.displayLayer = displayLayer
        self.platformName = platformName
        self.canStartDisplayClock = canStartDisplayClock
        self.startDisplayClock = startDisplayClock
        self.stopDisplayClock = stopDisplayClock
        self.updateDisplayClockTargetFPS = updateDisplayClockTargetFPS
        self.requestPlatformLayout = requestPlatformLayout

        presenter = MirageSampleBufferPresenter(displayLayer: displayLayer)
        presentationScheduler = MirageRenderPresentationScheduler(
            submit: { [weak presenter = presenter] referenceTime in
                presenter?.submitPendingFrameIfPossible(referenceTime: referenceTime) ?? .blocked
            },
            hasPendingFrame: { [weak presenter = presenter] in
                presenter?.hasPendingFrameForCurrentPresenter ?? false
            },
            onDisplayLayerNotReady: { [weak self] in
                self?.armDisplayLayerReadinessRetry()
            }
        )
        presentationScheduler.setPresentationTier(configuration.presentationTier)
        presenter.onFrameAvailable = { [weak self] in
            self?.presentationScheduler.handleFrameAvailable(referenceTime: CACurrentMediaTime())
        }
        presenter.onPresentationRecoveryRequested = { [weak self] in
            self?.recoverPresentationPipeline()
        }
    }

    deinit {
        displayLayerReadinessRetryTask?.cancel()
    }

    func applyConfiguration(_ newConfiguration: MirageStreamRenderConfiguration) {
        let previousConfiguration = configuration
        configuration = newConfiguration

        if newConfiguration.prefersLocalAspectFitPresentation != previousConfiguration.prefersLocalAspectFitPresentation {
            applyPresentationVideoGravity()
        }

        if newConfiguration.contentRectOverride != previousConfiguration.contentRectOverride {
            presenter.setContentRectOverride(newConfiguration.contentRectOverride)
        }

        if newConfiguration.maxDrawableSize != previousConfiguration.maxDrawableSize {
            lastReportedDrawableMetrics = nil
            requestPlatformLayout()
        }

        if newConfiguration.presentationTier != previousConfiguration.presentationTier {
            presentationScheduler.setPresentationTier(newConfiguration.presentationTier)
            let requested = appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS
            applyDisplayRefreshRateLock(requested)
            updatePresentationDisplayClockFrameRate()
        }

        if newConfiguration.mediaStreamID != previousConfiguration.mediaStreamID {
            bindStreamForPresentation(newConfiguration.mediaStreamID)
        } else {
            requestImmediateSubmission()
        }
    }

    func setInitialVideoLayerState(scale: CGFloat) {
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        displayLayer.wantsExtendedDynamicRangeContent = true
        displayLayer.isOpaque = true
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        displayLayer.contentsScale = scale
        applyPresentationVideoGravity()
    }

    func layoutDisplayLayer(
        bounds: CGRect,
        scale: CGFloat,
        metricsContext: MirageDrawableMetricsContext = .empty
    ) {
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale
        publishDrawableMetricsIfChanged(
            viewSize: bounds.size,
            scaleFactor: scale,
            metricsContext: metricsContext
        )
        requestImmediateSubmission()
    }

    func suspendRendering(clearCurrentFrame: Bool = true) {
        stopDisplayLayerReadinessRetry()
        stopPresentationDisplayClock()
        presenter.setRenderingSuspended(true, clearCurrentFrame: clearCurrentFrame)
        presentationScheduler.setRenderingSuspended(true)
    }

    func resumeRendering() {
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        presentationScheduler.setRenderingSuspended(false)
        startPresentationDisplayClockIfNeeded()
        requestImmediateSubmission()
    }

    #if os(iOS) || os(visionOS)
    var hasDisplayLayerFailure: Bool {
        presenter.hasDisplayLayerFailure
    }

    func resumeRenderingAfterApplicationActivation(resetPresentationState: Bool) {
        if resetPresentationState {
            presenter.resetPresentationState(removeDisplayedImage: false)
        }
        resumeRendering()
    }

    func resolvedPresentedContentRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        guard configuration.prefersLocalAspectFitPresentation else { return bounds }
        return DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: presenter.currentContentReferenceSize,
            in: bounds
        )
    }
    #endif

    func applyResolvedRenderFPS(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = clamped
        presenter.setTargetFPS(clamped)
        applyDisplayRefreshRateLock(clamped)
        onRefreshRateOverrideChange?(clamped)
    }

    func requestImmediateSubmission() {
        presentationScheduler.requestImmediateSubmission(referenceTime: CACurrentMediaTime())
    }

    func requestReadinessRetry() {
        presentationScheduler.requestReadinessRetry(referenceTime: CACurrentMediaTime())
    }

    func stopDisplayLayerReadinessRetry() {
        displayLayerReadinessRetryTask?.cancel()
        displayLayerReadinessRetryTask = nil
    }

    // MARK: - Metrics

    func publishDrawableMetricsIfChanged(
        viewSize: CGSize,
        scaleFactor: CGFloat,
        metricsContext: MirageDrawableMetricsContext = .empty
    ) {
        guard let metrics = nextDrawableMetricsIfChanged(
            viewSize: viewSize,
            scaleFactor: scaleFactor,
            metricsContext: metricsContext
        ) else {
            return
        }
        publishDrawableMetrics(metrics)
    }

    private func nextDrawableMetricsIfChanged(
        viewSize: CGSize,
        scaleFactor: CGFloat,
        metricsContext: MirageDrawableMetricsContext
    ) -> MirageDrawableMetrics? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let pixelSize = cappedDrawableSize(
            CGSize(width: viewSize.width * scaleFactor, height: viewSize.height * scaleFactor)
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let metrics = MirageDrawableMetrics(
            pixelSize: pixelSize,
            viewSize: viewSize,
            scaleFactor: scaleFactor,
            screenPointSize: metricsContext.screenPointSize,
            screenScale: metricsContext.screenScale,
            screenNativePixelSize: metricsContext.screenNativePixelSize,
            screenNativeScale: metricsContext.screenNativeScale
        )
        guard lastReportedDrawableMetrics != metrics else { return nil }

        return metrics
    }

    private func publishDrawableMetrics(_ metrics: MirageDrawableMetrics) {
        lastReportedDrawableMetrics = metrics
        onDrawableMetricsChanged?(metrics)
    }

    // MARK: - Presentation

    private func applyPresentationVideoGravity() {
        displayLayer.videoGravity = configuration.prefersLocalAspectFitPresentation ? .resizeAspect : .resize
    }

    private func bindStreamForPresentation(_ streamID: StreamID?) {
        presenter.setStreamID(streamID)
        presentationScheduler.setStreamID(streamID)
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        presentationScheduler.setRenderingSuspended(false)
        if streamID == nil {
            stopPresentationDisplayClock()
        } else {
            startPresentationDisplayClockIfNeeded()
        }
        requestImmediateSubmission()
    }

    private func recoverPresentationPipeline() {
        let streamID = configuration.mediaStreamID
        MirageLogger.renderer("Recovering \(platformName) presentation pipeline for stream \(streamID.map(String.init) ?? "none")")
        presenter.setStreamID(streamID)
        presentationScheduler.setStreamID(streamID)
        presenter.resetPresentationState(
            preserveLoggedLayerFailure: true,
            removeDisplayedImage: streamID == nil
        )
        presentationScheduler.reset()
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        presentationScheduler.setRenderingSuspended(false)
        startPresentationDisplayClockIfNeeded()
        requestImmediateSubmission()
    }

    private func startPresentationDisplayClockIfNeeded() {
        guard canStartDisplayClock() else { return }
        guard configuration.mediaStreamID != nil else { return }
        let localFPS = localPresentationFPS()
        presentationScheduler.setTargetFPS(localFPS)
        startDisplayClock(localFPS) { [weak self] referenceTime in
            self?.presentationScheduler.handleDisplayTick(referenceTime: referenceTime)
        }
        presentationScheduler.setDisplayClockActive(true)
    }

    private func stopPresentationDisplayClock() {
        stopDisplayClock()
        presentationScheduler.setDisplayClockActive(false)
    }

    private func updatePresentationDisplayClockFrameRate() {
        let localFPS = localPresentationFPS()
        presentationScheduler.setTargetFPS(localFPS)
        updateDisplayClockTargetFPS(localFPS)
    }

    private func armDisplayLayerReadinessRetry() {
        guard displayLayerReadinessRetryTask == nil else { return }
        displayLayerReadinessRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self else { return }
            displayLayerReadinessRetryTask = nil
            requestReadinessRetry()
        }
    }

    private func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        let localFPS = localPresentationFPS(hostFPS: clamped)
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        presentationScheduler.setTargetFPS(localFPS)
        updatePresentationDisplayClockFrameRate()

        guard changed else { return }
        let streamLabel = configuration.mediaStreamID.map { "\($0)" } ?? "none"
        MirageLogger.renderer(
            "Applied \(platformName) render cadence target: stream=\(streamLabel) host=\(clamped)Hz local=\(localFPS)Hz tier=\(configuration.presentationTier.rawValue)"
        )
    }

    private func localPresentationFPS(hostFPS: Int? = nil) -> Int {
        let resolvedHostFPS = MirageRenderModePolicy.normalizedTargetFPS(
            hostFPS ?? (appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS)
        )
        return configuration.presentationTier == .passiveSnapshot ? 1 : max(20, resolvedHostFPS)
    }

    private func cappedDrawableSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }

        if let maxDrawableSize = configuration.maxDrawableSize,
           maxDrawableSize.width <= 0 || maxDrawableSize.height <= 0 {
            return CGSize(width: alignedEven(size.width), height: alignedEven(size.height))
        }

        var width = size.width
        var height = size.height
        let aspectRatio = width / height
        let defaultMaxSize = CGSize(width: Self.maxDrawableWidth, height: Self.maxDrawableHeight)
        let maxSize = if let maxDrawableSize = configuration.maxDrawableSize,
                         maxDrawableSize.width > 0,
                         maxDrawableSize.height > 0 {
            CGSize(
                width: min(defaultMaxSize.width, maxDrawableSize.width),
                height: min(defaultMaxSize.height, maxDrawableSize.height)
            )
        } else {
            defaultMaxSize
        }

        if width > maxSize.width {
            width = maxSize.width
            height = width / aspectRatio
        }

        if height > maxSize.height {
            height = maxSize.height
            width = height * aspectRatio
        }

        return CGSize(width: alignedEven(width), height: alignedEven(height))
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }
}
