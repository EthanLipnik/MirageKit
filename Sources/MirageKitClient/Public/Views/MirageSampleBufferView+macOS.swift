//
//  MirageSampleBufferView+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  AVSampleBufferDisplayLayer-backed stream view on macOS.
//

import MirageKit
#if os(macOS)
import AVFoundation
import AppKit
import QuartzCore

public class MirageSampleBufferView: NSView {
    // MARK: - Public API

    var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            presenter.setStreamID(streamID)
            presentationScheduler.setStreamID(streamID)
            if streamID == nil {
                stopPresentationDisplayClock()
            } else {
                startPresentationDisplayClockIfNeeded()
            }
            requestImmediateSubmission()
        }
    }

    var streamPresentationTier: StreamPresentationTier = .activeLive {
        didSet {
            guard streamPresentationTier != oldValue else { return }
            presentationScheduler.setPresentationTier(streamPresentationTier)
            applyDisplayRefreshRateLock(appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS)
            updatePresentationDisplayClockFrameRate()
            requestImmediateSubmission()
        }
    }

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    public var preferredMaximumRenderFPS: Int? {
        didSet {
            guard preferredMaximumRenderFPS != oldValue else { return }
            applyRenderPreferences()
        }
    }

    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            needsLayout = true
        }
    }

    var desktopPresentationReferenceSize: CGSize? {
        didSet {
            guard desktopPresentationReferenceSize != oldValue else { return }
            applyPresentationVideoGravity()
            needsLayout = true
        }
    }

    var contentRectOverride: CGRect? {
        didSet {
            guard contentRectOverride != oldValue else { return }
            presenter.setContentRectOverride(contentRectOverride)
            requestImmediateSubmission()
        }
    }

    // MARK: - Rendering State

    private let preferencesObserver = MirageUserDefaultsObserver()
    private var presenter: MirageSampleBufferPresenter!
    @MainActor private var presentationScheduler: MirageRenderPresentationScheduler!
    private var displayLayerReadinessRetryTask: Task<Void, Never>?
    private var presentationDisplayClock: MirageMacDisplayClock?
    private var maxRenderFPS: Int = 60
    private var appliedRefreshRateLock: Int = 0
    private var lastReportedDrawableSize: CGSize = .zero
    private var screenChangeObserver: NSObjectProtocol?

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    private var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("MirageSampleBufferView requires AVSampleBufferDisplayLayer backing")
        }
        return layer
    }

    // MARK: - Init

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Layer

    override public func makeBackingLayer() -> CALayer {
        AVSampleBufferDisplayLayer()
    }

    // MARK: - NSView Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            resumeRendering()
            applyRenderPreferences()
            startPresentationDisplayClockIfNeeded()
            observeScreenChanges()
        } else {
            stopDisplayLayerReadinessRetry()
            stopPresentationDisplayClock()
            suspendRendering()
            stopObservingScreenChanges()
        }
    }

    override public func layout() {
        super.layout()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let displayLayer = self.displayLayer
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale

        reportDrawableMetricsIfChanged()
        requestImmediateSubmission()
    }

    // MARK: - Public Controls

    func suspendRendering() {
        stopDisplayLayerReadinessRetry()
        stopPresentationDisplayClock()
        presenter.setRenderingSuspended(true, clearCurrentFrame: true)
        presentationScheduler.setRenderingSuspended(true)
    }

    func resumeRendering() {
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        presentationScheduler.setRenderingSuspended(false)
        startPresentationDisplayClockIfNeeded()
        requestImmediateSubmission()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        let displayLayer = self.displayLayer
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.wantsExtendedDynamicRangeContent = true
        displayLayer.isOpaque = true
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        displayLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        applyPresentationVideoGravity()

        presenter = MirageSampleBufferPresenter(displayLayer: displayLayer)
        presentationScheduler = MirageRenderPresentationScheduler(
            submit: { [weak presenter] referenceTime in
                presenter?.submitPendingFrameIfPossible(referenceTime: referenceTime) ?? .blocked
            },
            hasPendingFrame: { [weak presenter] in
                presenter?.hasPendingFrameForCurrentPresenter ?? false
            },
            onDisplayLayerNotReady: { [weak self] in
                self?.armDisplayLayerReadinessRetry()
            }
        )
        presentationScheduler.setPresentationTier(streamPresentationTier)
        presenter.onFrameAvailable = { [weak self] in
            self?.handleFrameAvailable()
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    private func applyPresentationVideoGravity() {
        displayLayer.videoGravity = usesAspectFitDesktopPresentation ? .resizeAspect : .resize
    }

    private var usesAspectFitDesktopPresentation: Bool {
        guard let desktopPresentationReferenceSize else { return false }
        return desktopPresentationReferenceSize.width > 0 && desktopPresentationReferenceSize.height > 0
    }

    // MARK: - Draw Path

    func requestImmediateSubmission() {
        presentationScheduler.requestImmediateSubmission(referenceTime: CACurrentMediaTime())
    }

    private func handleFrameAvailable() {
        presentationScheduler.handleFrameAvailable(referenceTime: CACurrentMediaTime())
    }

    private func startPresentationDisplayClockIfNeeded() {
        guard window != nil else { return }
        guard streamID != nil else { return }
        let localFPS = localPresentationFPS()
        presentationScheduler.setTargetFPS(localFPS)
        if let presentationDisplayClock {
            presentationDisplayClock.updateTargetFPS(localFPS)
        } else {
            let clock = MirageMacDisplayClock()
            presentationDisplayClock = clock
            clock.start(targetFPS: localFPS) { [weak self] referenceTime in
                Task { @MainActor [weak self] in
                    self?.presentationScheduler.handleDisplayTick(referenceTime: referenceTime)
                }
            }
        }
        presentationScheduler.setDisplayClockActive(true)
    }

    private func stopPresentationDisplayClock() {
        presentationDisplayClock?.stop()
        presentationDisplayClock = nil
        presentationScheduler.setDisplayClockActive(false)
    }

    private func updatePresentationDisplayClockFrameRate() {
        let localFPS = localPresentationFPS()
        presentationScheduler.setTargetFPS(localFPS)
        presentationDisplayClock?.updateTargetFPS(localFPS)
    }

    private func armDisplayLayerReadinessRetry() {
        guard displayLayerReadinessRetryTask == nil else { return }
        displayLayerReadinessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            displayLayerReadinessRetryTask = nil
            presentationScheduler.requestReadinessRetry(referenceTime: CACurrentMediaTime())
        }
    }

    private func stopDisplayLayerReadinessRetry() {
        displayLayerReadinessRetryTask?.cancel()
        displayLayerReadinessRetryTask = nil
    }

    // MARK: - Metrics

    private func reportDrawableMetricsIfChanged() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = cappedDrawableSize(
            CGSize(width: bounds.width * scale, height: bounds.height * scale)
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        guard pixelSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = pixelSize
        let metrics = MirageDrawableMetrics(
            pixelSize: pixelSize,
            viewSize: bounds.size,
            scaleFactor: scale
        )
        onDrawableMetricsChanged?(metrics)
    }

    private func cappedDrawableSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }

        if let maxDrawableSize, maxDrawableSize.width <= 0 || maxDrawableSize.height <= 0 {
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

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }

    private func resolvedMaxDrawableSize() -> CGSize {
        let defaultSize = CGSize(width: Self.maxDrawableWidth, height: Self.maxDrawableHeight)
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0 else {
            return defaultSize
        }

        return CGSize(
            width: min(defaultSize.width, maxDrawableSize.width),
            height: min(defaultSize.height, maxDrawableSize.height)
        )
    }

    // MARK: - Preferences

    private func applyRenderPreferences() {
        let target = MirageRenderModePolicy.normalizedTargetFPS(
            preferredMaximumRenderFPS ?? MirageRenderPreferences.preferredMaximumRefreshRate()
        )
        maxRenderFPS = target
        presenter.setTargetFPS(target)
        presentationScheduler.setTargetFPS(localPresentationFPS(hostFPS: target))
        applyDisplayRefreshRateLock(target)
        updatePresentationDisplayClockFrameRate()
        onRefreshRateOverrideChange?(target)
        requestImmediateSubmission()
    }

    private func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        let localFPS = localPresentationFPS(hostFPS: clamped)
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        presentationScheduler.setTargetFPS(localFPS)

        guard changed else { return }
        MirageLogger.renderer(
            "Applied macOS render refresh lock: host=\(clamped)Hz local=\(localFPS)Hz tier=\(streamPresentationTier.rawValue)"
        )
    }

    private func localPresentationFPS(hostFPS: Int? = nil) -> Int {
        let resolvedHostFPS = MirageRenderModePolicy.normalizedTargetFPS(
            hostFPS ?? (appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS)
        )
        return streamPresentationTier == .passiveSnapshot ? 1 : max(20, resolvedHostFPS)
    }

    private func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyRenderPreferences()
            }
        }
    }

    private func observeScreenChanges() {
        stopObservingScreenChanges()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyRenderPreferences()
            }
        }
    }

    private func stopObservingScreenChanges() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }
}
#endif
