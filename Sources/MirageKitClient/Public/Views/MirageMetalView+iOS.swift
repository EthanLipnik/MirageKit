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

private final class MirageRenderAdmissionReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let releaseHandler: @Sendable () -> Bool

    init(releaseHandler: @escaping @Sendable () -> Bool) {
        self.releaseHandler = releaseHandler
    }

    @discardableResult
    func releaseOnce() -> Bool {
        lock.lock()
        let shouldRelease = !released
        if shouldRelease {
            released = true
        }
        lock.unlock()
        guard shouldRelease else { return false }
        return releaseHandler()
    }
}

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

    /// Stream latency mode used to tune render admission and scheduling policy.
    public var latencyMode: MirageStreamLatencyMode = .auto {
        didSet {
            guard latencyMode != oldValue else { return }
            updateDecodeDrivenTriggerPolicy()
            renderStabilityPolicy.reset()
            renderScalePolicy.reset()
            applyRenderPolicy(now: CFAbsoluteTimeGetCurrent(), forceLog: true)
            setNeedsLayout()
            requestDraw()
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
                MirageClientRenderTrigger.shared.setDecodeDrivenRequestsEnabled(
                    !usesDisplayClockLockedPresentation,
                    for: streamID
                )
            }
            renderState.reset()
            renderScheduler.reset()
            renderAdmission.reset()
            renderSequenceGate.reset()
            renderStabilityPolicy.reset()
            renderScalePolicy.reset()
            lastRenderPolicyDecision = nil
            drawableRetryTask?.cancel()
            drawableRetryTask = nil
            drawableRetryScheduled = false
            drawableAcquisitionPending = false
            admissionRetryTask?.cancel()
            admissionRetryTask = nil
            admissionRetryScheduled = false
            lastInFlightCapPressureTime = 0
            drawableWaitPressureUntil = 0
            capSkipStreak = 0
            admissionRetryFireCount = 0
            applyRenderPolicy(now: CFAbsoluteTimeGetCurrent(), forceLog: true)
            setNeedsLayout()
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
    private var drawableAcquisitionPending = false
    private var drawableRetryTask: Task<Void, Never>?
    private var admissionRetryScheduled = false
    private var admissionRetryTask: Task<Void, Never>?
    private var lastAdmissionRetryFireTime: CFAbsoluteTime = 0
    private var noDrawableSkipsSinceLog: UInt64 = 0
    private var lastNoDrawableLogTime: CFAbsoluteTime = 0
    private var renderDiagnostics = RenderDiagnostics()
    private var renderStabilityPolicy = MirageRenderStabilityPolicy()
    private var renderScalePolicy = MirageRenderScalePolicy()
    private var lastRenderPolicyDecision: MirageRenderPolicyDecision?
    private var lastInFlightCapPressureTime: CFAbsoluteTime = 0
    private var drawableWaitPressureUntil: CFAbsoluteTime = 0
    private var capSkipStreak: UInt64 = 0
    private var admissionRetryFireCount: UInt64 = 0

    /// Last reported drawable size to avoid redundant callbacks.
    private var lastReportedDrawableSize: CGSize = .zero

    private static let maxDrawableWidth: CGFloat = 5120
    private static let maxDrawableHeight: CGFloat = 2880
    private static let inFlightCapRetryDelayMs: Int64 = 1
    private static let inFlightCapRetryMinInterval: CFAbsoluteTime = 0.002
    private static let pressureWindow: CFAbsoluteTime = 0.25
    private static let drawableWaitPressureFactor = 1.30

    private struct RenderSubmission {
        let pixelBuffer: CVPixelBuffer
        let contentRect: CGRect
        let outputPixelFormat: MTLPixelFormat
        let streamID: StreamID?
        let sequence: UInt64
        let decodeTime: CFAbsoluteTime
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
        metalLayer.presentsWithTransaction = false
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
        admissionRetryTask?.cancel()
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
            let renderScale = CGFloat(renderScalePolicy.currentScale)
            let scaledDrawableSize = CGSize(
                width: rawDrawableSize.width * renderScale,
                height: rawDrawableSize.height * renderScale
            )
            let cappedDrawableSize = cappedDrawableSize(scaledDrawableSize)
            if metalLayer.drawableSize != cappedDrawableSize {
                metalLayer.drawableSize = cappedDrawableSize
                renderState.markNeedsRedraw()
                if cappedDrawableSize != scaledDrawableSize || renderScale < 0.999 {
                    MirageLogger
                        .renderer(
                            "Drawable size adjusted: \(rawDrawableSize.width)x\(rawDrawableSize.height) -> " +
                                "\(cappedDrawableSize.width)x\(cappedDrawableSize.height) px scale=\(renderScale)"
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
        drawableAcquisitionPending = false
        admissionRetryTask?.cancel()
        admissionRetryTask = nil
        admissionRetryScheduled = false
        lastInFlightCapPressureTime = 0
        drawableWaitPressureUntil = 0
        capSkipStreak = 0
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
        guard !drawableAcquisitionPending else {
            renderDiagnostics.skipAcquirePending &+= 1
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let initialDecision = resolvedRenderPolicyDecision(now: now)
        applyRenderPolicy(decision: initialDecision, now: now)

        guard let renderer else {
            renderDiagnostics.skipNoRenderer &+= 1
            maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
            return
        }

        drawableAcquisitionPending = true
        let drawStartTime = CFAbsoluteTimeGetCurrent()
        let signalDelay = lastScheduledSignalTime > 0 ? max(0, drawStartTime - lastScheduledSignalTime) : 0
        let streamID = streamID
        let metalLayer = self.metalLayer
        let drawableAcquireQueue = self.drawableAcquireQueue
        let renderQueue = self.renderQueue

        drawableAcquireQueue.async { [weak self] in
            let drawableWaitStart = CFAbsoluteTimeGetCurrent()
            let drawable = metalLayer.nextDrawable()
            let drawableWait = max(0, CFAbsoluteTimeGetCurrent() - drawableWaitStart)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.drawableAcquisitionPending = false

                guard !self.renderingSuspended else {
                    return
                }

                guard let drawable else {
                    self.handleNoDrawable(signalDelay: signalDelay, drawableWait: drawableWait)
                    return
                }

                let renderDecisionTime = CFAbsoluteTimeGetCurrent()
                let decision = self.resolvedRenderPolicyDecision(now: renderDecisionTime)
                self.applyRenderPolicy(decision: decision, now: renderDecisionTime)
                let effectiveCap = decision.inFlightCap
                guard self.renderAdmission.tryAcquire(limit: effectiveCap) else {
                    self.renderDiagnostics.skipInFlightCap &+= 1
                    self.capSkipStreak &+= 1
                    self.lastInFlightCapPressureTime = renderDecisionTime
                    self.scheduleInFlightCapRetry(now: renderDecisionTime, decision: decision)
                    self.recordDrawCompletion(
                        startTime: drawStartTime,
                        signalDelay: signalDelay,
                        drawableWait: drawableWait,
                        rendered: false
                    )
                    self.maybeLogRenderDiagnostics(now: renderDecisionTime)
                    return
                }
                self.capSkipStreak = 0
                self.renderDiagnostics.drawAttempts &+= 1

                let displayClockLocked = self.usesDisplayClockLockedPresentation
                let shouldPreferLatestFrame = displayClockLocked ||
                    (decision.prefersLatestFrameOnPressure && self.recentPressureActive(now: renderDecisionTime))
                let presentationKeepDepth = displayClockLocked ? 1 : decision.presentationKeepDepth

                guard let submission = self.prepareRenderSubmission(
                    streamID: streamID,
                    catchUpDepth: presentationKeepDepth,
                    preferLatestFrame: shouldPreferLatestFrame,
                    drawablePixelFormat: drawable.texture.pixelFormat
                ) else {
                    _ = self.renderAdmission.release()
                    self.recordDrawCompletion(
                        startTime: drawStartTime,
                        signalDelay: signalDelay,
                        drawableWait: drawableWait,
                        rendered: false
                    )
                    self.maybeLogRenderDiagnostics(now: CFAbsoluteTimeGetCurrent())
                    return
                }

                let renderAdmission = self.renderAdmission
                let admissionReleaseMode = decision.admissionReleaseMode
                let policyReason = decision.reason

                renderQueue.async { [weak self] in
                    let releaseGate = MirageRenderAdmissionReleaseGate {
                        renderAdmission.release()
                    }
                    guard self != nil else {
                        _ = releaseGate.releaseOnce()
                        return
                    }
                    renderer.render(
                        pixelBuffer: submission.pixelBuffer,
                        to: drawable,
                        contentRect: submission.contentRect,
                        outputPixelFormat: submission.outputPixelFormat,
                        onScheduled: {
                            guard admissionReleaseMode == .scheduled else { return }
                            _ = releaseGate.releaseOnce()
                        },
                        completion: { [weak self] wasPresented in
                            let releasedOnCompletion = releaseGate.releaseOnce()
                            if admissionReleaseMode == .scheduled, releasedOnCompletion, MirageLogger.isEnabled(.renderer) {
                                MirageLogger.renderer(
                                    "Render admission scheduled release fallback fired reason=\(policyReason.rawValue)"
                                )
                            }
                            Task { @MainActor [weak self] in
                                self?.handleRenderCompletion(
                                    startTime: drawStartTime,
                                    signalDelay: signalDelay,
                                    drawableWait: drawableWait,
                                    streamID: submission.streamID,
                                    sequence: submission.sequence,
                                    decodeTime: submission.decodeTime,
                                    wasPresented: wasPresented
                                )
                            }
                        }
                    )
                }
            }
        }
    }

    @MainActor
    private func prepareRenderSubmission(
        streamID: StreamID?,
        catchUpDepth: Int,
        preferLatestFrame: Bool,
        drawablePixelFormat: MTLPixelFormat
    ) -> RenderSubmission? {
        guard renderState.updateFrameIfNeeded(
            streamID: streamID,
            catchUpDepth: catchUpDepth,
            preferLatest: preferLatestFrame
        ) else {
            if let streamID, MirageFrameCache.shared.queueDepth(for: streamID) == 0 {
                renderDiagnostics.skipNoEntry &+= 1
            } else {
                renderDiagnostics.skipNoFrame &+= 1
            }
            return nil
        }

        if let pixelFormatType = renderState.currentPixelFormatType {
            updateOutputFormatIfNeeded(pixelFormatType)
        }

        guard var pixelBuffer = renderState.currentPixelBuffer else {
            renderDiagnostics.skipNoPixelBuffer &+= 1
            return nil
        }

        var contentRect = renderState.currentContentRect
        var sequence = renderState.currentSequence
        var decodeTime = renderState.currentDecodeTime

        var isStale = renderSequenceGate.noteRequestedAndCheckStale(sequence)

        if isStale {
            if renderState.updateFrameIfNeeded(
                streamID: streamID,
                catchUpDepth: 1,
                preferLatest: true
            ) {
                if let pixelFormatType = renderState.currentPixelFormatType {
                    updateOutputFormatIfNeeded(pixelFormatType)
                }
                if let refreshedPixelBuffer = renderState.currentPixelBuffer {
                    pixelBuffer = refreshedPixelBuffer
                    contentRect = renderState.currentContentRect
                    sequence = renderState.currentSequence
                    decodeTime = renderState.currentDecodeTime
                    isStale = renderSequenceGate.noteRequestedAndCheckStale(sequence)
                }
            }
        }

        guard !isStale else {
            renderDiagnostics.skipStale &+= 1
            renderState.clearCurrentFrame()
            renderScheduler.requestRedraw()
            return nil
        }

        return RenderSubmission(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            // Use the acquired drawable's format for this submission to avoid
            // pipeline/attachment mismatches if layer format changes this tick.
            outputPixelFormat: drawablePixelFormat,
            streamID: streamID,
            sequence: sequence,
            decodeTime: decodeTime
        )
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

    @MainActor
    private func scheduleInFlightCapRetry(now: CFAbsoluteTime, decision: MirageRenderPolicyDecision) {
        guard decision.allowsInFlightCapMicroRetry else { return }
        guard !admissionRetryScheduled else { return }
        if lastAdmissionRetryFireTime > 0, now - lastAdmissionRetryFireTime < Self.inFlightCapRetryMinInterval {
            return
        }
        admissionRetryScheduled = true
        admissionRetryTask?.cancel()
        admissionRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Self.inFlightCapRetryDelayMs))
            } catch {
                return
            }
            guard let self else { return }
            admissionRetryScheduled = false
            lastAdmissionRetryFireTime = CFAbsoluteTimeGetCurrent()
            admissionRetryFireCount &+= 1
            guard !renderingSuspended else { return }
            renderState.markNeedsRedraw()
            renderScheduler.requestRedraw()
            if MirageLogger.isEnabled(.renderer) {
                let inFlight = renderAdmission.snapshot()
                let queueDepth = streamID.map { MirageFrameCache.shared.queueDepth(for: $0) } ?? 0
                MirageLogger
                    .renderer(
                        "Render admission retry fired mode=\(latencyMode.rawValue) inFlight=\(inFlight)/\(decision.inFlightCap) " +
                            "queueDepth=\(queueDepth) capSkips=\(renderDiagnostics.skipInFlightCap) streak=\(capSkipStreak)"
                    )
            }
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

        let count = max(1, Double(drawStatsCount))
        let fps = count / elapsed
        let signalDelayAvgMs = (drawStatsSignalDelayTotal / count) * 1000
        let signalDelayMaxMs = drawStatsSignalDelayMax * 1000
        let drawableWaitAvgMs = (drawStatsDrawableWaitTotal / count) * 1000
        let drawableWaitMaxMs = drawStatsDrawableWaitMax * 1000
        let renderLatencyAvgMs = (drawStatsRenderLatencyTotal / count) * 1000
        let renderLatencyMaxMs = drawStatsRenderLatencyMax * 1000
        let frameBudgetMs = 1000.0 / Double(max(1, maxRenderFPS))
        let drawableWaitPressure = drawableWaitAvgMs > frameBudgetMs * Self.drawableWaitPressureFactor
        let hasCapPressure = renderDiagnostics.skipInFlightCap > 0

        if drawableWaitPressure {
            drawableWaitPressureUntil = now + Self.pressureWindow
        }
        if hasCapPressure {
            lastInFlightCapPressureTime = now
        }

        if MirageLogger.isEnabled(.renderer) {
            let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
            let signalDelayAvgText = signalDelayAvgMs.formatted(.number.precision(.fractionLength(1)))
            let signalDelayMaxText = signalDelayMaxMs.formatted(.number.precision(.fractionLength(1)))
            let drawableWaitAvgText = drawableWaitAvgMs.formatted(.number.precision(.fractionLength(1)))
            let drawableWaitMaxText = drawableWaitMaxMs.formatted(.number.precision(.fractionLength(1)))
            let renderLatencyAvgText = renderLatencyAvgMs.formatted(.number.precision(.fractionLength(1)))
            let renderLatencyMaxText = renderLatencyMaxMs.formatted(.number.precision(.fractionLength(1)))
            let queueDepth = streamID.map { MirageFrameCache.shared.queueDepth(for: $0) } ?? 0

            MirageLogger
                .renderer(
                    "Render timings: fps=\(fpsText) signalDelay=\(signalDelayAvgText)/\(signalDelayMaxText)ms " +
                        "drawableWait=\(drawableWaitAvgText)/\(drawableWaitMaxText)ms " +
                        "renderLatency=\(renderLatencyAvgText)/\(renderLatencyMaxText)ms"
                )
            MirageLogger
                .renderer(
                    "Render pressure drawableWait=\(drawableWaitAvgText)/\(drawableWaitMaxText)ms " +
                        "capSkips=\(renderDiagnostics.skipInFlightCap) streak=\(capSkipStreak) " +
                        "retryFires=\(admissionRetryFireCount) queueDepth=\(queueDepth)"
                )
        }

        updateRenderStability(
            now: now,
            renderedFPS: fps,
            drawableWaitAvgMs: drawableWaitAvgMs,
            drawableWaitMaxMs: drawableWaitMaxMs,
            hasCapPressure: hasCapPressure
        )
        updateRenderScale(
            now: now,
            renderedFPS: fps,
            drawableWaitAvgMs: drawableWaitAvgMs
        )

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

        let decision = resolvedRenderPolicyDecision(now: now)
        applyRenderPolicy(decision: decision, now: now)
        let maximumDrawableCount = max(1, metalLayer.maximumDrawableCount)
        let effectiveCap = decision.inFlightCap
        let inFlight = renderAdmission.snapshot()
        let acquisitionPending = drawableAcquisitionPending

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
                    "cap=\(renderDiagnostics.skipInFlightCap) acquire=\(renderDiagnostics.skipAcquirePending)) " +
                    "admission(inFlight=\(inFlight)/\(effectiveCap) " +
                    "acquirePending=\(acquisitionPending) " +
                    "drawables=\(maximumDrawableCount) target=\(maxRenderFPS) scale=\(renderScalePolicy.currentScale) " +
                    "capSkipStreak=\(capSkipStreak))"
            )

        renderDiagnostics.reset(now: now)
    }

    func allowsSecondaryCatchUpDraw() -> Bool {
        if usesDisplayClockLockedPresentation {
            return false
        }
        let decision = resolvedRenderPolicyDecision(now: CFAbsoluteTimeGetCurrent())
        return decision.allowsSecondaryCatchUpDraw
    }

    func allowsDecodeDrivenTickFallback(now: CFAbsoluteTime, targetFPS: Int) -> Bool {
        _ = now
        _ = targetFPS
        // Lowest-latency presentation is display-link clocked: decode callbacks mark redraw
        // pending, and only driver pulses are allowed to present.
        if usesDisplayClockLockedPresentation {
            return false
        }
        // Decode-driven fallback is gated by scheduler display-pulse lateness checks.
        return true
    }

    private var usesDisplayClockLockedPresentation: Bool {
        latencyMode == .lowestLatency
    }

    private func updateDecodeDrivenTriggerPolicy() {
        guard let streamID else { return }
        MirageClientRenderTrigger.shared.setDecodeDrivenRequestsEnabled(
            !usesDisplayClockLockedPresentation,
            for: streamID
        )
    }

    private func updateRenderStability(
        now: CFAbsoluteTime,
        renderedFPS: Double,
        drawableWaitAvgMs: Double,
        drawableWaitMaxMs: Double,
        hasCapPressure: Bool
    ) {
        let transition = renderStabilityPolicy.evaluate(
            now: now,
            latencyMode: latencyMode,
            targetFPS: maxRenderFPS,
            renderedFPS: renderedFPS,
            drawableWaitAvgMs: drawableWaitAvgMs,
            hasCapPressure: hasCapPressure,
            typingBurstActive: typingBurstActive(now: now)
        )
        let decision = resolvedRenderPolicyDecision(now: now)
        applyRenderPolicy(decision: decision, now: now)

        if transition.recoveryEntered {
            logRecoveryTransition(
                event: "entered",
                renderedFPS: renderedFPS,
                drawableWaitAvgMs: drawableWaitAvgMs,
                drawableWaitMaxMs: drawableWaitMaxMs,
                decision: decision
            )
        } else if transition.recoveryExited {
            logRecoveryTransition(
                event: "exited",
                renderedFPS: renderedFPS,
                drawableWaitAvgMs: drawableWaitAvgMs,
                drawableWaitMaxMs: drawableWaitMaxMs,
                decision: decision
            )
        } else if transition.promotionChanged, MirageLogger.isEnabled(.renderer) {
            let promotionState = renderStabilityPolicy.snapshot().smoothestPromotionActive ? "enabled" : "disabled"
            MirageLogger.renderer("Render policy smoothest promotion \(promotionState)")
        }
    }

    private func updateRenderScale(
        now: CFAbsoluteTime,
        renderedFPS: Double,
        drawableWaitAvgMs: Double
    ) {
        let transition = renderScalePolicy.evaluate(
            now: now,
            latencyMode: latencyMode,
            targetFPS: maxRenderFPS,
            renderedFPS: renderedFPS,
            drawableWaitAvgMs: drawableWaitAvgMs,
            typingBurstActive: typingBurstActive(now: now)
        )
        guard transition.changed else { return }

        renderState.markNeedsRedraw()
        setNeedsLayout()
        requestDraw()

        guard MirageLogger.isEnabled(.renderer) else { return }
        let fromText = transition.previousScale.formatted(.number.precision(.fractionLength(2)))
        let toText = transition.newScale.formatted(.number.precision(.fractionLength(2)))
        let directionText = transition.direction?.rawValue ?? "none"
        let stepDelayText = transition.secondsUntilNextStep.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.renderer(
            "Render scale transition mode=\(latencyMode.rawValue) direction=\(directionText) " +
                "scale=\(fromText)->\(toText) degradedStreak=\(transition.degradedStreak) " +
                "healthyStreak=\(transition.healthyStreak) nextStepIn=\(stepDelayText)s"
        )
    }

    private func logRecoveryTransition(
        event: String,
        renderedFPS: Double,
        drawableWaitAvgMs: Double,
        drawableWaitMaxMs: Double,
        decision: MirageRenderPolicyDecision
    ) {
        guard MirageLogger.isEnabled(.renderer) else { return }
        let renderedText = renderedFPS.formatted(.number.precision(.fractionLength(1)))
        let avgWaitText = drawableWaitAvgMs.formatted(.number.precision(.fractionLength(1)))
        let maxWaitText = drawableWaitMaxMs.formatted(.number.precision(.fractionLength(1)))
        let queueDepth = streamID.map { MirageFrameCache.shared.queueDepth(for: $0) } ?? 0
        MirageLogger
            .renderer(
                "Render recovery \(event) mode=\(latencyMode.rawValue) renderedFPS=\(renderedText) " +
                    "drawableWait=\(avgWaitText)/\(maxWaitText)ms cap=\(decision.inFlightCap) " +
                    "drawables=\(decision.maximumDrawableCount) queueDepth=\(queueDepth)"
            )
    }

    private func typingBurstActive(now: CFAbsoluteTime) -> Bool {
        guard let streamID else { return false }
        return MirageFrameCache.shared.isTypingBurstActive(for: streamID, now: now)
    }

    private func recentPressureActive(now: CFAbsoluteTime) -> Bool {
        if now <= drawableWaitPressureUntil {
            return true
        }
        if lastInFlightCapPressureTime == 0 {
            return false
        }
        return now - lastInFlightCapPressureTime <= Self.pressureWindow
    }

    private func resolvedRenderPolicyDecision(now: CFAbsoluteTime) -> MirageRenderPolicyDecision {
        MirageRenderAdmissionPolicy.decision(
            latencyMode: latencyMode,
            targetFPS: maxRenderFPS,
            typingBurstActive: typingBurstActive(now: now),
            recoveryActive: renderStabilityPolicy.snapshot().recoveryActive,
            smoothestPromotionActive: renderStabilityPolicy.snapshot().smoothestPromotionActive,
            pressureActive: recentPressureActive(now: now)
        )
    }

    private func applyRenderPolicy(
        now: CFAbsoluteTime,
        forceLog: Bool = false
    ) {
        let decision = resolvedRenderPolicyDecision(now: now)
        applyRenderPolicy(decision: decision, now: now, forceLog: forceLog)
    }

    private func applyRenderPolicy(
        decision: MirageRenderPolicyDecision,
        now _: CFAbsoluteTime,
        forceLog: Bool = false
    ) {
        let previousDecision = lastRenderPolicyDecision
        if metalLayer.maximumDrawableCount != decision.maximumDrawableCount {
            metalLayer.maximumDrawableCount = decision.maximumDrawableCount
        }
        guard forceLog || previousDecision != decision else { return }
        lastRenderPolicyDecision = decision
        guard MirageLogger.isEnabled(.renderer) else { return }
        MirageLogger
            .renderer(
                "Render policy mode=\(latencyMode.rawValue) cap=\(decision.inFlightCap) " +
                    "drawables=\(decision.maximumDrawableCount) reason=\(decision.reason.rawValue) " +
                    "release=\(decision.admissionReleaseMode.rawValue) keepDepth=\(decision.presentationKeepDepth) " +
                    "preferLatest=\(decision.prefersLatestFrameOnPressure)"
            )
        MirageLogger
            .renderer(
                "Render admission release mode=\(decision.admissionReleaseMode.rawValue) reason=\(decision.reason.rawValue)"
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
        if clamped >= 120 {
            renderScalePolicy.reset()
            setNeedsLayout()
        }
        renderScheduler.updateTargetFPS(clamped)
        applyDisplayRefreshRateLock(clamped)
        applyRenderPolicy(now: CFAbsoluteTimeGetCurrent(), forceLog: true)
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
    var skipAcquirePending: UInt64 = 0

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
        skipAcquirePending = 0
    }
}
#endif
