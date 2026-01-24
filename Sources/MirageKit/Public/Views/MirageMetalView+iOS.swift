//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import MetalKit
import UIKit

/// Metal-backed view for displaying streamed content on iOS/visionOS
public class MirageMetalView: MTKView {

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal drawable fills entire screen
    public override var safeAreaInsets: UIEdgeInsets { .zero }

    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private let preferencesObserver = MirageUserDefaultsObserver()

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// The Metal view reads frames directly from MirageFrameCache using this ID,
    /// completely bypassing any Swift actor machinery that could block during gestures.
    public var streamID: StreamID? {
        didSet {
            renderState.reset()
        }
    }

    /// Custom display link so drawing continues in UITrackingRunLoopMode.
    private var displayLink: CADisplayLink?
    /// Optional per-frame callback for auxiliary updates (cursor refresh, etc.).
    public var onFrameTick: (() -> Void)?
    private var maxFramesPerSecondOverride: Int = 120 {
        didSet {
            updateDisplayLinkFrameRate()
        }
    }

    public var temporalDitheringEnabled: Bool = true {
        didSet {
            renderer?.setTemporalDitheringEnabled(temporalDitheringEnabled)
        }
    }

    private var effectiveScale: CGFloat {
        if let screenScale = window?.screen.nativeScale {
            return screenScale
        }
        // Default to 2.0 (Retina) if we can't determine the screen
        return 2.0
    }

    public override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        setup()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        guard let device else { return }

        // Ensure this view doesn't respect safe area insets
        insetsLayoutMarginsFromSafeArea = false

        do {
            renderer = try MetalRenderer(device: device)
        } catch {
            MirageLogger.error(.renderer, "Failed to create renderer: \(error)")
        }

        // Configure for low latency
        isPaused = true
        enableSetNeedsDisplay = false

        // Use 10-bit color with P3 color space for wide color gamut
        colorPixelFormat = .bgr10a2Unorm

        // CRITICAL: Set content scale for Retina rendering on iOS
        // Without this, MTKView creates a 1x drawable instead of native resolution
        contentScaleFactor = effectiveScale

        // Set P3 color space and scale on the underlying CAMetalLayer for proper color management
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.contentsScale = effectiveScale
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            updateDisplayLinkFrameRate()
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    deinit {
        stopDisplayLink()
        stopObservingPreferences()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = preferredFramesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Restart the display link if needed after returning from background.
    /// Called when app becomes active to ensure rendering resumes.
    public func restartDisplayLinkIfNeeded() {
        guard window != nil, displayLink == nil else { return }
        renderState.markNeedsRedraw()
        startDisplayLink()
    }

    /// Pause the display link when app enters background to avoid Metal GPU permission errors
    /// iOS doesn't allow GPU work from background state - attempting to render causes
    /// "Insufficient Permission to submit GPU work from background" errors
    public func pauseDisplayLink() {
        stopDisplayLink()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        onFrameTick?()
        draw()
    }

    private func resolvedPreferredFramesPerSecond() -> Int {
        let screenMax = window?.screen.maximumFramesPerSecond ?? maxFramesPerSecondOverride
        return min(maxFramesPerSecondOverride, screenMax)
    }

    private func updateDisplayLinkFrameRate() {
        let fps = max(1, resolvedPreferredFramesPerSecond())
        preferredFramesPerSecond = fps
        displayLink?.preferredFramesPerSecond = fps
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        // CRITICAL: Ensure scale factor is maintained - UIKit/SwiftUI may reset it
        let expectedScale = effectiveScale
        if contentScaleFactor != expectedScale {
            contentScaleFactor = expectedScale
        }
        if let metalLayer = layer as? CAMetalLayer, metalLayer.contentsScale != expectedScale {
            metalLayer.contentsScale = expectedScale
        }

        if bounds.width > 0, bounds.height > 0 {
            let expectedDrawableSize = CGSize(
                width: bounds.width * expectedScale,
                height: bounds.height * expectedScale
            )
            if drawableSize != expectedDrawableSize {
                drawableSize = expectedDrawableSize
                renderState.markNeedsRedraw()
            }
        }

        reportDrawableSizeIfChanged()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    /// FIRST report is immediate (no debounce) to enable correct initial resolution
    /// Subsequent reports are sent immediately on significant changes to begin resize blur right away.
    private func reportDrawableSizeIfChanged() {
        let drawableSize = self.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        // FIRST report should be IMMEDIATE - critical for getting initial resolution correct
        // This prevents the orientation mismatch where stream starts at portrait but drawable is landscape
        if lastReportedDrawableSize.width == 0 && lastReportedDrawableSize.height == 0 {
            lastReportedDrawableSize = drawableSize
            renderState.markNeedsRedraw()
            MirageLogger.renderer("Initial drawable size (immediate): \(drawableSize.width)x\(drawableSize.height) px")
            onDrawableSizeChanged?(drawableSize)
            return
        }

        // Skip micro-changes (< 2% difference or < 20 pixels) to prevent resize spam
        // when iPad dock appears/disappears during Stage Manager transitions
        let widthDiff = abs(drawableSize.width - lastReportedDrawableSize.width)
        let heightDiff = abs(drawableSize.height - lastReportedDrawableSize.height)
        let widthTolerance = lastReportedDrawableSize.width * 0.02
        let heightTolerance = lastReportedDrawableSize.height * 0.02

        // Only report if change exceeds 2% OR 20 pixels (whichever is larger)
        let significantWidthChange = widthDiff > max(widthTolerance, 20)
        let significantHeightChange = heightDiff > max(heightTolerance, 20)

        guard significantWidthChange || significantHeightChange else {
            return  // Skip - change is too small
        }

        lastReportedDrawableSize = drawableSize
        renderState.markNeedsRedraw()
        MirageLogger.renderer("Drawable size changed: \(drawableSize.width)x\(drawableSize.height) px")
        onDrawableSizeChanged?(drawableSize)
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update: read directly from global cache using stream ID
        // This completely bypasses Swift actor machinery that blocks during iOS gesture tracking.
        // CRITICAL: No closures, no weak references to @MainActor objects, just direct cache access.
        renderState.updateFrameIfNeeded(streamID: streamID, renderer: renderer)

        guard let drawable = currentDrawable,
              let texture = renderState.currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: renderState.currentContentRect)
    }

    private func applyRenderPreferences() {
        temporalDitheringEnabled = MirageRenderPreferences.temporalDitheringEnabled()

        let proMotionEnabled = MirageRenderPreferences.proMotionEnabled()
        maxFramesPerSecondOverride = proMotionEnabled ? 120 : 60
    }

    private func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            self?.applyRenderPreferences()
        }
    }

    private func stopObservingPreferences() {
        preferencesObserver.stop()
    }
}
#endif
