//
//  MirageMetalView+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(macOS)
import AppKit
import MetalKit

/// Metal-backed view for displaying streamed content on macOS
public class MirageMetalView: MTKView {
    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private let preferencesObserver = MirageUserDefaultsObserver()

    public var temporalDitheringEnabled: Bool = true {
        didSet {
            renderer?.setTemporalDitheringEnabled(temporalDitheringEnabled)
        }
    }

    /// Stream ID for direct frame cache access (gesture tracking support)
    var streamID: StreamID? {
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

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero
    private var registeredStreamID: StreamID?
    private var renderingSuspended = false

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

        do {
            renderer = try MetalRenderer(device: device)
        } catch {
            MirageLogger.error(.renderer, "Failed to create renderer: \(error)")
        }

        // Configure for low latency
        isPaused = true
        enableSetNeedsDisplay = false

        // P3 color space with 10-bit color for wide color gamut
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        colorPixelFormat = .bgr10a2Unorm

        applyRenderPreferences()
        startObservingPreferences()
    }

    public override func layout() {
        super.layout()
        reportDrawableMetricsIfChanged()
        if let streamID {
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
    }

    deinit {
        if let registeredStreamID {
            MirageRenderScheduler.shared.unregister(streamID: registeredStreamID)
        }
        stopObservingPreferences()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    private func reportDrawableMetricsIfChanged() {
        let drawableSize = self.drawableSize
        if drawableSize != lastReportedDrawableSize && drawableSize.width > 0 && drawableSize.height > 0 {
            lastReportedDrawableSize = drawableSize
            renderState.markNeedsRedraw()
            MirageLogger.renderer("Drawable size: \(drawableSize.width)x\(drawableSize.height) px (bounds: \(bounds.size))")
            onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: drawableSize))
        }
    }

    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let scale = window?.backingScaleFactor ?? 2.0
        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: bounds.size,
            scaleFactor: scale
        )
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update to avoid MainActor stalls during menu tracking/dragging.
        guard !renderingSuspended else { return }
        guard renderState.updateFrameIfNeeded(streamID: streamID, renderer: renderer) else { return }

        guard let drawable = currentDrawable,
              let texture = renderState.currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: renderState.currentContentRect)
    }

    private func applyRenderPreferences() {
        temporalDitheringEnabled = MirageRenderPreferences.temporalDitheringEnabled()
        if let streamID {
            renderState.markNeedsRedraw()
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
    }

    func suspendRendering() {
        renderingSuspended = true
    }

    func resumeRendering() {
        renderingSuspended = false
        renderState.markNeedsRedraw()
        if let streamID {
            MirageRenderScheduler.shared.signalFrame(for: streamID)
        }
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
