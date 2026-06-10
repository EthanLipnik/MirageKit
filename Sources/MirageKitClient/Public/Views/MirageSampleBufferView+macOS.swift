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

/// AppKit view that renders decoded stream frames through an `AVSampleBufferDisplayLayer`.
public class MirageSampleBufferView: NSView {
    // MARK: - Public API

    var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    var streamPresentationTier: StreamPresentationTier = .activeLive {
        didSet {
            guard streamPresentationTier != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    /// Callback fired when drawable pixel size or scale changes.
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    /// Callback fired when the renderer requests a platform refresh-rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Host-authoritative maximum render frame rate for this stream.
    public var preferredMaximumRenderFPS: Int? {
        didSet {
            guard preferredMaximumRenderFPS != oldValue else { return }
            applyRenderConfiguration()
            applyRenderPreferences()
        }
    }

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    var prefersLocalAspectFitPresentation: Bool = true {
        didSet {
            guard prefersLocalAspectFitPresentation != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    var contentRectOverride: CGRect? {
        didSet {
            guard contentRectOverride != oldValue else { return }
            applyRenderConfiguration()
        }
    }

    // MARK: - Rendering State

    private let preferencesObserver = MirageUserDefaultsObserver()
    private var presentationPipeline: MirageSampleBufferPresentationPipeline!
    private var presentationDisplayClock: MirageMacDisplayClock?
    private var presentationDisplayTickHandler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?
    private var screenChangeObserver: NSObjectProtocol?

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
            presentationPipeline.resumeRendering()
            applyRenderPreferences()
            observeScreenChanges()
        } else {
            presentationPipeline.suspendRendering()
            stopObservingScreenChanges()
        }
    }

    override public func layout() {
        super.layout()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        presentationPipeline.layoutDisplayLayer(bounds: bounds, scale: scale)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        let displayLayer = displayLayer
        presentationPipeline = MirageSampleBufferPresentationPipeline(
            displayLayer: displayLayer,
            platformName: "macOS",
            canStartDisplayClock: { [weak self] in
                self?.window != nil
            },
            startDisplayClock: { [weak self] targetFPS, tickHandler in
                self?.startPresentationDisplayClock(targetFPS: targetFPS, tickHandler: tickHandler)
            },
            stopDisplayClock: { [weak self] in
                self?.stopPresentationDisplayClock()
            },
            updateDisplayClockTargetFPS: { [weak self] targetFPS in
                self?.presentationDisplayClock?.updateTargetFPS(targetFPS)
            },
            requestPlatformLayout: { [weak self] in
                self?.needsLayout = true
            }
        )
        presentationPipeline.setInitialVideoLayerState(
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        )
        presentationPipeline.onDrawableMetricsChanged = { [weak self] metrics in
            self?.onDrawableMetricsChanged?(metrics)
        }
        presentationPipeline.onRefreshRateOverrideChange = { [weak self] override in
            self?.onRefreshRateOverrideChange?(override)
        }
        applyRenderConfiguration()

        applyRenderPreferences()
        startObservingPreferences()
    }

    private func applyRenderConfiguration() {
        presentationPipeline.applyConfiguration(
            MirageStreamRenderConfiguration(
                mediaStreamID: streamID,
                contentRectOverride: contentRectOverride,
                presentationTier: streamPresentationTier,
                maxDrawableSize: maxDrawableSize,
                prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation
            )
        )
    }

    private func startPresentationDisplayClock(
        targetFPS: Int,
        tickHandler: @escaping MirageSampleBufferPresentationPipeline.DisplayTickHandler
    ) {
        presentationDisplayTickHandler = tickHandler
        if let presentationDisplayClock {
            presentationDisplayClock.updateTargetFPS(targetFPS)
        } else {
            let clock = MirageMacDisplayClock()
            presentationDisplayClock = clock
            clock.start(targetFPS: targetFPS) { [weak self] referenceTime in
                Task { @MainActor [weak self] in
                    self?.presentationDisplayTickHandler?(referenceTime)
                }
            }
        }
    }

    private func stopPresentationDisplayClock() {
        presentationDisplayClock?.stop()
        presentationDisplayClock = nil
        presentationDisplayTickHandler = nil
    }

    // MARK: - Preferences

    private func applyRenderPreferences() {
        presentationPipeline.applyResolvedRenderFPS(
            preferredMaximumRenderFPS ?? MirageRenderPreferences.preferredMaximumRefreshRate
        )
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
