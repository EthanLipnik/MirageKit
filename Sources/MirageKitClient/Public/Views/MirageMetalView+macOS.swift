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

private final class MirageDrawAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var renderingSuspended = false
    private var inFlightDrawCount = 0
    private var pendingDraw = false

    func suspend() {
        lock.lock()
        renderingSuspended = true
        inFlightDrawCount = 0
        pendingDraw = false
        lock.unlock()
    }

    func resume() {
        lock.lock()
        renderingSuspended = false
        lock.unlock()
    }

    func isSuspended() -> Bool {
        lock.lock()
        let suspended = renderingSuspended
        lock.unlock()
        return suspended
    }

    func reset() {
        lock.lock()
        inFlightDrawCount = 0
        pendingDraw = false
        lock.unlock()
    }

    func reserve(maxInFlight: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard inFlightDrawCount < maxInFlight else {
            pendingDraw = true
            return false
        }

        inFlightDrawCount += 1
        return true
    }

    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if inFlightDrawCount > 0 {
            inFlightDrawCount -= 1
        }
        guard pendingDraw else { return false }
        pendingDraw = false
        return true
    }
}

private final class MirageSendableMetalLayer: @unchecked Sendable {
    let layer: CAMetalLayer

    init(_ layer: CAMetalLayer) {
        self.layer = layer
    }
}

public class MirageMetalView: NSView {
    // MARK: - Public API

    var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            resetDrawAdmissionState()
            renderLoop.setStreamID(streamID)
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
    private let drawAdmissionState = MirageDrawAdmissionState()

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
        drawAdmissionState.suspend()
    }

    func resumeRendering() {
        drawAdmissionState.resume()
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
        metalLayer.maximumDrawableCount = desiredLayerMaximumDrawableCount()
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        renderLoop = MirageRenderLoop(delegate: self)

        applyRenderPreferences()
        startObservingPreferences()
    }

    // MARK: - Draw Path

    func requestDraw() {
        guard !isRenderingSuspended() else { return }
        renderLoop.requestRedraw()
    }

    private func draw(
        now _: CFAbsoluteTime,
        decision: MirageRenderModeDecision,
        completion: @escaping @Sendable (MirageRenderDrawOutcome) -> Void
    ) {
        guard !isRenderingSuspended() else {
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }

        guard let streamID else {
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }

        guard let renderer else {
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }

        let queueDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        guard queueDepth > 0 else {
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }

        let maxInFlightDraws = max(1, min(desiredMaxInFlightDraws(for: decision), metalLayer.maximumDrawableCount))
        guard drawAdmissionState.reserve(maxInFlight: maxInFlightDraws) else {
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }

        guard let latestQueuedFrame = MirageFrameCache.shared.peekLatest(for: streamID) else {
            if drawAdmissionState.release() {
                renderLoop.requestRedraw()
            }
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }
        updateOutputFormatIfNeeded(CVPixelBufferGetPixelFormatType(latestQueuedFrame.pixelBuffer))

        let presentationPolicy = decision.presentationPolicy
        let outputPixelFormat = colorPixelFormat
        let sendableLayer = MirageSendableMetalLayer(metalLayer)
        let admissionState = drawAdmissionState
        guard let renderLoop else {
            if admissionState.release() {
                self.renderLoop?.requestRedraw()
            }
            completion(MirageRenderDrawOutcome(drawableWaitMs: 0, rendered: false))
            return
        }
        let releaseInFlightAndRequestRedraw: @Sendable () -> Void = {
            if admissionState.release() {
                renderLoop.requestRedraw()
            }
        }

        renderQueue.async {
            let waitStart = CFAbsoluteTimeGetCurrent()
            let drawable = sendableLayer.layer.nextDrawable()
            let drawableWaitMs = max(0, CFAbsoluteTimeGetCurrent() - waitStart) * 1000

            guard let drawable else {
                releaseInFlightAndRequestRedraw()
                completion(MirageRenderDrawOutcome(drawableWaitMs: drawableWaitMs, rendered: false))
                return
            }

            guard let frame = MirageFrameCache.shared.dequeueForPresentation(
                for: streamID,
                policy: presentationPolicy
            ) else {
                releaseInFlightAndRequestRedraw()
                completion(MirageRenderDrawOutcome(drawableWaitMs: drawableWaitMs, rendered: false))
                return
            }

            renderer.render(
                pixelBuffer: frame.pixelBuffer,
                to: drawable,
                contentRect: frame.contentRect,
                outputPixelFormat: outputPixelFormat,
                completion: { wasPresented in
                    if wasPresented {
                        MirageFrameCache.shared.markPresented(sequence: frame.sequence, for: streamID)
                    }
                    releaseInFlightAndRequestRedraw()
                    completion(MirageRenderDrawOutcome(drawableWaitMs: drawableWaitMs, rendered: wasPresented))
                }
            )
        }
    }

    private func desiredMaxInFlightDraws(for decision: MirageRenderModeDecision? = nil) -> Int {
        _ = decision
        return 3
    }

    private func desiredLayerMaximumDrawableCount() -> Int {
        max(2, min(3, desiredMaxInFlightDraws()))
    }

    private func isRenderingSuspended() -> Bool {
        drawAdmissionState.isSuspended()
    }

    private func resetDrawAdmissionState() {
        drawAdmissionState.reset()
    }

    @objc private func applyScaleLayoutUpdateOnMainThread() {
        needsLayout = true
    }

    // MARK: - Metrics

    private func reportDrawableMetricsIfChanged() {
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard drawableSize != lastReportedDrawableSize else { return }

        lastReportedDrawableSize = drawableSize
        let metrics = currentDrawableMetrics(drawableSize: drawableSize)
        onDrawableMetricsChanged?(metrics)
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
        metalLayer.maximumDrawableCount = desiredLayerMaximumDrawableCount()
        renderLoop.updateTargetFPS(target)
        renderLoop.updateLatencyMode(MirageRenderPreferences.latencyMode())
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
    func renderLoopDraw(
        now: CFAbsoluteTime,
        decision: MirageRenderModeDecision,
        completion: @escaping @Sendable (MirageRenderDrawOutcome) -> Void
    ) {
        draw(now: now, decision: decision, completion: completion)
    }

    func renderLoopScaleChanged(_: Double) {
        if Thread.isMainThread {
            needsLayout = true
        } else {
            performSelector(onMainThread: #selector(applyScaleLayoutUpdateOnMainThread), with: nil, waitUntilDone: false)
        }
    }
}
#endif
