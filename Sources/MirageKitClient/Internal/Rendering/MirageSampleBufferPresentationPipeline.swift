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

struct MirageStreamRenderConfiguration: Equatable {
    var logicalStreamID: StreamID?
    var mediaStreamID: StreamID?
    var contentRectOverride: CGRect?
    var presentationTier: StreamPresentationTier
    var preferredMaximumRenderFPS: Int?
    var maxDrawableSize: CGSize?
    var prefersLocalAspectFitPresentation: Bool
    var containerSizingMode: MirageStreamContainerSizingMode

    var presentationStreamID: StreamID? {
        mediaStreamID ?? logicalStreamID
    }

    static let empty = MirageStreamRenderConfiguration(
        logicalStreamID: nil,
        mediaStreamID: nil,
        contentRectOverride: nil,
        presentationTier: .activeLive,
        preferredMaximumRenderFPS: nil,
        maxDrawableSize: nil,
        prefersLocalAspectFitPresentation: false,
        containerSizingMode: .contentLayout
    )
}

struct MirageDrawableMetricsContext: Equatable {
    var screenPointSize: CGSize?
    var screenScale: CGFloat?
    var screenNativePixelSize: CGSize?
    var screenNativeScale: CGFloat?

    static let empty = MirageDrawableMetricsContext()
}

@MainActor
final class MirageSampleBufferPresentationPipeline {
    typealias DisplayTickHandler = @Sendable (CFTimeInterval) -> Void
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

    private struct DisplayLayerLayoutState: Equatable {
        var bounds: CGRect
        var scale: CGFloat
    }

    private var presentationWorker: MirageSampleBufferPresentationWorker!
    private var configuration: MirageStreamRenderConfiguration = .empty
    private var maxRenderFPS: Int = 60
    private var appliedRefreshRateLock: Int = 0
    private var lastReportedDrawableMetrics: MirageDrawableMetrics?
    private var lastDisplayLayerLayoutState: DisplayLayerLayoutState?
    private var displayClockActive = false

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

        presentationWorker = MirageSampleBufferPresentationWorker(
            displayLayer: displayLayer,
            platformName: platformName
        )
        presentationWorker.setPresentationTier(configuration.presentationTier)
    }

    var streamID: StreamID? {
        configuration.presentationStreamID
    }

    var streamPresentationTier: StreamPresentationTier {
        configuration.presentationTier
    }

    var hasDisplayLayerFailure: Bool {
        presentationWorker.hasDisplayLayerFailure
    }

    var currentPresentationReferenceSize: CGSize? {
        presentationWorker.currentContentReferenceSize
    }

    func applyConfiguration(_ newConfiguration: MirageStreamRenderConfiguration) {
        let previousConfiguration = configuration
        configuration = newConfiguration

        if newConfiguration.prefersLocalAspectFitPresentation != previousConfiguration.prefersLocalAspectFitPresentation {
            applyPresentationVideoGravity()
        }

        if newConfiguration.contentRectOverride != previousConfiguration.contentRectOverride {
            presentationWorker.setContentRectOverride(newConfiguration.contentRectOverride)
        }

        if newConfiguration.maxDrawableSize != previousConfiguration.maxDrawableSize {
            lastReportedDrawableMetrics = nil
            requestPlatformLayout()
        }

        if newConfiguration.presentationTier != previousConfiguration.presentationTier {
            presentationWorker.setPresentationTier(newConfiguration.presentationTier)
            let requested = appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS
            applyDisplayRefreshRateLock(requested)
            updatePresentationDisplayClockFrameRate()
        }

        if newConfiguration.presentationStreamID != previousConfiguration.presentationStreamID {
            bindStreamForPresentation(newConfiguration.presentationStreamID)
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
        let layoutState = DisplayLayerLayoutState(
            bounds: bounds,
            scale: scale
        )
        let layoutChanged = lastDisplayLayerLayoutState != layoutState
        if layoutChanged {
            displayLayer.frame = bounds
            displayLayer.contentsScale = scale
            lastDisplayLayerLayoutState = layoutState
        }
        reportDrawableMetricsIfChanged(
            viewSize: bounds.size,
            scaleFactor: scale,
            metricsContext: metricsContext
        )
        if layoutChanged {
            requestImmediateSubmission()
        }
    }

    func suspendRendering(clearCurrentFrame: Bool = true) {
        stopPresentationDisplayClock()
        presentationWorker.setRenderingSuspended(true, clearCurrentFrame: clearCurrentFrame)
    }

    func resumeRendering() {
        presentationWorker.setRenderingSuspended(false, clearCurrentFrame: false)
        startPresentationDisplayClockIfNeeded()
        requestImmediateSubmission()
    }

    func activateStreamPresentation() {
        bindStreamForPresentation(configuration.presentationStreamID)
    }

    func resumeRenderingAfterApplicationActivation(resetPresentationState: Bool) {
        if resetPresentationState {
            presentationWorker.resetPresentationState()
        }
        resumeRendering()
    }

    func resolvedPresentedContentRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        guard configuration.prefersLocalAspectFitPresentation else { return bounds }
        return DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: currentPresentationReferenceSize,
            in: bounds
        )
    }

    func applyResolvedRenderFPS(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        maxRenderFPS = clamped
        presentationWorker.setTargetFPS(clamped)
        applyDisplayRefreshRateLock(clamped)
        onRefreshRateOverrideChange?(clamped)
    }

    func applyResolvedCadenceTarget(_ target: MirageStreamCadenceTarget) {
        maxRenderFPS = MirageRenderModePolicy.normalizedTargetFPS(target.displayFPS)
        presentationWorker.setCadenceTarget(target)
        applyDisplayRefreshRateLock(maxRenderFPS)
        onRefreshRateOverrideChange?(maxRenderFPS)
    }

    func requestImmediateSubmission() {
        presentationWorker.requestImmediateSubmission(referenceTime: CACurrentMediaTime())
    }

    func requestReadinessRetry() {
        guard !(displayClockActive && configuration.presentationTier == .activeLive) else { return }
        presentationWorker.requestReadinessRetry(referenceTime: CACurrentMediaTime())
    }

    // MARK: - Metrics

    @discardableResult
    func reportDrawableMetricsIfChanged(
        viewSize: CGSize,
        scaleFactor: CGFloat,
        metricsContext: MirageDrawableMetricsContext = .empty
    )
    -> MirageDrawableMetrics? {
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
        guard MirageDrawableMetrics.shouldReportChange(
            from: lastReportedDrawableMetrics,
            to: metrics
        ) else {
            return nil
        }

        lastReportedDrawableMetrics = metrics
        onDrawableMetricsChanged?(metrics)
        return metrics
    }

    // MARK: - Presentation

    private func applyPresentationVideoGravity() {
        displayLayer.videoGravity = configuration.prefersLocalAspectFitPresentation ? .resizeAspect : .resize
    }

    private func bindStreamForPresentation(_ streamID: StreamID?) {
        presentationWorker.setStreamID(streamID)
        presentationWorker.setRenderingSuspended(false, clearCurrentFrame: false)
        if streamID == nil {
            stopPresentationDisplayClock()
        } else {
            startPresentationDisplayClockIfNeeded()
        }
        requestImmediateSubmission()
    }

    private func startPresentationDisplayClockIfNeeded() {
        guard canStartDisplayClock() else { return }
        guard configuration.presentationStreamID != nil else { return }
        let localFPS = localPresentationFPS()
        presentationWorker.setTargetFPS(localFPS)
        presentationWorker.setDisplayClockActive(true)
        let worker = presentationWorker
        startDisplayClock(localFPS) { referenceTime in
            worker?.handleDisplayLinkTick(referenceTime: referenceTime)
        }
        displayClockActive = true
    }

    private func stopPresentationDisplayClock() {
        stopDisplayClock()
        displayClockActive = false
        presentationWorker.setDisplayClockActive(false)
    }

    private func updatePresentationDisplayClockFrameRate() {
        let localFPS = localPresentationFPS()
        presentationWorker.setTargetFPS(localFPS)
        updateDisplayClockTargetFPS(localFPS)
    }

    private func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        let localFPS = localPresentationFPS(hostFPS: clamped)
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        presentationWorker.setTargetFPS(localFPS)
        updatePresentationDisplayClockFrameRate()

        guard changed else { return }
        let streamLabel = configuration.presentationStreamID.map { "\($0)" } ?? "none"
        MirageLogger.renderer(
            "Applied \(platformName) render refresh lock: stream=\(streamLabel) host=\(clamped)Hz local=\(localFPS)Hz tier=\(configuration.presentationTier.rawValue)"
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
        let maxSize = resolvedMaxDrawableSize()

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

    private func resolvedMaxDrawableSize() -> CGSize {
        let defaultSize = CGSize(width: Self.maxDrawableWidth, height: Self.maxDrawableHeight)
        guard let maxDrawableSize = configuration.maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0 else {
            return defaultSize
        }

        return CGSize(
            width: min(defaultSize.width, maxDrawableSize.width),
            height: min(defaultSize.height, maxDrawableSize.height)
        )
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }
}
