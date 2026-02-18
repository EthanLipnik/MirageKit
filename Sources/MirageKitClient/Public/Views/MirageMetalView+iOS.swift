//
//  MirageMetalView+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//
//  AVSampleBufferDisplayLayer-backed stream view on iOS and visionOS.
//

import MirageKit
#if os(iOS) || os(visionOS)
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

public class MirageMetalView: UIView {
    // MARK: - Safe Area Override

    override public var safeAreaInsets: UIEdgeInsets { .zero }

    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
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

    public var streamID: StreamID? {
        didSet {
            guard streamID != oldValue else { return }
            unregisterFrameListener(for: oldValue)
            registerFrameListener(for: streamID)
            resetPresentationState()
            requestDraw()
        }
    }

    // MARK: - Rendering State

    let preferencesObserver = MirageUserDefaultsObserver()
    lazy var refreshRateMonitor = MirageRefreshRateMonitor(view: self)
    var displayLink: CADisplayLink?

    private var renderingSuspended = false
    private var cachedFormatKey: PixelBufferFormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastEnqueuedSequence: UInt64 = 0
    private var listenerStreamID: StreamID?
    private var loggedLayerFailure = false
    private static let cmTimeScale: CMTimeScale = 1_000_000_000

    var maxRenderFPS: Int = 60
    var appliedRefreshRateLock: Int = 0

    var lastReportedDrawableSize: CGSize = .zero

    static let maxDrawableWidth: CGFloat = 5120
    static let maxDrawableHeight: CGFloat = 2880

    struct PixelBufferFormatKey: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("MirageMetalView requires AVSampleBufferDisplayLayer backing")
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

    deinit {
        unregisterFrameListener(for: listenerStreamID)
        stopDisplayLink()
        stopObservingPreferences()
    }

    // MARK: - UIView Lifecycle

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            refreshRateMonitor.start()
            startDisplayLinkIfNeeded()
            resumeRendering()
            requestDraw()
        } else {
            refreshRateMonitor.stop()
            stopDisplayLink()
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
        let displayLayer = self.displayLayer
        displayLayer.frame = bounds
        displayLayer.contentsScale = effectiveScale

        reportDrawableMetricsIfChanged()
        requestDraw()
    }

    // MARK: - Public Controls

    public func suspendRendering() {
        renderingSuspended = true
        displayLayer.flushAndRemoveImage()
        lastEnqueuedSequence = 0
    }

    public func resumeRendering() {
        renderingSuspended = false
        requestDraw()
    }

    // MARK: - Setup

    private func setup() {
        insetsLayoutMarginsFromSafeArea = false

        let displayLayer = self.displayLayer
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsScale = effectiveScale
        displayLayer.isOpaque = true
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        refreshRateMonitor.onOverrideChange = { [weak self] override in
            self?.applyRefreshRateOverride(override)
        }

        applyRenderPreferences()
        startObservingPreferences()
    }

    // MARK: - Draw Path

    func requestDraw() {
        guard !renderingSuspended else { return }
        drainLatestFrameIfPossible(presentationTime: CACurrentMediaTime())
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard !renderingSuspended else { return }
        drainLatestFrameIfPossible(presentationTime: link.timestamp)
    }

    private func drainLatestFrameIfPossible(presentationTime: CFTimeInterval) {
        guard let streamID else { return }
        recoverDisplayLayerIfNeeded()
        guard displayLayer.status != .failed else { return }
        guard displayLayer.isReadyForMoreMediaData else { return }

        guard let frame = MirageFrameCache.shared.dequeueForPresentation(
            for: streamID,
            policy: .latest
        ) else {
            return
        }

        guard frame.sequence > lastEnqueuedSequence else { return }

        updateLayerContentRect(frame.contentRect, pixelBuffer: frame.pixelBuffer)
        guard let sampleBuffer = makeSampleBuffer(from: frame.pixelBuffer, presentationTime: presentationTime) else {
            return
        }

        displayLayer.enqueue(sampleBuffer)
        lastEnqueuedSequence = frame.sequence
        MirageFrameCache.shared.markPresented(sequence: frame.sequence, for: streamID)
    }

    private func updateLayerContentRect(_ contentRect: CGRect, pixelBuffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else {
            displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        let normalized = CGRect(
            x: min(max(contentRect.origin.x / width, 0), 1),
            y: min(max(contentRect.origin.y / height, 0), 1),
            width: min(max(contentRect.size.width / width, 0), 1),
            height: min(max(contentRect.size.height / height, 0), 1)
        )
        displayLayer.contentsRect = normalized
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationTime: CFTimeInterval
    ) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription(for: pixelBuffer) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                seconds: presentationTime,
                preferredTimescale: Self.cmTimeScale
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            MirageLogger.error(.renderer, "CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
            return nil
        }

        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        return sampleBuffer
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        let key = PixelBufferFormatKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )

        if key == cachedFormatKey, let cachedFormatDescription {
            return cachedFormatDescription
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            MirageLogger.error(.renderer, "CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
            return nil
        }

        cachedFormatKey = key
        cachedFormatDescription = formatDescription
        return formatDescription
    }

    private func resetPresentationState() {
        cachedFormatKey = nil
        cachedFormatDescription = nil
        lastEnqueuedSequence = 0
        loggedLayerFailure = false
        displayLayer.flushAndRemoveImage()
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func registerFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        listenerStreamID = streamID
        MirageRenderStreamStore.shared.registerFrameListener(for: streamID, owner: self) { [weak self] in
            guard let self else { return }
            if Thread.isMainThread {
                self.requestDraw()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.requestDraw()
                }
            }
        }
    }

    private func unregisterFrameListener(for streamID: StreamID?) {
        guard let streamID else { return }
        MirageRenderStreamStore.shared.unregisterFrameListener(for: streamID, owner: self)
        if listenerStreamID == streamID {
            listenerStreamID = nil
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        configureDisplayLinkRate(link, fps: appliedRefreshRateLock > 0 ? appliedRefreshRateLock : maxRenderFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func recoverDisplayLayerIfNeeded() {
        guard displayLayer.status == .failed else { return }
        if !loggedLayerFailure {
            let description = displayLayer.error?.localizedDescription ?? "unknown error"
            MirageLogger.error(.renderer, "AVSampleBufferDisplayLayer failure: \(description)")
            loggedLayerFailure = true
        }
        displayLayer.flushAndRemoveImage()
    }
}
#endif
