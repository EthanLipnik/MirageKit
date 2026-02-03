//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import CoreVideo
import MetalKit
import QuartzCore
import UIKit

/// Metal-backed view for displaying streamed content on iOS/visionOS
public class MirageMetalView: MTKView {
    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal drawable fills entire screen
    override public var safeAreaInsets: UIEdgeInsets { .zero }

    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private let preferencesObserver = MirageUserDefaultsObserver()
    private lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// The Metal view reads frames directly from MirageFrameCache using this ID,
    /// completely bypassing any Swift actor machinery that could block during gestures.
    public var streamID: StreamID? {
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

    private var registeredStreamID: StreamID?
    private var renderingSuspended = false
    private var lastScheduledSignalTime: CFAbsoluteTime = 0
    private var drawStatsStartTime: CFAbsoluteTime = 0
    private var drawStatsCount: UInt64 = 0
    private var drawStatsSignalDelayTotal: CFAbsoluteTime = 0
    private var drawStatsSignalDelayMax: CFAbsoluteTime = 0
    private var drawStatsDrawableWaitTotal: CFAbsoluteTime = 0
    private var drawStatsDrawableWaitMax: CFAbsoluteTime = 0
    private var drawStatsRenderLatencyTotal: CFAbsoluteTime = 0
    private var drawStatsRenderLatencyMax: CFAbsoluteTime = 0
    private var drawableRetryScheduled = false
    private var renderDiagnostics = RenderDiagnostics()
    private var drawScheduled = false
    private var inFlightDraws: Int = 0
    private var pendingDraw = false

    private var effectiveScale: CGFloat {
        let traitScale = traitCollection.displayScale
        if traitScale > 0 { return traitScale }
        // Default to 2.0 (Retina) if we can't determine the scale
        return 2.0
    }

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880
    private var maxInFlightDraws: Int {
        if let metalLayer = layer as? CAMetalLayer {
            return max(1, min(2, metalLayer.maximumDrawableCount - 1))
        }
        return 1
    }

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
        framebufferOnly = true
        preferredFramesPerSecond = 120

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
            // Allow nextDrawable to time out rather than block indefinitely.
            metalLayer.allowsNextDrawableTimeout = true
            metalLayer.maximumDrawableCount = 3
        }

        refreshRateMonitor.onOverrideChange = { [weak self] override in
            self?.applyRefreshRateOverride(override)
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            resumeRendering()
            requestDraw()
        } else {
            refreshRateMonitor.stop()
            suspendRendering()
        }
    }

    deinit {
        let streamID = registeredStreamID
        Task { @MainActor in
            if let streamID { MirageClientRenderTrigger.shared.unregister(streamID: streamID) }
        }
        stopObservingPreferences()
    }

    public func suspendRendering() {
        renderingSuspended = true
    }

    public func resumeRendering() {
        renderingSuspended = false
        renderState.markNeedsRedraw()
        requestDraw()
    }

    @MainActor
    func noteScheduledDraw(signalTime: CFAbsoluteTime) {
        lastScheduledSignalTime = signalTime
    }

    @MainActor
    func requestDraw() {
        guard !renderingSuspended else { return }
        noteScheduledDraw(signalTime: CFAbsoluteTimeGetCurrent())
        renderDiagnostics.drawRequests &+= 1
        maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
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

    override public func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()

        // CRITICAL: Ensure scale factor is maintained - UIKit/SwiftUI may reset it
        let expectedScale = effectiveScale
        if contentScaleFactor != expectedScale { contentScaleFactor = expectedScale }
        if let metalLayer = layer as? CAMetalLayer, metalLayer.contentsScale != expectedScale { metalLayer.contentsScale = expectedScale }

        if bounds.width > 0, bounds.height > 0 {
            let rawDrawableSize = CGSize(
                width: bounds.width * expectedScale,
                height: bounds.height * expectedScale
            )
            let expectedDrawableSize = cappedDrawableSize(rawDrawableSize)
            if drawableSize != expectedDrawableSize {
                drawableSize = expectedDrawableSize
                renderState.markNeedsRedraw()
                if expectedDrawableSize != rawDrawableSize {
                    MirageLogger.renderer(
                        "Drawable size capped: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                            "\(expectedDrawableSize.width)x\(expectedDrawableSize.height) px"
                    )
                }
            }
        }

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    /// FIRST report is immediate (no debounce) to enable correct initial resolution
    /// Subsequent reports are sent immediately on significant changes to begin resize blur right away.
    private func reportDrawableMetricsIfChanged() {
        let drawableSize = drawableSize
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

        // Skip - change is too small
        guard significantWidthChange || significantHeightChange else { return }

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
        // Pull-based frame update: read directly from global cache using stream ID
        // This completely bypasses Swift actor machinery that blocks during iOS gesture tracking.
        // CRITICAL: No closures, no weak references to @MainActor objects, just direct cache access.
        renderDiagnostics.drawAttempts &+= 1
        drawScheduled = false
        inFlightDraws += 1
        guard !renderingSuspended else {
            finishDraw()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }
        let activeStreamID = streamID
        guard renderState.updateFrameIfNeeded(streamID: activeStreamID) else {
            if let activeStreamID, MirageFrameCache.shared.getEntry(for: activeStreamID) == nil {
                renderDiagnostics.skipNoEntry &+= 1
            } else {
                renderDiagnostics.skipNoFrame &+= 1
            }
            finishDraw()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        if let pixelFormatType = renderState.currentPixelFormatType { updateOutputFormatIfNeeded(pixelFormatType) }

        let drawStartTime = CFAbsoluteTimeGetCurrent()
        let signalDelay = lastScheduledSignalTime > 0 ? max(0, drawStartTime - lastScheduledSignalTime) : 0

        guard let pixelBuffer = renderState.currentPixelBuffer else {
            renderDiagnostics.skipNoPixelBuffer &+= 1
            finishDraw()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        let drawableStartTime = CFAbsoluteTimeGetCurrent()
        let drawable: CAMetalDrawable? = if let metalLayer = layer as? CAMetalLayer {
            metalLayer.nextDrawable()
        } else {
            currentDrawable
        }
        let drawableWait = max(0, CFAbsoluteTimeGetCurrent() - drawableStartTime)

        guard let drawable else {
            renderDiagnostics.skipNoDrawable &+= 1
            scheduleDrawableRetry()
            finishDraw()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        guard let renderer else {
            renderDiagnostics.skipNoRenderer &+= 1
            finishDraw()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        renderer.render(
            pixelBuffer: pixelBuffer,
            to: drawable,
            contentRect: renderState.currentContentRect,
            outputPixelFormat: colorPixelFormat,
            completion: { [weak self] in
                guard let self else { return }
                recordDrawCompletion(
                    startTime: drawStartTime,
                    signalDelay: signalDelay,
                    drawableWait: drawableWait
                )
                finishDraw()
            }
        )
    }

    private func scheduleDrawableRetry() {
        guard !drawableRetryScheduled, let streamID else { return }
        drawableRetryScheduled = true
        let retryStreamID = streamID
        // Small backoff prevents tight loops when CAMetalLayer is out of drawables.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
            guard let self else { return }
            drawableRetryScheduled = false
            guard self.streamID == retryStreamID else { return }
            renderState.markNeedsRedraw()
            requestDraw()
        }
    }

    private func recordDrawCompletion(
        startTime: CFAbsoluteTime,
        signalDelay: CFAbsoluteTime,
        drawableWait: CFAbsoluteTime
    ) {
        renderDiagnostics.drawRendered &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        let renderLatency = max(0, now - startTime)

        if drawStatsStartTime == 0 { drawStatsStartTime = now }

        drawStatsCount &+= 1
        drawStatsSignalDelayTotal += signalDelay
        drawStatsSignalDelayMax = max(drawStatsSignalDelayMax, signalDelay)
        drawStatsDrawableWaitTotal += drawableWait
        drawStatsDrawableWaitMax = max(drawStatsDrawableWaitMax, drawableWait)
        drawStatsRenderLatencyTotal += renderLatency
        drawStatsRenderLatencyMax = max(drawStatsRenderLatencyMax, renderLatency)

        let elapsed = now - drawStatsStartTime
        guard elapsed >= 2.0 else { return }

        if MirageLogger.isEnabled(.renderer) {
            let count = max(1, Double(drawStatsCount))
            let fps = count / elapsed
            let signalDelayAvgMs = (drawStatsSignalDelayTotal / count) * 1000
            let signalDelayMaxMs = drawStatsSignalDelayMax * 1000
            let drawableWaitAvgMs = (drawStatsDrawableWaitTotal / count) * 1000
            let drawableWaitMaxMs = drawStatsDrawableWaitMax * 1000
            let renderLatencyAvgMs = (drawStatsRenderLatencyTotal / count) * 1000
            let renderLatencyMaxMs = drawStatsRenderLatencyMax * 1000

            let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
            let signalDelayAvgText = signalDelayAvgMs.formatted(.number.precision(.fractionLength(1)))
            let signalDelayMaxText = signalDelayMaxMs.formatted(.number.precision(.fractionLength(1)))
            let drawableWaitAvgText = drawableWaitAvgMs.formatted(.number.precision(.fractionLength(1)))
            let drawableWaitMaxText = drawableWaitMaxMs.formatted(.number.precision(.fractionLength(1)))
            let renderLatencyAvgText = renderLatencyAvgMs.formatted(.number.precision(.fractionLength(1)))
            let renderLatencyMaxText = renderLatencyMaxMs.formatted(.number.precision(.fractionLength(1)))

            MirageLogger.renderer(
                "Render timings: fps=\(fpsText) signalDelay=\(signalDelayAvgText)/\(signalDelayMaxText)ms " +
                    "drawableWait=\(drawableWaitAvgText)/\(drawableWaitMaxText)ms " +
                    "renderLatency=\(renderLatencyAvgText)/\(renderLatencyMaxText)ms"
            )
        }

        maybeLogRenderDiagnostics(now: now)

        drawStatsStartTime = now
        drawStatsCount = 0
        drawStatsSignalDelayTotal = 0
        drawStatsSignalDelayMax = 0
        drawStatsDrawableWaitTotal = 0
        drawStatsDrawableWaitMax = 0
        drawStatsRenderLatencyTotal = 0
        drawStatsRenderLatencyMax = 0
    }

    private func maybeLogRenderDiagnostics(now: CFAbsoluteTime) {
        guard MirageLogger.isEnabled(.renderer) else { return }
        if renderDiagnostics.startTime == 0 {
            renderDiagnostics.startTime = now
            return
        }
        let elapsed = now - renderDiagnostics.startTime
        guard elapsed >= 2.0 else { return }

        let safeElapsed = max(0.001, elapsed)
        let requestFPS = Double(renderDiagnostics.drawRequests) / safeElapsed
        let drawAttemptFPS = Double(renderDiagnostics.drawAttempts) / safeElapsed
        let renderedFPS = Double(renderDiagnostics.drawRendered) / safeElapsed

        let requestText = requestFPS.formatted(.number.precision(.fractionLength(1)))
        let drawAttemptText = drawAttemptFPS.formatted(.number.precision(.fractionLength(1)))
        let renderedText = renderedFPS.formatted(.number.precision(.fractionLength(1)))

        MirageLogger.renderer(
            "Render diag: drawRequests=\(requestText)fps drawAttempts=\(drawAttemptText)fps " +
                "rendered=\(renderedText)fps skips(noEntry=\(renderDiagnostics.skipNoEntry) " +
                "noFrame=\(renderDiagnostics.skipNoFrame) noDrawable=\(renderDiagnostics.skipNoDrawable) " +
                "noRenderer=\(renderDiagnostics.skipNoRenderer) noPixelBuffer=\(renderDiagnostics.skipNoPixelBuffer))"
        )

        renderDiagnostics.reset(now: now)
    }

    private func applyRenderPreferences() {
        let proMotionEnabled = MirageRenderPreferences.proMotionEnabled()
        refreshRateMonitor.isProMotionEnabled = proMotionEnabled
        updateFrameRatePreference(proMotionEnabled: proMotionEnabled)
        renderState.markNeedsRedraw()
        requestDraw()
    }

    private func updateFrameRatePreference(proMotionEnabled: Bool) {
        let desired = proMotionEnabled ? 120 : 60
        applyRefreshRateOverride(desired)
    }

    private func applyRefreshRateOverride(_ override: Int) {
        let clamped = override >= 120 ? 120 : 60
        preferredFramesPerSecond = 120
        onRefreshRateOverrideChange?(clamped)
    }

    private func updateOutputFormatIfNeeded(_ pixelFormatType: OSType) {
        let outputPixelFormat: MTLPixelFormat
        let colorSpace: CGColorSpace?
        let wantsHDR: Bool

        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            outputPixelFormat = .bgra8Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            wantsHDR = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            wantsHDR = true
        default:
            outputPixelFormat = .bgr10a2Unorm
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            wantsHDR = true
        }

        guard colorPixelFormat != outputPixelFormat else { return }
        colorPixelFormat = outputPixelFormat
        renderState.markNeedsRedraw()

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.colorspace = colorSpace
            metalLayer.wantsExtendedDynamicRangeContent = wantsHDR
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

private struct RenderDiagnostics {
    var startTime: CFAbsoluteTime = 0
    var drawRequests: UInt64 = 0
    var drawAttempts: UInt64 = 0
    var drawRendered: UInt64 = 0
    var skipNoEntry: UInt64 = 0
    var skipNoFrame: UInt64 = 0
    var skipNoDrawable: UInt64 = 0
    var skipNoRenderer: UInt64 = 0
    var skipNoPixelBuffer: UInt64 = 0

    mutating func reset(now: CFAbsoluteTime) {
        startTime = now
        drawRequests = 0
        drawAttempts = 0
        drawRendered = 0
        skipNoEntry = 0
        skipNoFrame = 0
        skipNoDrawable = 0
        skipNoRenderer = 0
        skipNoPixelBuffer = 0
    }
}
#endif
