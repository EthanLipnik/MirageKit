//
//  MirageSampleBufferView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  AVSampleBufferDisplayLayer-backed stream view on iOS and visionOS.
//

import MirageKit
#if os(iOS) || os(visionOS)
import AVFoundation
import QuartzCore
import UIKit

public class MirageSampleBufferView: UIView {
    // MARK: - Safe Area Override

    public var ignoresSafeArea: Bool = true {
        didSet {
            guard ignoresSafeArea != oldValue else { return }
            setNeedsLayout()
        }
    }

    override public var safeAreaInsets: UIEdgeInsets {
        ignoresSafeArea ? .zero : super.safeAreaInsets
    }

    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    // MARK: - Public API

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    public var preferredMaximumRenderFPS: Int? {
        didSet {
            guard preferredMaximumRenderFPS != oldValue else { return }
            applyRenderConfiguration()
            applyRenderPreferences()
        }
    }

    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    public var prefersLocalAspectFitPresentation: Bool = false {
        didSet {
            guard prefersLocalAspectFitPresentation != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    public var contentRectOverride: CGRect? {
        didSet {
            guard contentRectOverride != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    public var streamID: StreamID? {
        didSet {
            applyRenderConfiguration()
        }
    }

    public var streamPresentationTier: StreamPresentationTier = .activeLive {
        didSet {
            guard streamPresentationTier != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    // MARK: - Rendering State

    let preferencesObserver = MirageUserDefaultsObserver()
    lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)
    var presentationPipeline: MirageSampleBufferPresentationPipeline!
    private var presentationDisplayLink: CADisplayLink?
    private var presentationDisplayTickHandler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("MirageSampleBufferView requires AVSampleBufferDisplayLayer backing")
        }
        return layer
    }

    private var effectiveScale: CGFloat {
        #if os(iOS)
        if let screen = window?.windowScene?.screen ?? window?.screen {
            let nativeScale = screen.nativeScale
            if nativeScale > 0 { return nativeScale }
            let screenScale = screen.scale
            if screenScale > 0 { return screenScale }
        }
        #endif
        let traitScale = traitCollection.displayScale
        if traitScale > 0 { return traitScale }
        return 2.0
    }

    // MARK: - Init

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        suspendRendering(clearCurrentFrame: true)
    }

    // MARK: - UIView Lifecycle

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            resumeRendering()
            requestImmediateSubmission()
        } else {
            refreshRateMonitor.stop()
            stopPresentationDisplayLink()
            suspendRendering()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        applyRenderConfiguration()
        if window != nil {
            refreshRateMonitor.start()
            resumeRendering()
        } else {
            stopPresentationDisplayLink()
        }
        applyRenderPreferences()
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()

        contentScaleFactor = effectiveScale
        presentationPipeline.layoutDisplayLayer(
            bounds: bounds,
            scale: effectiveScale,
            metricsContext: currentDrawableMetricsContext()
        )
    }

    // MARK: - Public Controls

    public func suspendRendering() {
        suspendRendering(clearCurrentFrame: true)
    }

    public func resumeRendering() {
        presentationPipeline.resumeRendering()
    }

    func activateStreamPresentation() {
        presentationPipeline.activateStreamPresentation()
    }

    func resumeRenderingAfterApplicationActivation(resetPresentationState: Bool) {
        presentationPipeline.resumeRenderingAfterApplicationActivation(resetPresentationState: resetPresentationState)
    }

    public var hasDisplayLayerFailure: Bool {
        presentationPipeline.hasDisplayLayerFailure
    }

    var currentPresentationReferenceSize: CGSize? {
        presentationPipeline.currentPresentationReferenceSize
    }

    func resolvedPresentedContentRect(in bounds: CGRect) -> CGRect {
        presentationPipeline.resolvedPresentedContentRect(in: bounds)
    }

    public func suspendRendering(clearCurrentFrame: Bool) {
        stopPresentationDisplayLink()
        presentationPipeline.suspendRendering(clearCurrentFrame: clearCurrentFrame)
    }

    // MARK: - Setup

    private func setup() {
        insetsLayoutMarginsFromSafeArea = false

        let displayLayer = self.displayLayer
        presentationPipeline = MirageSampleBufferPresentationPipeline(
            displayLayer: displayLayer,
            platformName: "iOS",
            canStartDisplayClock: { [weak self] in
                guard let self else { return false }
                return window != nil || superview != nil
            },
            startDisplayClock: { [weak self] targetFPS, tickHandler in
                self?.startPresentationDisplayLink(targetFPS: targetFPS, tickHandler: tickHandler)
            },
            stopDisplayClock: { [weak self] in
                self?.stopPresentationDisplayLink()
            },
            updateDisplayClockTargetFPS: { [weak self] targetFPS in
                self?.updatePresentationDisplayLinkFrameRate(targetFPS: targetFPS)
            },
            requestPlatformLayout: { [weak self] in
                self?.setNeedsLayout()
            }
        )
        presentationPipeline.setInitialVideoLayerState(scale: effectiveScale)
        presentationPipeline.onDrawableMetricsChanged = { [weak self] metrics in
            self?.onDrawableMetricsChanged?(metrics)
        }
        presentationPipeline.onRefreshRateOverrideChange = { [weak self] override in
            self?.onRefreshRateOverrideChange?(override)
        }
        applyRenderConfiguration()

        refreshRateMonitor.onOverrideChange = { [weak self] override in
            self?.applyRefreshRateOverride(override)
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    // MARK: - Draw Path

    func requestImmediateSubmission() {
        presentationPipeline.requestImmediateSubmission()
    }

    private func startPresentationDisplayLinkIfNeeded() {
        presentationPipeline.resumeRendering()
    }

    private func startPresentationDisplayLink(
        targetFPS: Int,
        tickHandler: @escaping MirageSampleBufferPresentationPipeline.DisplayTickHandler
    ) {
        presentationDisplayTickHandler = tickHandler
        guard presentationDisplayLink == nil else {
            updatePresentationDisplayLinkFrameRate(targetFPS: targetFPS)
            return
        }

        let displayLink = CADisplayLink(target: self, selector: #selector(handlePresentationDisplayLinkTick(_:)))
        presentationDisplayLink = displayLink
        updatePresentationDisplayLinkFrameRate(targetFPS: targetFPS)
        displayLink.add(to: .main, forMode: .common)
    }

    private func stopPresentationDisplayLink() {
        presentationDisplayLink?.invalidate()
        presentationDisplayLink = nil
        presentationDisplayTickHandler = nil
    }

    func updatePresentationDisplayLinkFrameRate(targetFPS: Int) {
        guard let presentationDisplayLink else { return }
        let localFPS = max(1, targetFPS)
        presentationDisplayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(localFPS),
            maximum: Float(localFPS),
            preferred: Float(localFPS)
        )
    }

    @objc private func handlePresentationDisplayLinkTick(_ displayLink: CADisplayLink) {
        let referenceTime = displayLink.targetTimestamp > 0 ? displayLink.targetTimestamp : CACurrentMediaTime()
        if let streamID {
            let delayMs = max(0, CACurrentMediaTime() - referenceTime) * 1000
            MirageRenderStreamStore.shared.noteDisplayTickMainRelay(for: streamID, delayMs: delayMs)
        }
        presentationDisplayTickHandler?(referenceTime)
    }
}
#endif
