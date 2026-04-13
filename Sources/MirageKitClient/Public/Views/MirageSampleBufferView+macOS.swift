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
            requestImmediateSubmission()
        }
    }

    var streamPresentationTier: StreamPresentationTier = .activeLive {
        didSet {
            guard streamPresentationTier != oldValue else { return }
            presentationScheduler.setPresentationTier(streamPresentationTier)
            applyDisplayRefreshRateLock(appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS)
            requestImmediateSubmission()
        }
    }

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

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

    // MARK: - Rendering State

    private let preferencesObserver = MirageUserDefaultsObserver()
    private var activeDisplayLink: CADisplayLink?
    private var presenter: MirageSampleBufferPresenter!
    @MainActor private var presentationScheduler: MirageRenderPresentationScheduler!
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
            startDisplayLinkIfNeeded()
            resumeRendering()
            applyRenderPreferences()
            observeScreenChanges()
        } else {
            stopDisplayLink()
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
        presenter.setRenderingSuspended(true, clearCurrentFrame: true)
        presentationScheduler.setRenderingSuspended(true)
    }

    func resumeRendering() {
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        presentationScheduler.setRenderingSuspended(false)
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
                presenter?.submitPendingFrameIfPossible(referenceTime: referenceTime) ?? false
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

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        let renderTargetFPS = streamPresentationTier == .activeLive ? maxRenderFPS : 1
        let interval = link.targetTimestamp - link.timestamp
        _ = interval > 0 ? (1.0 / interval) : Double(renderTargetFPS)
        presentationScheduler.displayLinkTick(referenceTime: link.timestamp)
    }

    private func handleFrameAvailable() {
        presentationScheduler.handleFrameAvailable(referenceTime: CACurrentMediaTime())
    }

    private func startDisplayLinkIfNeeded() {
        guard activeDisplayLink == nil else { return }
        let link = self.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        let requestedFPS = appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS
        let localFPS = streamPresentationTier == .activeLive ? requestedFPS : 1
        configureDisplayLinkRate(link, fps: localFPS)
        link.add(to: .main, forMode: .common)
        activeDisplayLink = link
        presentationScheduler.setDisplayLinkActive(true)
    }

    private func stopDisplayLink() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        presentationScheduler.setDisplayLinkActive(false)
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
            MirageRenderPreferences.preferredMaximumRefreshRate()
        )
        maxRenderFPS = target
        presenter.setTargetFPS(target)
        applyDisplayRefreshRateLock(target)
        onRefreshRateOverrideChange?(target)
        requestImmediateSubmission()
    }

    private func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        let localFPS = streamPresentationTier == .passiveSnapshot ? 1 : clamped
        let changed = appliedRefreshRateLock != clamped
        appliedRefreshRateLock = clamped
        if let activeDisplayLink {
            configureDisplayLinkRate(activeDisplayLink, fps: localFPS)
        }

        guard changed else { return }
        MirageLogger.renderer(
            "Applied macOS render refresh lock: host=\(clamped)Hz local=\(localFPS)Hz tier=\(streamPresentationTier.rawValue)"
        )
    }

    private func configureDisplayLinkRate(_ displayLink: CADisplayLink, fps: Int) {
        let clamped = MirageRenderModePolicy.normalizedTargetFPS(fps)
        if #available(macOS 14.0, *) {
            let preferred = Float(clamped)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: preferred,
                maximum: preferred,
                preferred: preferred
            )
        }
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
