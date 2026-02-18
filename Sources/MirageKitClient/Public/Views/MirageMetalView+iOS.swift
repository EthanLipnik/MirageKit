//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  CAMetalLayer-backed stream view on iOS and visionOS.
//

import MirageKit
#if os(iOS) || os(visionOS)
import CoreVideo
import Metal
import QuartzCore
import UIKit

public class MirageMetalView: UIView {
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

    // MARK: - Safe Area Override

    override public var safeAreaInsets: UIEdgeInsets { .zero }

    override public class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    // MARK: - Public API

    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    public var maxDrawableSize: CGSize? {
        didSet {
            guard maxDrawableSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    public var latencyMode: MirageStreamLatencyMode = .auto {
        didSet {
            guard latencyMode != oldValue else { return }
            renderLoop.updateLatencyMode(latencyMode)
            metalLayer.maximumDrawableCount = desiredLayerMaximumDrawableCount()
            requestDraw()
        }
    }

    public var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            resetDrawAdmissionState()
            renderLoop.setStreamID(streamID)
            requestDraw()
        }
    }

    // MARK: - Rendering State

    private var renderer: MetalRenderer?
    let preferencesObserver = MirageUserDefaultsObserver()
    lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)
    var renderLoop: MirageRenderLoop!

    private let renderQueue = DispatchQueue(label: "com.mirage.client.render.ios", qos: .userInteractive)
    private let drawableAcquireQueue = DispatchQueue(
        label: "com.mirage.client.render.drawable.ios",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private let drawAdmissionLock = NSLock()

    private var renderingSuspended = false
    private var inFlightDrawCount = 0 // guarded by drawAdmissionLock
    private var pendingDraw = false // guarded by drawAdmissionLock
    private var drawableRetryTask: Task<Void, Never>?

    private var diagnosticsWindowStart: CFAbsoluteTime = 0
    private var diagnosticsDrawCalls: UInt64 = 0
    private var diagnosticsAdmissionSkips: UInt64 = 0
    private var diagnosticsSubmissions: UInt64 = 0
    private var diagnosticsNoDrawable: UInt64 = 0
    private var diagnosticsPresented: UInt64 = 0
    private var diagnosticsDrawableWaitTotalMs: Double = 0
    private var diagnosticsDrawableWaitMaxMs: Double = 0
    private var diagnosticsMaxInFlight: Int = 0
    private var diagnosticsTargetInFlight: Int = 1

    var maxRenderFPS: Int = 60
    var appliedRefreshRateLock: Int = 0
    var colorPixelFormat: MTLPixelFormat = .bgr10a2Unorm

    var lastReportedDrawableSize: CGSize = .zero

    static let maxDrawableWidth: CGFloat = 5120
    static let maxDrawableHeight: CGFloat = 2880

    var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else {
            fatalError("MirageMetalView requires CAMetalLayer backing")
        }
        return layer
    }

    private var effectiveScale: CGFloat {
        #if os(iOS)
        if let screen = window?.windowScene?.screen ?? window?.screen {
            let nativeScale = screen.nativeScale
            if nativeScale > 0 { return nativeScale }
            let screenScale = screen.scale
            if screenScale > 0 { return screenScale }
        }
        #endif
        let traitScale = traitCollection.displayScale
        if traitScale > 0 { return traitScale }
        return 2.0
    }

    // MARK: - Init

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

    @MainActor
    deinit {
        drawableRetryTask?.cancel()
        renderLoop.stop()
        refreshRateMonitor.stop()
        stopObservingPreferences()
    }

    // MARK: - UIView Lifecycle

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            renderLoop.start()
            resumeRendering()
            requestDraw()
        } else {
            refreshRateMonitor.stop()
            renderLoop.stop()
            suspendRendering()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayRefreshRateLock(maxRenderFPS)
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()

        contentScaleFactor = effectiveScale
        let metalLayer = self.metalLayer
        metalLayer.frame = bounds
        metalLayer.contentsScale = effectiveScale

        if bounds.width > 0, bounds.height > 0 {
            let baseDrawableSize = CGSize(
                width: bounds.width * metalLayer.contentsScale,
                height: bounds.height * metalLayer.contentsScale
            )
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

    public func suspendRendering() {
        renderingSuspended = true
        resetDrawAdmissionState()
        drawableRetryTask?.cancel()
        drawableRetryTask = nil
    }

    public func resumeRendering() {
        renderingSuspended = false
        requestDraw()
    }

    // MARK: - Setup

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

        let metalLayer = self.metalLayer
        metalLayer.device = device
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = colorPixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.contentsScale = effectiveScale
        metalLayer.presentsWithTransaction = false
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = desiredLayerMaximumDrawableCount()

        renderLoop = MirageRenderLoop(delegate: self)
        renderLoop.updateLatencyMode(latencyMode)

        refreshRateMonitor.onOverrideChange = { [weak self] override in
            self?.applyRefreshRateOverride(override)
        }

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
        noteDrawCall()

        let queueDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        guard queueDepth > 0 else { return }

        let desiredInFlight = desiredMaxInFlightDraws(for: decision)
        diagnosticsTargetInFlight = desiredInFlight
        let maxInFlightDraws = max(1, min(desiredInFlight, metalLayer.maximumDrawableCount))
        guard let inFlightCount = reserveInFlightSlot(maxInFlightDraws) else {
            diagnosticsAdmissionSkips &+= 1
            emitDiagnosticsIfNeeded()
            return
        }

        let latestQueuedFrame = MirageFrameCache.shared.peekLatest(for: streamID)
        if let latestQueuedFrame {
            updateOutputFormatIfNeeded(CVPixelBufferGetPixelFormatType(latestQueuedFrame.pixelBuffer))
        } else {
            releaseInFlightSlotAndRequestPendingRedrawIfNeeded()
            return
        }
        let outputPixelFormat = colorPixelFormat
        let presentationPolicy = decision.presentationPolicy

        diagnosticsSubmissions &+= 1
        diagnosticsMaxInFlight = max(diagnosticsMaxInFlight, inFlightCount)
        emitDiagnosticsIfNeeded()
        let releaseToken = DrawReleaseToken(release: { [weak self] in
            self?.releaseInFlightSlotAndRequestPendingRedrawIfNeeded()
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
                    self.diagnosticsNoDrawable &+= 1
                    self.recordDrawableWait(drawableWaitMs)
                    self.renderLoop.recordDrawResult(drawableWaitMs: drawableWaitMs, rendered: false)
                    self.scheduleDrawableRetry()
                    self.emitDiagnosticsIfNeeded()
                }
                return
            }

            self?.renderQueue.async { [weak self] in
                let frame = MirageFrameCache.shared.dequeueForPresentation(
                    for: streamID,
                    policy: presentationPolicy
                )

                guard let frame else {
                    releaseToken.fire()
                    return
                }

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
            diagnosticsPresented &+= 1
            MirageFrameCache.shared.markPresented(sequence: frame.sequence, for: streamID)
        }

        recordDrawableWait(drawableWaitMs)
        renderLoop.recordDrawResult(drawableWaitMs: drawableWaitMs, rendered: wasPresented)
        emitDiagnosticsIfNeeded()
    }

    func desiredMaxInFlightDraws(for decision: MirageRenderModeDecision? = nil) -> Int {
        let lowLatencyDepth = 3
        let smoothDepth = 3

        guard let decision else {
            switch latencyMode {
            case .lowestLatency:
                return lowLatencyDepth
            case .auto, .smoothest:
                return smoothDepth
            }
        }

        switch decision.profile {
        case .lowestLatency, .autoTyping:
            return lowLatencyDepth
        case .autoSmooth, .smoothest:
            return smoothDepth
        }
    }

    func desiredLayerMaximumDrawableCount() -> Int {
        max(2, min(3, desiredMaxInFlightDraws()))
    }

    private func resetDrawAdmissionState() {
        drawAdmissionLock.lock()
        inFlightDrawCount = 0
        pendingDraw = false
        drawAdmissionLock.unlock()
    }

    private func snapshotInFlightDrawCount() -> Int {
        drawAdmissionLock.lock()
        let count = inFlightDrawCount
        drawAdmissionLock.unlock()
        return count
    }

    private func reserveInFlightSlot(_ maxInFlightDraws: Int) -> Int? {
        drawAdmissionLock.lock()
        defer { drawAdmissionLock.unlock() }

        guard inFlightDrawCount < maxInFlightDraws else {
            pendingDraw = true
            return nil
        }

        inFlightDrawCount += 1
        return inFlightDrawCount
    }

    private func releaseInFlightSlotAndRequestPendingRedrawIfNeeded() {
        var shouldRequestRedraw = false

        drawAdmissionLock.lock()
        if inFlightDrawCount > 0 {
            inFlightDrawCount -= 1
        }
        if pendingDraw {
            pendingDraw = false
            shouldRequestRedraw = true
        }
        drawAdmissionLock.unlock()

        if shouldRequestRedraw {
            renderLoop.requestRedraw()
        }
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

    @MainActor
    private func noteDrawCall(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        diagnosticsDrawCalls &+= 1
        if diagnosticsWindowStart == 0 {
            diagnosticsWindowStart = now
        }
    }

    @MainActor
    private func recordDrawableWait(_ waitMs: Double) {
        diagnosticsDrawableWaitTotalMs += waitMs
        diagnosticsDrawableWaitMaxMs = max(diagnosticsDrawableWaitMaxMs, waitMs)
    }

    @MainActor
    private func emitDiagnosticsIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard MirageLogger.isEnabled(.renderer) else { return }
        if diagnosticsWindowStart == 0 {
            diagnosticsWindowStart = now
            return
        }

        let elapsed = now - diagnosticsWindowStart
        guard elapsed >= 1.0 else { return }

        let safeElapsed = max(0.001, elapsed)
        let drawHz = Double(diagnosticsDrawCalls) / safeElapsed
        let submitHz = Double(diagnosticsSubmissions) / safeElapsed
        let presentHz = Double(diagnosticsPresented) / safeElapsed
        let waitSamples = max(1.0, Double(diagnosticsSubmissions + diagnosticsNoDrawable))
        let waitAvg = diagnosticsDrawableWaitTotalMs / waitSamples

        let drawText = drawHz.formatted(.number.precision(.fractionLength(1)))
        let submitText = submitHz.formatted(.number.precision(.fractionLength(1)))
        let presentText = presentHz.formatted(.number.precision(.fractionLength(1)))
        let waitAvgText = waitAvg.formatted(.number.precision(.fractionLength(2)))
        let waitMaxText = diagnosticsDrawableWaitMaxMs.formatted(.number.precision(.fractionLength(2)))
        let inFlightCount = snapshotInFlightDrawCount()

        MirageLogger.renderer(
            "Render path stats draw=\(drawText)Hz submit=\(submitText)Hz present=\(presentText)Hz " +
                "inFlight=\(inFlightCount) maxInFlight=\(diagnosticsMaxInFlight) " +
                "targetInFlight=\(diagnosticsTargetInFlight) layerMax=\(metalLayer.maximumDrawableCount) " +
                "admissionSkips=\(diagnosticsAdmissionSkips) noDrawable=\(diagnosticsNoDrawable) " +
                "drawableWait=\(waitAvgText)/\(waitMaxText)ms"
        )

        diagnosticsWindowStart = now
        diagnosticsDrawCalls = 0
        diagnosticsAdmissionSkips = 0
        diagnosticsSubmissions = 0
        diagnosticsNoDrawable = 0
        diagnosticsPresented = 0
        diagnosticsDrawableWaitTotalMs = 0
        diagnosticsDrawableWaitMaxMs = 0
        diagnosticsMaxInFlight = inFlightCount
        diagnosticsTargetInFlight = desiredMaxInFlightDraws()
    }

}

extension MirageMetalView: MirageRenderLoopDelegate {
    @MainActor
    func renderLoopDraw(now: CFAbsoluteTime, decision: MirageRenderModeDecision) {
        draw(now: now, decision: decision)
    }

    @MainActor
    func renderLoopScaleChanged(_: Double) {
        setNeedsLayout()
    }
}
#endif
