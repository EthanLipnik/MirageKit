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

    /// Stream ID for direct frame cache access (gesture tracking support)
    var streamID: StreamID? {
        didSet {
            renderState.reset()
            drawScheduled = false
            inFlightDraws = 0
            pendingDraw = false
            let previousID = registeredStreamID
            if let previousID, previousID != streamID { MirageClientRenderTrigger.shared.unregister(streamID: previousID) }
            registeredStreamID = streamID
            if let streamID {
                MirageClientRenderTrigger.shared.register(view: self, for: streamID)
                requestDraw()
            }
        }
    }

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero
    private var registeredStreamID: StreamID?
    private var renderingSuspended = false
    private var drawScheduled = false
    private var inFlightDraws: Int = 0
    private var pendingDraw = false

    private var maxInFlightDraws: Int {
        if let metalLayer = layer as? CAMetalLayer {
            return max(1, min(2, metalLayer.maximumDrawableCount - 1))
        }
        return 1
    }

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    override public init(frame: CGRect, device: MTLDevice?) {
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
    }

    override public func layout() {
        super.layout()
        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    deinit {
        let streamID = registeredStreamID
        Task { @MainActor in
            if let streamID { MirageClientRenderTrigger.shared.unregister(streamID: streamID) }
        }
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    private func reportDrawableMetricsIfChanged() {
        let rawDrawableSize = drawableSize
        let cappedDrawableSize = cappedDrawableSize(rawDrawableSize)
        if cappedDrawableSize != rawDrawableSize { drawableSize = cappedDrawableSize }
        if cappedDrawableSize != lastReportedDrawableSize, cappedDrawableSize.width > 0, cappedDrawableSize.height > 0 {
            lastReportedDrawableSize = cappedDrawableSize
            renderState.markNeedsRedraw()
            if cappedDrawableSize != rawDrawableSize {
                MirageLogger.renderer(
                    "Drawable size capped: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                        "\(cappedDrawableSize.width)x\(cappedDrawableSize.height) px (bounds: \(bounds.size))"
                )
            } else {
                MirageLogger
                    .renderer(
                        "Drawable size: \(cappedDrawableSize.width)x\(cappedDrawableSize.height) px (bounds: \(bounds.size))"
                    )
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

    override public func draw(_: CGRect) {
        // Pull-based frame update to avoid MainActor stalls during menu tracking/dragging.
        drawScheduled = false
        inFlightDraws += 1
        guard !renderingSuspended else {
            finishDraw()
            return
        }
        guard renderState.updateFrameIfNeeded(streamID: streamID) else {
            finishDraw()
            return
        }

        if let pixelFormatType = renderState.currentPixelFormatType { updateOutputFormatIfNeeded(pixelFormatType) }

        guard let drawable = currentDrawable,
              let pixelBuffer = renderState.currentPixelBuffer else {
            finishDraw()
            return
        }

        guard let renderer else {
            finishDraw()
            return
        }

        renderer.render(
            pixelBuffer: pixelBuffer,
            to: drawable,
            contentRect: renderState.currentContentRect,
            outputPixelFormat: colorPixelFormat,
            completion: { [weak self] in
                self?.finishDraw()
            }
        )
    }

    func suspendRendering() {
        renderingSuspended = true
    }

    func resumeRendering() {
        renderingSuspended = false
        renderState.markNeedsRedraw()
        requestDraw()
    }

    @MainActor
    func requestDraw() {
        guard !renderingSuspended else { return }
        if drawScheduled || inFlightDraws >= maxInFlightDraws {
            pendingDraw = true
            return
        }
        scheduleDraw()
    }

    @MainActor
    private func finishDraw() {
        inFlightDraws = max(0, inFlightDraws - 1)
        if pendingDraw, inFlightDraws < maxInFlightDraws {
            pendingDraw = false
            scheduleDraw()
        }
    }

    @MainActor
    private func scheduleDraw() {
        drawScheduled = true
        draw()
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
