//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import MetalKit
import QuartzCore
import UIKit

/// Metal-backed view for displaying streamed content on iOS/visionOS
public class MirageMetalView: MTKView {

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal drawable fills entire screen
    public override var safeAreaInsets: UIEdgeInsets { .zero }

    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private let preferencesObserver = MirageUserDefaultsObserver()
    private lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view decides on a refresh rate override (60 or 120).
    public var onRefreshRateOverrideChange: ((Int) -> Void)? {
        didSet {
            refreshRateMonitor.onOverrideChange = onRefreshRateOverrideChange
        }
    }

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// The Metal view reads frames directly from MirageFrameCache using this ID,
    /// completely bypassing any Swift actor machinery that could block during gestures.
    public var streamID: StreamID? {
        didSet {
            renderState.reset()
            let previousID = registeredStreamID
            if let previousID, previousID != streamID {
                MirageRenderScheduler.shared.unregister(streamID: previousID)
            }
            registeredStreamID = streamID
            if let streamID {
                MirageRenderScheduler.shared.register(view: self, for: streamID)
                MirageRenderScheduler.shared.signalFrame(for: streamID)
            }
        }
    }

    private var registeredStreamID: StreamID?
    private var renderingSuspended = false

    public var temporalDitheringEnabled: Bool = true {
        didSet {
            renderer?.setTemporalDitheringEnabled(temporalDitheringEnabled)
        }
    }

    private var effectiveScale: CGFloat {
        let traitScale = traitCollection.displayScale
        if traitScale > 0 {
            return traitScale
        }
        // Default to 2.0 (Retina) if we can't determine the scale
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

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            resumeRendering()
            if let streamID {
                MirageRenderScheduler.shared.signalFrame(for: streamID)
            }
        } else {
            refreshRateMonitor.stop()
            suspendRendering()
        }
    }

    deinit {
        if let registeredStreamID {
            MirageRenderScheduler.shared.unregister(streamID: registeredStreamID)
        }
        stopObservingPreferences()
    }

    public func suspendRendering() {
        renderingSuspended = true
    }

    public func resumeRendering() {
        renderingSuspended = false
        renderState.markNeedsRedraw()
        if let streamID {
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
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

        reportDrawableMetricsIfChanged()
        if let streamID {
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    /// FIRST report is immediate (no debounce) to enable correct initial resolution
    /// Subsequent reports are sent immediately on significant changes to begin resize blur right away.
    private func reportDrawableMetricsIfChanged() {
        let drawableSize = self.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        // FIRST report should be IMMEDIATE - critical for getting initial resolution correct
        // This prevents the orientation mismatch where stream starts at portrait but drawable is landscape
        if lastReportedDrawableSize.width == 0 && lastReportedDrawableSize.height == 0 {
            lastReportedDrawableSize = drawableSize
            renderState.markNeedsRedraw()
            MirageLogger.renderer("Initial drawable size (immediate): \(drawableSize.width)x\(drawableSize.height) px")
            onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: drawableSize))
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
        onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: drawableSize))
    }

    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let scale = contentScaleFactor > 0 ? contentScaleFactor : effectiveScale
        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: bounds.size,
            scaleFactor: scale
        )
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update: read directly from global cache using stream ID
        // This completely bypasses Swift actor machinery that blocks during iOS gesture tracking.
        // CRITICAL: No closures, no weak references to @MainActor objects, just direct cache access.
        guard !renderingSuspended else { return }
        guard renderState.updateFrameIfNeeded(streamID: streamID, renderer: renderer) else { return }

        guard let drawable = currentDrawable,
              let texture = renderState.currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: renderState.currentContentRect)
    }

    private func applyRenderPreferences() {
        temporalDitheringEnabled = MirageRenderPreferences.temporalDitheringEnabled()
        let proMotionEnabled = MirageRenderPreferences.proMotionEnabled()
        refreshRateMonitor.isProMotionEnabled = proMotionEnabled
        updateFrameRatePreference(proMotionEnabled: proMotionEnabled)
        if let streamID {
            renderState.markNeedsRedraw()
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
    }

    private func updateFrameRatePreference(proMotionEnabled: Bool) {
        preferredFramesPerSecond = proMotionEnabled ? 120 : 60
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
