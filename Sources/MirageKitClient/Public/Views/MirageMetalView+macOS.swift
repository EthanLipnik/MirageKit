//
//  MirageMetalView+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  CAMetalLayer-backed stream view on macOS.
//

import MirageKit
#if os(macOS)
import AppKit
import CoreVideo
import Metal
import QuartzCore

public class MirageMetalView: NSView {
    // @unchecked Sendable: guarded by NSLock for once-only callback dispatch.
    private final class DrawReleaseToken: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let release: @Sendable () -> Void

        init(release: @escaping @Sendable () -> Void) {
            self.release = release
        }

        func fire() {
            lock.lock()
            let shouldFire = !fired
            if shouldFire { fired = true }
            lock.unlock()
            guard shouldFire else { return }
            release()
        }
    }

    // MARK: - Public API

    var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            inFlightDrawCount = 0
            pendingDraw = false
            lastPresentedFrame = nil
            renderLoop.setStreamID(streamID)
            requestDraw()
        }
    }

    public var latencyMode: MirageStreamLatencyMode = .auto {
        didSet {
            guard latencyMode != oldValue else { return }
            renderLoop.updateLatencyMode(latencyMode)
            requestDraw()
        }
    }

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            needsLayout = true
        }
    }

    // MARK: - Rendering State

    private var renderer: MetalRenderer?
    private var renderLoop: MirageRenderLoop!
    private let preferencesObserver = MirageUserDefaultsObserver()

    private let renderQueue = DispatchQueue(label: "com.mirage.client.render.macos", qos: .userInteractive)
    private let drawableAcquireQueue = DispatchQueue(
        label: "com.mirage.client.render.drawable.macos",
        qos: .userInteractive
    )

    private var renderingSuspended = false
    private var inFlightDrawCount = 0
    private var pendingDraw = false
    private var drawableRetryTask: Task<Void, Never>?

    private var lastPresentedFrame: MirageFrameCache.FrameEntry?

    private var maxRenderFPS: Int = 60
    private var colorPixelFormat: MTLPixelFormat = .bgr10a2Unorm

    private var lastReportedDrawableSize: CGSize = .zero

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880

    private var metalLayer: CAMetalLayer {
        if let layer = layer as? CAMetalLayer {
            return layer
        }
        fatalError("MirageMetalView requires CAMetalLayer backing")
    }

    // MARK: - Init

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

    deinit {
        drawableRetryTask?.cancel()
        renderLoop.stop()
    }

    // MARK: - NSView Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            renderLoop.start()
            resumeRendering()
            requestDraw()
        } else {
            renderLoop.stop()
            suspendRendering()
        }
    }

    override public func layout() {
        super.layout()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let metalLayer = self.metalLayer
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale

        if bounds.width > 0, bounds.height > 0 {
            let baseDrawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let scaledDrawableSize = CGSize(
                width: baseDrawableSize.width * CGFloat(renderLoop.currentRenderScale()),
                height: baseDrawableSize.height * CGFloat(renderLoop.currentRenderScale())
            )
            let cappedSize = cappedDrawableSize(scaledDrawableSize)
            if metalLayer.drawableSize != cappedSize {
                metalLayer.drawableSize = cappedSize
            }
        }

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    // MARK: - Public Controls

    func suspendRendering() {
        renderingSuspended = true
        inFlightDrawCount = 0
        pendingDraw = false
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
    }

    func resumeRendering() {
        renderingSuspended = false
        requestDraw()
    }

    // MARK: - Setup

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

        renderLoop = MirageRenderLoop(delegate: self)
        renderLoop.updateLatencyMode(latencyMode)

        applyRenderPreferences()
        startObservingPreferences()
    }

    // MARK: - Draw Path

    @MainActor
    func requestDraw() {
        guard !renderingSuspended else { return }
        renderLoop.requestRedraw()
    }

    @MainActor
    private func draw(now _: CFAbsoluteTime, decision: MirageRenderModeDecision) {
        guard !renderingSuspended else { return }
        guard let streamID else { return }
        guard let renderer else { return }

        let queueDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        let canRepeat = decision.allowCadenceRepeat && lastPresentedFrame != nil
        guard queueDepth > 0 || canRepeat else { return }

        let maxInFlightDraws = max(1, min(3, metalLayer.maximumDrawableCount))
        guard inFlightDrawCount < maxInFlightDraws else {
            pendingDraw = true
            return
        }

        guard let frame = selectFrameForPresentation(streamID: streamID, decision: decision) else { return }
        updateOutputFormatIfNeeded(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
        let outputPixelFormat = colorPixelFormat

        inFlightDrawCount += 1
        let releaseToken = DrawReleaseToken(release: { [weak self] in
            Task { @MainActor [weak self] in
                self?.releaseInFlightSlot()
            }
        })

        let drawableLayer = metalLayer
        drawableAcquireQueue.async { [weak self] in
            let waitStart = CFAbsoluteTimeGetCurrent()
            let drawable = drawableLayer.nextDrawable()
            let drawableWaitMs = max(0, CFAbsoluteTimeGetCurrent() - waitStart) * 1000

            guard let drawable else {
                releaseToken.fire()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.renderLoop.recordDrawResult(drawableWaitMs: drawableWaitMs, rendered: false)
                    self.scheduleDrawableRetry()
                    self.flushPendingDrawIfNeeded()
                }
                return
            }

            self?.renderQueue.async { [weak self] in
                renderer.render(
                    pixelBuffer: frame.pixelBuffer,
                    to: drawable,
                    contentRect: frame.contentRect,
                    outputPixelFormat: outputPixelFormat,
                    onScheduled: {
                        releaseToken.fire()
                    },
                    completion: { [weak self] wasPresented in
                        releaseToken.fire()
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.completeDraw(
                                frame: frame,
                                streamID: streamID,
                                drawableWaitMs: drawableWaitMs,
                                wasPresented: wasPresented
                            )
                        }
                    }
                )
            }
        }
    }

    @MainActor
    private func completeDraw(
        frame: MirageFrameCache.FrameEntry,
        streamID: StreamID,
        drawableWaitMs: Double,
        wasPresented: Bool
    ) {
        if wasPresented {
            lastPresentedFrame = frame
            MirageFrameCache.shared.markPresented(sequence: frame.sequence, for: streamID)
        }

        renderLoop.recordDrawResult(drawableWaitMs: drawableWaitMs, rendered: wasPresented)
        flushPendingDrawIfNeeded()
    }

    @MainActor
    private func flushPendingDrawIfNeeded() {
        guard pendingDraw else { return }
        pendingDraw = false
        renderLoop.requestRedraw()
    }

    @MainActor
    private func releaseInFlightSlot() {
        if inFlightDrawCount > 0 {
            inFlightDrawCount -= 1
        }
        flushPendingDrawIfNeeded()
    }

    @MainActor
    private func selectFrameForPresentation(
        streamID: StreamID,
        decision: MirageRenderModeDecision
    ) -> MirageFrameCache.FrameEntry? {
        if let frame = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            catchUpDepth: decision.presentationKeepDepth,
            preferLatest: decision.preferLatest
        ) {
            return frame
        }

        if decision.allowCadenceRepeat {
            return lastPresentedFrame
        }

        return nil
    }

    @MainActor
    private func scheduleDrawableRetry() {
        guard drawableRetryTask == nil else { return }
        drawableRetryTask = Task { @MainActor [weak self] in
            defer { self?.drawableRetryTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(4))
            } catch {
                return
            }
            guard let self, !self.renderingSuspended else { return }
            self.renderLoop.requestRedraw()
        }
    }

    // MARK: - Metrics

    private func reportDrawableMetricsIfChanged() {
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard drawableSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = drawableSize
        let metrics = currentDrawableMetrics(drawableSize: drawableSize)
        let callback = onDrawableMetricsChanged
        Task { @MainActor in
            callback?(metrics)
        }
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

        if let maxDrawableSize, maxDrawableSize.width <= 0 || maxDrawableSize.height <= 0 {
            return CGSize(width: alignedEven(size.width), height: alignedEven(size.height))
        }

        var width = size.width
        var height = size.height
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

    // MARK: - Preferences / Format

    private func applyRenderPreferences() {
        let target = MirageRenderPreferences.proMotionEnabled() ? 120 : 60
        maxRenderFPS = target
        renderLoop.updateTargetFPS(target)
        renderLoop.updateAllowDegradationRecovery(MirageRenderPreferences.allowAdaptiveFallback())
        requestDraw()
    }

    private func startObservingPreferences() {
        preferencesObserver.start { [weak self] in
            self?.applyRenderPreferences()
        }
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
    }
}

extension MirageMetalView: MirageRenderLoopDelegate {
    @MainActor
    func renderLoopDraw(now: CFAbsoluteTime, decision: MirageRenderModeDecision) {
        draw(now: now, decision: decision)
    }

    @MainActor
    func renderLoopScaleChanged(_: Double) {
        needsLayout = true
    }
}
#endif
