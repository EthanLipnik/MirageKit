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
        }
    }

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

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
        isPaused = false
        enableSetNeedsDisplay = false

        // Adapt to actual screen refresh rate (120Hz for ProMotion, 60Hz for standard)
        preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120

        // P3 color space with 10-bit color for wide color gamut
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        colorPixelFormat = .bgr10a2Unorm

        applyRenderPreferences()
        startObservingPreferences()
    }

    public override func layout() {
        super.layout()
        reportDrawableSizeIfChanged()
    }

    deinit {
        stopObservingPreferences()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    private func reportDrawableSizeIfChanged() {
        let drawableSize = self.drawableSize
        if drawableSize != lastReportedDrawableSize && drawableSize.width > 0 && drawableSize.height > 0 {
            lastReportedDrawableSize = drawableSize
            renderState.markNeedsRedraw()
            MirageLogger.renderer("Drawable size: \(drawableSize.width)x\(drawableSize.height) px (bounds: \(bounds.size))")
            onDrawableSizeChanged?(drawableSize)
        }
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update to avoid MainActor stalls during menu tracking/dragging.
        renderState.updateFrameIfNeeded(streamID: streamID, renderer: renderer)

        guard let drawable = currentDrawable,
              let texture = renderState.currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: renderState.currentContentRect)
    }

    private func applyRenderPreferences() {
        temporalDitheringEnabled = MirageRenderPreferences.temporalDitheringEnabled()
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
