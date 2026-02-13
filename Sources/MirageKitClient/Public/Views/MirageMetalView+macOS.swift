//
//  MirageMetalView+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(macOS)
import AppKit
import CoreVideo
import Metal
import QuartzCore

/// CAMetalLayer-backed view for displaying streamed content on macOS.
public class MirageMetalView: NSView {
    /// Stream ID used to read from the shared frame cache.
    var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            if let oldValue {
                MirageClientRenderTrigger.shared.unregister(streamID: oldValue)
            }
            if let streamID {
                MirageClientRenderTrigger.shared.register(view: self, for: streamID)
            }
            renderState.reset()
            renderScheduler.reset()
            renderAdmission.reset()
            renderSequenceGate.reset()
            drawableRetryTask?.cancel()
            drawableRetryTask = nil
            drawableRetryScheduled = false
            requestDraw()
        }
    }

    /// Callback when drawable metrics change - reports pixel size and scale factor.
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Optional cap for drawable pixel dimensions.
    /// Set a non-positive size to disable drawable capping.
    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            reportDrawableMetricsIfChanged()
            requestDraw()
        }
    }

    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private lazy var renderScheduler = MirageRenderScheduler(view: self)

    private let renderQueue = DispatchQueue(label: "com.mirage.client.render.macos", qos: .userInteractive)
    private let drawableAcquireQueue = DispatchQueue(
        label: "com.mirage.client.render.drawable.macos",
        qos: .userInteractive
    )
    private let renderAdmission = MirageRenderAdmissionCounter()
    private let renderSequenceGate = MirageRenderSequenceGate()

    private var renderingSuspended = false
    private var maxRenderFPS: Int = 60
    private var colorPixelFormat: MTLPixelFormat = .bgr10a2Unorm

    private var drawableRetryScheduled = false
    private var drawableRetryTask: Task<Void, Never>?
    private var noDrawableSkipsSinceLog: UInt64 = 0
    private var lastNoDrawableLogTime: CFAbsoluteTime = 0

    private var drawStatsStartTime: CFAbsoluteTime = 0
    private var drawStatsCount: UInt64 = 0
    private var drawStatsSignalDelayTotal: CFAbsoluteTime = 0
    private var drawStatsSignalDelayMax: CFAbsoluteTime = 0
    private var drawStatsDrawableWaitTotal: CFAbsoluteTime = 0
    private var drawStatsDrawableWaitMax: CFAbsoluteTime = 0
    private var drawStatsRenderLatencyTotal: CFAbsoluteTime = 0
    private var drawStatsRenderLatencyMax: CFAbsoluteTime = 0

    private var renderDiagnostics = RenderDiagnostics()
    private var lastScheduledSignalTime: CFAbsoluteTime = 0

    /// Last reported drawable size to avoid redundant callbacks.
    private var lastReportedDrawableSize: CGSize = .zero

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    private var metalLayer: CAMetalLayer {
        if let layer = layer as? CAMetalLayer {
            return layer
        }
        fatalError("MirageMetalView requires CAMetalLayer backing")
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public convenience init(frame frameRect: NSRect, device _: MTLDevice?) {
        self.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        layer = metalLayer

        guard let device = MTLCreateSystemDefaultDevice() else {
            MirageLogger.error(.renderer, "Failed to create Metal device")
            return
        }

        do {
            renderer = try MetalRenderer(device: device)
        } catch {
            MirageLogger.error(.renderer, "Failed to create renderer: \(error)")
        }

        metalLayer.device = device
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = colorPixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            renderScheduler.start()
            resumeRendering()
            requestDraw()
        } else {
            renderScheduler.stop()
            suspendRendering()
        }
    }

    override public func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let metalLayer = self.metalLayer
        metalLayer.frame = bounds
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }

        if bounds.width > 0, bounds.height > 0 {
            let rawDrawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let cappedSize = cappedDrawableSize(rawDrawableSize)
            if metalLayer.drawableSize != cappedSize {
                metalLayer.drawableSize = cappedSize
                renderState.markNeedsRedraw()
            }
        }

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    deinit {
        if let streamID {
            MirageClientRenderTrigger.shared.unregister(streamID: streamID)
        }
        drawableRetryTask?.cancel()
    }

    func suspendRendering() {
        renderingSuspended = true
        renderAdmission.reset()
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
        drawableRetryScheduled = false
    }

    func resumeRendering() {
        renderingSuspended = false
        renderState.markNeedsRedraw()
        requestDraw()
    }

    @MainActor
    func requestDraw() {
        guard !renderingSuspended else { return }
        lastScheduledSignalTime = CFAbsoluteTimeGetCurrent()
        renderDiagnostics.drawRequests &+= 1
        maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
        renderScheduler.requestRedraw()
        renderScheduler.requestDecodeDrivenTick()
    }

    @MainActor
    func renderSchedulerTick() {
        guard !renderingSuspended else { return }
        guard !drawableRetryScheduled else { return }

        let maximumDrawableCount = max(1, metalLayer.maximumDrawableCount)
        let effectiveCap = effectiveInFlightCap(maximumDrawableCount: maximumDrawableCount)
        guard renderAdmission.tryAcquire(limit: effectiveCap) else {
            renderDiagnostics.skipInFlightCap &+= 1
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        renderDiagnostics.drawAttempts &+= 1

        guard renderState.updateFrameIfNeeded(streamID: streamID) else {
            if let streamID, MirageFrameCache.shared.queueDepth(for: streamID) == 0 {
                renderDiagnostics.skipNoEntry &+= 1
            } else {
                renderDiagnostics.skipNoFrame &+= 1
            }
            _ = renderAdmission.release()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        if let pixelFormatType = renderState.currentPixelFormatType {
            updateOutputFormatIfNeeded(pixelFormatType)
        }

        guard let pixelBuffer = renderState.currentPixelBuffer else {
            renderDiagnostics.skipNoPixelBuffer &+= 1
            _ = renderAdmission.release()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        guard let renderer else {
            renderDiagnostics.skipNoRenderer &+= 1
            _ = renderAdmission.release()
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        let drawStartTime = CFAbsoluteTimeGetCurrent()
        let signalDelay = lastScheduledSignalTime > 0 ? max(0, drawStartTime - lastScheduledSignalTime) : 0
        let contentRect = renderState.currentContentRect
        let outputPixelFormat = colorPixelFormat
        let sequence = renderState.currentSequence
        let decodeTime = renderState.currentDecodeTime
        renderSequenceGate.noteRequested(sequence)
        let streamID = streamID
        let metalLayer = self.metalLayer
        let renderAdmission = self.renderAdmission

        drawableAcquireQueue.async { [weak self] in
            guard let self else { return }
            let drawableWaitStart = CFAbsoluteTimeGetCurrent()
            guard let drawable = metalLayer.nextDrawable() else {
                let wait = max(0, CFAbsoluteTimeGetCurrent() - drawableWaitStart)
                _ = self.renderAdmission.release()
                Task { @MainActor [weak self] in
                    self?.handleNoDrawable(signalDelay: signalDelay, drawableWait: wait)
                }
                return
            }

            let drawableWait = max(0, CFAbsoluteTimeGetCurrent() - drawableWaitStart)
            if self.renderSequenceGate.isStale(sequence) {
                _ = self.renderAdmission.release()
                Task { @MainActor [weak self] in
                    self?.handleStaleDrawableDrop(signalDelay: signalDelay, drawableWait: drawableWait)
                }
                return
            }
            self.renderQueue.async { [weak self] in
                guard let self else {
                    _ = renderAdmission.release()
                    return
                }
                renderer.render(
                    pixelBuffer: pixelBuffer,
                    to: drawable,
                    contentRect: contentRect,
                    outputPixelFormat: outputPixelFormat,
                    completion: { [weak self] wasPresented in
                        _ = renderAdmission.release()
                        Task { @MainActor [weak self] in
                            self?.handleRenderCompletion(
                                startTime: drawStartTime,
                                signalDelay: signalDelay,
                                drawableWait: drawableWait,
                                streamID: streamID,
                                sequence: sequence,
                                decodeTime: decodeTime,
                                wasPresented: wasPresented
                            )
                        }
                    }
                )
            }
        }
    }

    @MainActor
    private func handleNoDrawable(signalDelay: CFAbsoluteTime, drawableWait: CFAbsoluteTime) {
        renderDiagnostics.skipNoDrawable &+= 1
        noDrawableSkipsSinceLog &+= 1
        maybeLogDrawableStarvation()
        recordDrawCompletion(
            startTime: CFAbsoluteTimeGetCurrent(),
            signalDelay: signalDelay,
            drawableWait: drawableWait,
            rendered: false
        )
        scheduleDrawableRetry()
    }

    @MainActor
    private func handleStaleDrawableDrop(signalDelay: CFAbsoluteTime, drawableWait: CFAbsoluteTime) {
        renderDiagnostics.skipStale &+= 1
        recordDrawCompletion(
            startTime: CFAbsoluteTimeGetCurrent(),
            signalDelay: signalDelay,
            drawableWait: drawableWait,
            rendered: false
        )
        renderState.markNeedsRedraw()
        renderScheduler.requestRedraw()
    }

    @MainActor
    private func handleRenderCompletion(
        startTime: CFAbsoluteTime,
        signalDelay: CFAbsoluteTime,
        drawableWait: CFAbsoluteTime,
        streamID: StreamID?,
        sequence: UInt64,
        decodeTime: CFAbsoluteTime,
        wasPresented: Bool
    ) {
        if wasPresented {
            renderSequenceGate.notePresented(sequence)
            if let streamID {
                MirageFrameCache.shared.markPresented(sequence: sequence, for: streamID)
            }
            renderScheduler.notePresented(sequence: sequence, decodeTime: decodeTime)
        } else {
            renderState.markNeedsRedraw()
            renderScheduler.requestRedraw()
        }

        recordDrawCompletion(
            startTime: startTime,
            signalDelay: signalDelay,
            drawableWait: drawableWait,
            rendered: wasPresented
        )
    }

    @MainActor
    private func scheduleDrawableRetry() {
        guard !drawableRetryScheduled else { return }
        drawableRetryScheduled = true
        drawableRetryTask?.cancel()
        drawableRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(4))
            } catch {
                return
            }
            guard let self else { return }
            drawableRetryScheduled = false
            guard !renderingSuspended else { return }
            renderState.markNeedsRedraw()
            renderScheduler.requestRedraw()
        }
    }

    private func reportDrawableMetricsIfChanged() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let rawDrawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let cappedSize = cappedDrawableSize(rawDrawableSize)
        if cappedSize != rawDrawableSize {
            metalLayer.drawableSize = cappedSize
        }

        guard cappedSize.width > 0, cappedSize.height > 0 else { return }
        guard cappedSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = cappedSize
        renderState.markNeedsRedraw()

        if cappedSize != rawDrawableSize {
            MirageLogger
                .renderer(
                    "Drawable size capped: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                        "\(cappedSize.width)x\(cappedSize.height) px (bounds: \(bounds.size))"
                )
        } else {
            MirageLogger
                .renderer(
                    "Drawable size: \(cappedSize.width)x\(cappedSize.height) px (bounds: \(bounds.size))"
                )
        }

        onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: cappedSize))
    }

    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
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

        if let maxDrawableSize, maxDrawableSize.width <= 0 || maxDrawableSize.height <= 0 {
            return CGSize(width: alignedEven(width), height: alignedEven(height))
        }

        let aspectRatio = width / height
        let maxSize = resolvedMaxDrawableSize()

        if width > maxSize.width {
            width = maxSize.width
            height = width / aspectRatio
        }

        if height > maxSize.height {
            height = maxSize.height
            width = height * aspectRatio
        }

        return CGSize(width: alignedEven(width), height: alignedEven(height))
    }

    private func alignedEven(_ value: CGFloat) -> CGFloat {
        let rounded = CGFloat(Int(value.rounded()))
        let even = rounded - CGFloat(Int(rounded) % 2)
        return max(2, even)
    }

    private func resolvedMaxDrawableSize() -> CGSize {
        let defaultSize = CGSize(width: Self.maxDrawableWidth, height: Self.maxDrawableHeight)
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0 else {
            return defaultSize
        }

        return CGSize(
            width: min(defaultSize.width, maxDrawableSize.width),
            height: min(defaultSize.height, maxDrawableSize.height)
        )
    }

    private func maybeLogDrawableStarvation(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard MirageLogger.isEnabled(.renderer) else { return }
        if lastNoDrawableLogTime == 0 {
            lastNoDrawableLogTime = now
            return
        }
        guard now - lastNoDrawableLogTime >= 1.0 else { return }
        let elapsedText = (now - lastNoDrawableLogTime).formatted(.number.precision(.fractionLength(1)))
        MirageLogger
            .renderer(
                "Drawable unavailable on macOS view; retries=\(noDrawableSkipsSinceLog) in last \(elapsedText)s"
            )
        noDrawableSkipsSinceLog = 0
        lastNoDrawableLogTime = now
    }

    private func recordDrawCompletion(
        startTime: CFAbsoluteTime,
        signalDelay: CFAbsoluteTime,
        drawableWait: CFAbsoluteTime,
        rendered: Bool
    ) {
        if rendered {
            renderDiagnostics.drawRendered &+= 1
        }

        let now = CFAbsoluteTimeGetCurrent()
        let renderLatency = max(0, now - startTime)

        if drawStatsStartTime == 0 {
            drawStatsStartTime = now
        }

        drawStatsCount &+= 1
        drawStatsSignalDelayTotal += signalDelay
        drawStatsSignalDelayMax = max(drawStatsSignalDelayMax, signalDelay)
        drawStatsDrawableWaitTotal += drawableWait
        drawStatsDrawableWaitMax = max(drawStatsDrawableWaitMax, drawableWait)
        drawStatsRenderLatencyTotal += renderLatency
        drawStatsRenderLatencyMax = max(drawStatsRenderLatencyMax, renderLatency)

        let elapsed = now - drawStatsStartTime
        guard elapsed >= 2.0 else {
            maybeLogRenderDiagnostics(now: now)
            return
        }

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

            MirageLogger
                .renderer(
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

        let maximumDrawableCount = max(1, metalLayer.maximumDrawableCount)
        let effectiveCap = effectiveInFlightCap(maximumDrawableCount: maximumDrawableCount)
        let inFlight = renderAdmission.snapshot()

        let requestText = requestFPS.formatted(.number.precision(.fractionLength(1)))
        let drawAttemptText = drawAttemptFPS.formatted(.number.precision(.fractionLength(1)))
        let renderedText = renderedFPS.formatted(.number.precision(.fractionLength(1)))

        MirageLogger
            .renderer(
                "Render diag: drawRequests=\(requestText)fps drawAttempts=\(drawAttemptText)fps " +
                    "rendered=\(renderedText)fps skips(noEntry=\(renderDiagnostics.skipNoEntry) " +
                    "noFrame=\(renderDiagnostics.skipNoFrame) noDrawable=\(renderDiagnostics.skipNoDrawable) " +
                    "noRenderer=\(renderDiagnostics.skipNoRenderer) noPixelBuffer=\(renderDiagnostics.skipNoPixelBuffer) " +
                    "stale=\(renderDiagnostics.skipStale) " +
                    "cap=\(renderDiagnostics.skipInFlightCap)) admission(inFlight=\(inFlight)/\(effectiveCap) " +
                    "drawables=\(maximumDrawableCount) target=\(maxRenderFPS))"
            )

        renderDiagnostics.reset(now: now)
    }

    private func effectiveInFlightCap(maximumDrawableCount: Int? = nil) -> Int {
        let drawableCount = max(1, maximumDrawableCount ?? metalLayer.maximumDrawableCount)
        return MirageRenderAdmissionPolicy.effectiveInFlightCap(
            targetFPS: maxRenderFPS,
            maximumDrawableCount: drawableCount
        )
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
        metalLayer.pixelFormat = outputPixelFormat
        metalLayer.colorspace = colorSpace
        renderState.markNeedsRedraw()
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
    var skipStale: UInt64 = 0
    var skipInFlightCap: UInt64 = 0

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
        skipStale = 0
        skipInFlightCap = 0
    }
}
#endif
