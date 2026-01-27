//
//  MirageMetalView+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(macOS)
import AppKit
import CoreVideo
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
    var onDrawCompleted: (@Sendable () -> Void)?
    private var registeredStreamID: StreamID?
    private var renderingSuspended = false
    private var lastScheduledSignalTime: CFAbsoluteTime = 0

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

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
        framebufferOnly = true

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
        let streamID = registeredStreamID
        Task { @MainActor in
            if let streamID {
                MirageRenderScheduler.shared.unregister(streamID: streamID)
            }
        }
        stopObservingPreferences()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    private func reportDrawableMetricsIfChanged() {
        let rawDrawableSize = self.drawableSize
        let cappedDrawableSize = cappedDrawableSize(rawDrawableSize)
        if cappedDrawableSize != rawDrawableSize {
            self.drawableSize = cappedDrawableSize
        }
        if cappedDrawableSize != lastReportedDrawableSize && cappedDrawableSize.width > 0 && cappedDrawableSize.height > 0 {
            lastReportedDrawableSize = cappedDrawableSize
            renderState.markNeedsRedraw()
            if cappedDrawableSize != rawDrawableSize {
                MirageLogger.renderer(
                    "Drawable size capped: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                        "\(cappedDrawableSize.width)x\(cappedDrawableSize.height) px (bounds: \(bounds.size))"
                )
            } else {
                MirageLogger.renderer("Drawable size: \(cappedDrawableSize.width)x\(cappedDrawableSize.height) px (bounds: \(bounds.size))")
            }
            onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: cappedDrawableSize))
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

    private func cappedDrawableSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var width = size.width
        var height = size.height
        let aspectRatio = width / height

        if width > Self.maxDrawableWidth {
            width = Self.maxDrawableWidth
            height = width / aspectRatio
        }

        if height > Self.maxDrawableHeight {
            height = Self.maxDrawableHeight
            width = height * aspectRatio
        }

        return CGSize(
            width: alignedEven(width),
            height: alignedEven(height)
        )
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update to avoid MainActor stalls during menu tracking/dragging.
        guard !renderingSuspended else {
            onDrawCompleted?()
            return
        }
        guard renderState.updateFrameIfNeeded(streamID: streamID) else {
            onDrawCompleted?()
            return
        }

        if let pixelFormatType = renderState.currentPixelFormatType {
            updateOutputFormatIfNeeded(pixelFormatType)
        }

        guard let drawable = currentDrawable,
              let pixelBuffer = renderState.currentPixelBuffer else {
            onDrawCompleted?()
            return
        }

        guard let renderer else {
            onDrawCompleted?()
            return
        }

        renderer.render(
            pixelBuffer: pixelBuffer,
            to: drawable,
            contentRect: renderState.currentContentRect,
            outputPixelFormat: colorPixelFormat,
            completion: onDrawCompleted
        )
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

    @MainActor
    func noteScheduledDraw(signalTime: CFAbsoluteTime) {
        lastScheduledSignalTime = signalTime
    }

    @MainActor
    func requestDisplayLinkDraw(signalTime: CFAbsoluteTime) {
        noteScheduledDraw(signalTime: signalTime)
        draw()
    }

    private func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            self?.applyRenderPreferences()
        }
    }

    private func stopObservingPreferences() {
        preferencesObserver.stop()
    }

    private func updateOutputFormatIfNeeded(_ pixelFormatType: OSType) {
        let outputPixelFormat: MTLPixelFormat
        let colorSpace: CGColorSpace?

        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            outputPixelFormat = .bgra8Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        default:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        }

        guard colorPixelFormat != outputPixelFormat else { return }
        colorPixelFormat = outputPixelFormat
        colorspace = colorSpace
        renderState.markNeedsRedraw()
    }
}
#endif
