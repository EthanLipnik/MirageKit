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
import CoreGraphics
import QuartzCore

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

    var prefersLocalAspectFitPresentation: Bool = false {
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
    private let presentationDisplayTickHandlerBox = MirageDisplayTickHandlerBox()
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
            resumeRendering()
            applyRenderPreferences()
            observeScreenChanges()
        } else {
            suspendRendering()
            stopObservingScreenChanges()
        }
    }

    override public func layout() {
        super.layout()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        presentationPipeline.layoutDisplayLayer(bounds: bounds, scale: scale)
    }

    // MARK: - Public Controls

    func suspendRendering() {
        presentationPipeline.suspendRendering()
    }

    func resumeRendering() {
        presentationPipeline.resumeRendering()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        let displayLayer = self.displayLayer
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
                self?.updatePresentationDisplayClockFrameRate(targetFPS: targetFPS)
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
                logicalStreamID: streamID,
                mediaStreamID: streamID,
                contentRectOverride: contentRectOverride,
                presentationTier: streamPresentationTier,
                preferredMaximumRenderFPS: preferredMaximumRenderFPS,
                maxDrawableSize: maxDrawableSize,
                prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
                containerSizingMode: .viewBounds
            )
        )
    }

    // MARK: - Draw Path

    func requestImmediateSubmission() {
        presentationPipeline.requestImmediateSubmission()
    }

    private func startPresentationDisplayClockIfNeeded() {
        presentationPipeline.resumeRendering()
    }

    private func startPresentationDisplayClock(
        targetFPS: Int,
        tickHandler: @escaping MirageSampleBufferPresentationPipeline.DisplayTickHandler
    ) {
        presentationDisplayTickHandlerBox.set(tickHandler)
        let displayID = currentScreenDisplayID
        if let presentationDisplayClock {
            presentationDisplayClock.updateTargetFPS(targetFPS, displayID: displayID)
        } else {
            let clock = MirageMacDisplayClock()
            presentationDisplayClock = clock
            let handlerBox = presentationDisplayTickHandlerBox
            clock.start(targetFPS: targetFPS, displayID: displayID) { referenceTime in
                handlerBox.call(referenceTime)
            }
        }
    }

    private func stopPresentationDisplayClock() {
        presentationDisplayClock?.stop()
        presentationDisplayClock = nil
        presentationDisplayTickHandlerBox.set(nil)
    }

    private func updatePresentationDisplayClockFrameRate(targetFPS: Int) {
        presentationDisplayClock?.updateTargetFPS(targetFPS, displayID: currentScreenDisplayID)
    }

    private var currentScreenDisplayID: CGDirectDisplayID? {
        guard let displayID = window?.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(displayID.uint32Value)
    }

    // MARK: - Preferences

    private func applyRenderPreferences() {
        presentationPipeline.applyResolvedRenderFPS(
            preferredMaximumRenderFPS ?? MirageRenderPreferences.preferredMaximumRefreshRate()
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
                self?.presentationPipeline.requestImmediateSubmission()
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

private final class MirageDisplayTickHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?

    func set(_ handler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func call(_ referenceTime: CFTimeInterval) {
        let handler: MirageSampleBufferPresentationPipeline.DisplayTickHandler?
        lock.lock()
        handler = self.handler
        lock.unlock()
        handler?(referenceTime)
    }
}
#endif
