//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  AVSampleBufferDisplayLayer-backed stream view on iOS and visionOS.
//

import MirageKit
#if os(iOS) || os(visionOS)
import AVFoundation
import Metal
import QuartzCore
import UIKit

public class MirageMetalView: UIView {
    // MARK: - Safe Area Override

    override public var safeAreaInsets: UIEdgeInsets { .zero }

    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    // MARK: - Public API

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    public var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            presenter.setStreamID(streamID)
            requestDraw()
        }
    }

    public var streamPresentationTier: StreamPresentationTier = .activeLive {
        didSet {
            guard streamPresentationTier != oldValue else { return }
            let requested = appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS
            applyDisplayRefreshRateLock(requested)
            requestDraw()
        }
    }

    // MARK: - Rendering State

    let preferencesObserver = MirageUserDefaultsObserver()
    lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)
    var displayLink: CADisplayLink?
    var presenter: MirageSampleBufferPresenter!

    var maxRenderFPS: Int = 60
    var appliedRefreshRateLock: Int = 0
    var lastReportedDrawableSize: CGSize = .zero

    static let maxDrawableWidth: CGFloat = 5120
    static let maxDrawableHeight: CGFloat = 2880

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("MirageMetalView requires AVSampleBufferDisplayLayer backing")
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

    public convenience init(frame: CGRect, device _: MTLDevice?) {
        self.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - UIView Lifecycle

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            startDisplayLinkIfNeeded()
            resumeRendering()
            requestDraw()
        } else {
            refreshRateMonitor.stop()
            stopDisplayLink()
            suspendRendering()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayRefreshRateLock(maxRenderFPS)
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()

        contentScaleFactor = effectiveScale
        let displayLayer = self.displayLayer
        displayLayer.frame = bounds
        displayLayer.contentsScale = effectiveScale

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    // MARK: - Public Controls

    public func suspendRendering() {
        suspendRendering(clearCurrentFrame: true)
    }

    public func resumeRendering() {
        presenter.setRenderingSuspended(false, clearCurrentFrame: false)
        requestDraw()
    }

    public var hasDisplayLayerFailure: Bool {
        presenter.hasDisplayLayerFailure
    }

    public func suspendRendering(clearCurrentFrame: Bool) {
        presenter.setRenderingSuspended(true, clearCurrentFrame: clearCurrentFrame)
    }

    // MARK: - Setup

    private func setup() {
        insetsLayoutMarginsFromSafeArea = false

        let displayLayer = self.displayLayer
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsScale = effectiveScale
        displayLayer.isOpaque = true
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        presenter = MirageSampleBufferPresenter(displayLayer: displayLayer)
        presenter.onFrameAvailable = { [weak self] in
            self?.requestDraw()
        }

        refreshRateMonitor.onOverrideChange = { [weak self] override in
            self?.applyRefreshRateOverride(override)
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    // MARK: - Draw Path

    func requestDraw() {
        let overrides = presentationTierOverrides()
        presenter.requestDraw(
            referenceTime: CACurrentMediaTime(),
            useFramePacing: false,
            presentationPolicyOverride: overrides.policy,
            maxFramesOverride: overrides.maxFrames
        )
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        let renderTargetFPS = streamPresentationTier == .activeLive ? maxRenderFPS : 1
        let interval = link.targetTimestamp - link.timestamp
        let displayRefreshRate = interval > 0 ? (1.0 / interval) : Double(renderTargetFPS)
        let overrides = presentationTierOverrides()
        presenter.displayLinkTick(
            referenceTime: link.timestamp,
            displayRefreshRate: displayRefreshRate,
            presentationPolicyOverride: overrides.policy,
            maxFramesOverride: overrides.maxFrames
        )
    }

    private func presentationTierOverrides() -> (policy: MirageRenderPresentationPolicy?, maxFrames: Int?) {
        if streamPresentationTier == .passiveSnapshot {
            return (.latest, 1)
        }
        return (nil, nil)
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        let requestedFPS = appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS
        let localFPS = streamPresentationTier == .activeLive ? requestedFPS : 1
        configureDisplayLinkRate(link, fps: localFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
#endif
