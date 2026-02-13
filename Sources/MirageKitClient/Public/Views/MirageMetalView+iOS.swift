//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import CoreVideo
import Metal
import QuartzCore
import UIKit

/// CAMetalLayer-backed view for displaying streamed content on iOS/visionOS.
public class MirageMetalView: UIView {
    // MARK: - Safe Area Override

    override public var safeAreaInsets: UIEdgeInsets { .zero }

    override public class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    /// Callback when drawable metrics change - reports pixel size and scale factor.
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Optional cap for drawable pixel dimensions.
    /// Set a non-positive size to disable drawable capping.
    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Stream ID used to read from the shared frame cache.
    public var streamID: StreamID? {
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

    private var renderer: MetalRenderer?
    private let renderState = MirageMetalRenderState()
    private let preferencesObserver = MirageUserDefaultsObserver()
    private lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)
    private lazy var renderScheduler = MirageRenderScheduler(view: self)

    private let renderQueue = DispatchQueue(label: "com.mirage.client.render.ios", qos: .userInteractive)
    private let drawableAcquireQueue = DispatchQueue(
        label: "com.mirage.client.render.drawable.ios",
        qos: .userInteractive
    )
    private let renderAdmission = MirageRenderAdmissionCounter()
    private let renderSequenceGate = MirageRenderSequenceGate()

    private var renderingSuspended = false
    private var maxRenderFPS: Int = 120
    private var appliedRefreshRateLock: Int = 0
    private var colorPixelFormat: MTLPixelFormat = .bgr10a2Unorm

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
    private var drawableRetryTask: Task<Void, Never>?
    private var noDrawableSkipsSinceLog: UInt64 = 0
    private var lastNoDrawableLogTime: CFAbsoluteTime = 0
    private var renderDiagnostics = RenderDiagnostics()

    /// Last reported drawable size to avoid redundant callbacks.
    private var lastReportedDrawableSize: CGSize = .zero

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    private var effectiveScale: CGFloat {
        let traitScale = traitCollection.displayScale
        if traitScale > 0 { return traitScale }
        return 2.0
    }

    private var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else {
            fatalError("MirageMetalView requires CAMetalLayer backing")
        }
        return layer
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public convenience init(frame: CGRect, device _: MTLDevice?) {
        self.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        insetsLayoutMarginsFromSafeArea = false

        guard let device = MTLCreateSystemDefaultDevice() else {
            MirageLogger.error(.renderer, "Failed to create Metal device")
            return
        }

        do {
            renderer = try MetalRenderer(device: device)
        } catch {
            MirageLogger.error(.renderer, "Failed to create renderer: \(error)")
        }

        contentScaleFactor = effectiveScale

        let metalLayer = self.metalLayer
        metalLayer.device = device
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = colorPixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.contentsScale = effectiveScale
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = 3

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
            renderScheduler.start()
            resumeRendering()
            requestDraw()
        } else {
            refreshRateMonitor.stop()
            renderScheduler.stop()
            suspendRendering()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayRefreshRateLock(maxRenderFPS)
    }

    @MainActor deinit {
        if let streamID {
            MirageClientRenderTrigger.shared.unregister(streamID: streamID)
        }
        stopObservingPreferences()
        drawableRetryTask?.cancel()
    }

    override public func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()

        let scale = effectiveScale
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }

        let metalLayer = self.metalLayer
        metalLayer.frame = bounds
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }

        if bounds.width > 0, bounds.height > 0 {
            let rawDrawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            let cappedDrawableSize = cappedDrawableSize(rawDrawableSize)
            if metalLayer.drawableSize != cappedDrawableSize {
                metalLayer.drawableSize = cappedDrawableSize
                renderState.markNeedsRedraw()
                if cappedDrawableSize != rawDrawableSize {
                    MirageLogger
                        .renderer(
                            "Drawable size capped: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                                "\(cappedDrawableSize.width)x\(cappedDrawableSize.height) px"
                        )
                }
            }
        }

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    public func suspendRendering() {
        renderingSuspended = true
        renderAdmission.reset()
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
        drawableRetryScheduled = false
    }

    public func resumeRendering() {
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
        let presentedSequence = renderState.currentSequence
        let presentedDecodeTime = renderState.currentDecodeTime
        renderSequenceGate.noteRequested(presentedSequence)
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
            if self.renderSequenceGate.isStale(presentedSequence) {
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
                                sequence: presentedSequence,
                                decodeTime: presentedDecodeTime,
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
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        if lastReportedDrawableSize == .zero {
            lastReportedDrawableSize = drawableSize
            renderState.markNeedsRedraw()
            MirageLogger.renderer("Initial drawable size (immediate): \(drawableSize.width)x\(drawableSize.height) px")
            onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: drawableSize))
            return
        }

        let widthDiff = abs(drawableSize.width - lastReportedDrawableSize.width)
        let heightDiff = abs(drawableSize.height - lastReportedDrawableSize.height)
        let widthTolerance = lastReportedDrawableSize.width * 0.005
        let heightTolerance = lastReportedDrawableSize.height * 0.005
        let significantWidthChange = widthDiff > max(widthTolerance, 4)
        let significantHeightChange = heightDiff > max(heightTolerance, 4)

        guard significantWidthChange || significantHeightChange else { return }

        lastReportedDrawableSize = drawableSize
        renderState.markNeedsRedraw()
        MirageLogger.renderer("Drawable size changed: \(drawableSize.width)x\(drawableSize.height) px")
        onDrawableMetricsChanged?(currentDrawableMetrics(drawableSize: drawableSize))
    }

    #if os(visionOS)
    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let boundsSize = bounds.size
        let scaleX = boundsSize.width > 0 ? drawableSize.width / boundsSize.width : 0
        let scaleY = boundsSize.height > 0 ? drawableSize.height / boundsSize.height : 0
        let scale = max(0.1, max(scaleX, scaleY))
        let windowPointSize = window?.bounds.size ?? boundsSize
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let nativePixelSize = CGSize(
            width: windowPointSize.width * screenScale,
            height: windowPointSize.height * screenScale
        )
        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: boundsSize,
            scaleFactor: scale,
            screenPointSize: windowPointSize,
            screenScale: screenScale,
            screenNativePixelSize: nativePixelSize,
            screenNativeScale: screenScale
        )
    }
    #else
    private func currentDrawableMetrics(drawableSize: CGSize) -> MirageDrawableMetrics {
        let boundsSize = bounds.size
        let scaleX = boundsSize.width > 0 ? drawableSize.width / boundsSize.width : 0
        let scaleY = boundsSize.height > 0 ? drawableSize.height / boundsSize.height : 0
        let scale = max(0.1, max(scaleX, scaleY))
        let screen = resolveCurrentScreen()
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
        return MirageDrawableMetrics(
            pixelSize: drawableSize,
            viewSize: boundsSize,
            scaleFactor: scale,
            screenPointSize: screen.bounds.size,
            screenScale: screen.scale,
            screenNativePixelSize: orientedNativePixelSize(for: screen),
            screenNativeScale: nativeScale
        )
    }

    private func resolveCurrentScreen() -> UIScreen {
        if let screen = window?.windowScene?.screen { return screen }
        if let screen = window?.screen { return screen }
        return UIScreen.main
    }

    private func orientedNativePixelSize(for screen: UIScreen) -> CGSize {
        let nativeSize = screen.nativeBounds.size
        let pointSize = screen.bounds.size
        guard nativeSize.width > 0, nativeSize.height > 0 else { return .zero }

        let nativeIsLandscape = nativeSize.width >= nativeSize.height
        let pointsAreLandscape = pointSize.width >= pointSize.height
        if nativeIsLandscape == pointsAreLandscape { return nativeSize }

        return CGSize(width: nativeSize.height, height: nativeSize.width)
    }
    #endif

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
                "Drawable unavailable on iOS/visionOS view; retries=\(noDrawableSkipsSinceLog) in last \(elapsedText)s"
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
        maxRenderFPS = clamped
        renderScheduler.updateTargetFPS(clamped)
        applyDisplayRefreshRateLock(clamped)
        onRefreshRateOverrideChange?(clamped)
    }

    func applyDisplayRefreshRateLock(_ fps: Int) {
        let clamped = fps >= 120 ? 120 : 60
        guard appliedRefreshRateLock != clamped else { return }
        appliedRefreshRateLock = clamped
        MirageLogger.renderer("Applied iOS render refresh lock: \(clamped)Hz")
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

        let metalLayer = self.metalLayer
        metalLayer.pixelFormat = outputPixelFormat
        metalLayer.colorspace = colorSpace
        metalLayer.wantsExtendedDynamicRangeContent = wantsHDR
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
