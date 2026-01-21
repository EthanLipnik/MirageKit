import Foundation
import Metal
import MetalKit
import CoreVideo
import SwiftUI

// MARK: - Global Frame Cache (iOS Gesture Tracking Support)

/// Global frame cache for iOS gesture tracking support.
/// This provides a completely actor-free path for the Metal view to access frames.
/// During iOS gesture tracking (UITrackingRunLoopMode), accessing any @MainActor object
/// can cause synchronous waits that block the entire app. By using a global cache with
/// simple lock-based synchronization, the Metal view's draw loop can access frames
/// without any Swift concurrency overhead.
public final class MirageFrameCache: @unchecked Sendable {
    /// Shared instance - use this from both decode callbacks and Metal views
    public static let shared = MirageFrameCache()

    private let lock = NSLock()
    private var frames: [StreamID: (pixelBuffer: CVPixelBuffer, contentRect: CGRect)] = [:]

    private init() {}

    /// Store a frame for a stream (called from decode callback)
    public func store(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect, for streamID: StreamID) {
        lock.lock()
        frames[streamID] = (pixelBuffer, contentRect)
        lock.unlock()
    }

    /// Get the latest frame for a stream (called from Metal draw loop)
    public func get(for streamID: StreamID) -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)? {
        lock.lock()
        let result = frames[streamID]
        lock.unlock()
        return result
    }

    /// Clear frame for a stream (called when stream ends)
    public func clear(for streamID: StreamID) {
        lock.lock()
        frames.removeValue(forKey: streamID)
        lock.unlock()
    }
}

// MARK: - macOS MirageMetalView

#if os(macOS)
import AppKit

/// Metal-backed view for displaying streamed content on macOS
public class MirageMetalView: MTKView {
    private var renderer: MetalRenderer?
    private var currentTexture: MTLTexture?
    private var currentContentRect: CGRect = .zero

    /// Stream ID for direct frame cache access (gesture tracking support)
    var streamID: StreamID?

    /// Legacy frame provider for backwards compatibility (not used if streamID is set)
    var frameProvider: (() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?)?

    /// Track the last pixel buffer to avoid redundant texture creation
    private weak var lastPixelBuffer: CVPixelBuffer?

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

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
        isPaused = false
        enableSetNeedsDisplay = false

        // Adapt to actual screen refresh rate (120Hz for ProMotion, 60Hz for standard)
        preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120

        // P3 color space with 10-bit color for wide color gamut
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        colorPixelFormat = .bgr10a2Unorm
    }

    public override func layout() {
        super.layout()
        reportDrawableSizeIfChanged()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    private func reportDrawableSizeIfChanged() {
        let drawableSize = self.drawableSize
        if drawableSize != lastReportedDrawableSize && drawableSize.width > 0 && drawableSize.height > 0 {
            lastReportedDrawableSize = drawableSize
            MirageLogger.renderer("Drawable size: \(drawableSize.width)x\(drawableSize.height) px (bounds: \(bounds.size))")
            onDrawableSizeChanged?(drawableSize)
        }
    }

    /// Update with a new decoded frame
    /// - Parameters:
    ///   - pixelBuffer: The decoded video frame
    ///   - contentRect: The region within the buffer containing actual content (for SCK black bar cropping)
    public func updateFrame(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect = .zero) {
        currentTexture = renderer?.createTexture(from: pixelBuffer)
        currentContentRect = contentRect
        lastPixelBuffer = pixelBuffer
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update to avoid MainActor stalls during menu tracking/dragging.
        if let id = streamID, let (pixelBuffer, contentRect) = MirageFrameCache.shared.get(for: id) {
            if pixelBuffer !== lastPixelBuffer {
                currentTexture = renderer?.createTexture(from: pixelBuffer)
                currentContentRect = contentRect
                lastPixelBuffer = pixelBuffer
            }
        } else if let (pixelBuffer, contentRect) = frameProvider?() {
            if pixelBuffer !== lastPixelBuffer {
                currentTexture = renderer?.createTexture(from: pixelBuffer)
                currentContentRect = contentRect
                lastPixelBuffer = pixelBuffer
            }
        }

        guard let drawable = currentDrawable,
              let texture = currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: currentContentRect)
    }
}

// MARK: - Scroll Physics Capturing View (macOS)

/// Invisible scroll view that captures native trackpad scroll physics on macOS.
/// The actual content (Metal view) stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
private class ScrollPhysicsCapturingNSView: NSView {
    /// The invisible scroll view for capturing trackpad physics
    private let scrollView: NSScrollView

    /// The document view that scrollView scrolls (large canvas)
    private let documentView: FlippedView

    /// The actual content we display (stays pinned to bounds)
    let contentView: NSView

    /// Callback for scroll events: (deltaX, deltaY, location, phase, momentumPhase, isPrecise)
    /// Location is in normalized coordinates (0-1 within view bounds)
    var onScroll: ((CGFloat, CGFloat, CGPoint?, MirageScrollPhase, MirageScrollPhase, Bool) -> Void)?

    /// Callback for mouse events - used for forwarding clicks to host
    var onMouseEvent: ((MirageInputEvent) -> Void)?

    /// Track current modifier state
    private var currentModifiers: MirageModifierFlags = []

    /// Last known mouse location (normalized) for scroll events
    private var lastMouseLocation: CGPoint?

    /// Size of scrollable area - large enough for extended scrolling before recenter
    private let scrollableSize: CGFloat = 100_000

    /// Last scroll position for delta calculation
    private var lastScrollPosition: CGPoint = .zero

    /// Whether we need to recenter after momentum ends
    private var needsRecenter = false

    /// Flag to suppress scroll events during recenter operation
    private var isRecentering = false

    override init(frame: CGRect) {
        scrollView = NSScrollView(frame: frame)
        documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize))
        contentView = NSView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        scrollView = NSScrollView()
        documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize))
        contentView = NSView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Configure scroll view - hide scrollers, no background
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Enable elastic scrolling for bounce effect
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed

        // Content view holds the Metal view (stays pinned)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // Add scroll view as overlay (for capturing scroll events)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Scroll view fills our bounds
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Content view also fills bounds (stays stationary)
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Listen for scroll changes via bounds notification
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    override func layout() {
        super.layout()

        // Ensure documentView maintains its large size (NSScrollView may resize it)
        if documentView.frame.size.width != scrollableSize || documentView.frame.size.height != scrollableSize {
            documentView.frame = NSRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize)
        }

        recenterIfNeeded(force: lastScrollPosition == .zero)
    }

    /// Center the scroll view's content offset
    private func recenterIfNeeded(force: Bool = false) {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let centerPoint = NSPoint(
            x: (scrollableSize - bounds.width) / 2,
            y: (scrollableSize - bounds.height) / 2
        )

        if force || needsRecenter {
            // Suppress scroll events during recenter operation
            isRecentering = true
            documentView.scroll(centerPoint)
            lastScrollPosition = centerPoint
            needsRecenter = false
            isRecentering = false
        }
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        // Skip sending events during recenter operation
        guard !isRecentering else { return }

        let currentPos = scrollView.documentVisibleRect.origin
        // Calculate deltas (content moving = scroll in opposite direction)
        let deltaX = lastScrollPosition.x - currentPos.x
        let deltaY = currentPos.y - lastScrollPosition.y  // NSScrollView Y is flipped
        lastScrollPosition = currentPos

        if deltaX != 0 || deltaY != 0 {
            // Phase determination based on scroll state
            let phase: MirageScrollPhase = .changed
            let momentumPhase: MirageScrollPhase = .none
            // Use last known mouse location for scroll position
            onScroll?(deltaX, deltaY, lastMouseLocation, phase, momentumPhase, true)
        }
    }

    // Override scrollWheel to capture phases and handle momentum
    override func scrollWheel(with event: NSEvent) {
        // Extract phases from NSEvent
        let phase = MirageScrollPhase(from: event.phase)
        let momentumPhase = MirageScrollPhase(from: event.momentumPhase)

        // Get mouse location and normalize to 0-1 within view bounds
        let locationInView = convert(event.locationInWindow, from: nil)
        if bounds.width > 0 && bounds.height > 0 {
            lastMouseLocation = CGPoint(
                x: locationInView.x / bounds.width,
                y: 1.0 - (locationInView.y / bounds.height)  // Flip Y for normalized coords
            )
        }

        // Forward to scroll view for physics processing
        scrollView.scrollWheel(with: event)

        // Check if this is the end of scrolling
        if event.phase == .ended || event.momentumPhase == .ended {
            needsRecenter = true
            // Delay recenter slightly to allow final deceleration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.recenterIfNeeded()
            }
        }

        // Send phase events so the host can end scroll smoothing promptly.
        if phase == .began || phase == .ended || phase == .cancelled ||
            momentumPhase == .began || momentumPhase == .ended || momentumPhase == .cancelled {
            let isPrecise = event.hasPreciseScrollingDeltas
            onScroll?(0, 0, lastMouseLocation, phase, momentumPhase, isPrecise)
        }
    }

    // MARK: - Mouse Event Handling

    override func mouseDown(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDown(mouseEvent))
    }

    override func mouseUp(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseUp(mouseEvent))
    }

    override func mouseDragged(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDragged(mouseEvent))
    }

    override func mouseMoved(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        lastMouseLocation = location
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: 0,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseMoved(mouseEvent))
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDown(mouseEvent))
    }

    override func rightMouseUp(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseUp(mouseEvent))
    }

    override func rightMouseDragged(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDragged(mouseEvent))
    }

    override func otherMouseDown(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseDown(mouseEvent))
    }

    override func otherMouseUp(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseUp(mouseEvent))
    }

    override func otherMouseDragged(with event: NSEvent) {
        let location = normalizedLocation(from: event)
        let mouseEvent = MirageMouseEvent(
            button: MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseDragged(mouseEvent))
    }

    // MARK: - Keyboard Event Handling

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        // Clear modifier state when losing focus to prevent stuck modifiers
        if !currentModifiers.isEmpty {
            currentModifiers = []
            onMouseEvent?(.flagsChanged(currentModifiers))
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: event.isARepeat
        )
        onMouseEvent?(.keyDown(keyEvent))
    }

    override func keyUp(with event: NSEvent) {
        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: false
        )
        onMouseEvent?(.keyUp(keyEvent))
    }

    override func flagsChanged(with event: NSEvent) {
        currentModifiers = MirageModifierFlags(nsEventFlags: event.modifierFlags)
        onMouseEvent?(.flagsChanged(currentModifiers))
    }

    /// Normalize mouse location to 0-1 range within view bounds
    private func normalizedLocation(from event: NSEvent) -> CGPoint {
        let locationInView = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: locationInView.x / bounds.width,
            y: 1.0 - (locationInView.y / bounds.height)  // Flip Y for normalized coords
        )
    }

    /// Enable tracking area for mouse moved events
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Add new tracking area for the entire view
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// A flipped NSView for correct coordinate system in scroll view
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

#elseif os(iOS) || os(visionOS)
import UIKit

/// Metal-backed view for displaying streamed content on iOS/visionOS
public class MirageMetalView: MTKView {

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal drawable fills entire screen
    public override var safeAreaInsets: UIEdgeInsets { .zero }

    private var renderer: MetalRenderer?
    private var currentTexture: MTLTexture?
    private var currentContentRect: CGRect = .zero

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Last reported drawable size to avoid redundant callbacks
    private var lastReportedDrawableSize: CGSize = .zero

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// The Metal view reads frames directly from MirageFrameCache using this ID,
    /// completely bypassing any Swift actor machinery that could block during gestures.
    public var streamID: StreamID?

    /// Legacy frame provider for backwards compatibility (not used if streamID is set)
    public var frameProvider: (() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?)?

    /// Track the last pixel buffer to avoid redundant texture creation
    private weak var lastPixelBuffer: CVPixelBuffer?

    /// Custom display link so drawing continues in UITrackingRunLoopMode.
    private var displayLink: CADisplayLink?


    private var effectiveScale: CGFloat {
        if let screenScale = window?.screen.nativeScale {
            return screenScale
        }
        // Default to 2.0 (Retina) if we can't determine the screen
        return 2.0
    }

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
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            // Adapt to actual screen refresh rate (120Hz for ProMotion, 60Hz for standard)
            preferredFramesPerSecond = window.screen.maximumFramesPerSecond
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    deinit {
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFramesPerSecond = preferredFramesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Restart the display link if needed after returning from background.
    /// Called when app becomes active to ensure rendering resumes.
    public func restartDisplayLinkIfNeeded() {
        guard window != nil, displayLink == nil else { return }
        startDisplayLink()
    }

    /// Pause the display link when app enters background to avoid Metal GPU permission errors
    /// iOS doesn't allow GPU work from background state - attempting to render causes
    /// "Insufficient Permission to submit GPU work from background" errors
    public func pauseDisplayLink() {
        stopDisplayLink()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        draw()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        // CRITICAL: Ensure scale factor is maintained - UIKit/SwiftUI may reset it
        let expectedScale = effectiveScale
        if contentScaleFactor != expectedScale {
            contentScaleFactor = expectedScale
        }
        if let metalLayer = layer as? CAMetalLayer, metalLayer.contentsScale != expectedScale {
            metalLayer.contentsScale = expectedScale
        }

        if bounds.width > 0, bounds.height > 0 {
            let expectedDrawableSize = CGSize(
                width: bounds.width * expectedScale,
                height: bounds.height * expectedScale
            )
            if drawableSize != expectedDrawableSize {
                drawableSize = expectedDrawableSize
            }
        }

        reportDrawableSizeIfChanged()
    }

    /// Report actual drawable pixel size to ensure host captures at correct resolution
    /// FIRST report is immediate (no debounce) to enable correct initial resolution
    /// Subsequent reports are sent immediately on significant changes to begin resize blur right away.
    private func reportDrawableSizeIfChanged() {
        let drawableSize = self.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        // FIRST report should be IMMEDIATE - critical for getting initial resolution correct
        // This prevents the orientation mismatch where stream starts at portrait but drawable is landscape
        if lastReportedDrawableSize.width == 0 && lastReportedDrawableSize.height == 0 {
            lastReportedDrawableSize = drawableSize
            MirageLogger.renderer("Initial drawable size (immediate): \(drawableSize.width)x\(drawableSize.height) px")
            onDrawableSizeChanged?(drawableSize)
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

        guard significantWidthChange || significantHeightChange else {
            return  // Skip - change is too small
        }

        lastReportedDrawableSize = drawableSize
        MirageLogger.renderer("Drawable size changed: \(drawableSize.width)x\(drawableSize.height) px")
        onDrawableSizeChanged?(drawableSize)
    }

    /// Update with a new decoded frame
    /// - Parameters:
    ///   - pixelBuffer: The decoded video frame
    ///   - contentRect: The region within the buffer containing actual content (for SCK black bar cropping)
    public func updateFrame(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect = .zero) {
        currentTexture = renderer?.createTexture(from: pixelBuffer)
        currentContentRect = contentRect
        lastPixelBuffer = pixelBuffer
    }

    public override func draw(_ rect: CGRect) {
        // Pull-based frame update: read directly from global cache using stream ID
        // This completely bypasses Swift actor machinery that blocks during iOS gesture tracking.
        // CRITICAL: No closures, no weak references to @MainActor objects, just direct cache access.
        if let id = streamID, let (pixelBuffer, contentRect) = MirageFrameCache.shared.get(for: id) {
            // Only create new texture if pixel buffer changed (pointer comparison)
            if pixelBuffer !== lastPixelBuffer {
                currentTexture = renderer?.createTexture(from: pixelBuffer)
                currentContentRect = contentRect
                lastPixelBuffer = pixelBuffer
            }
        } else if let (pixelBuffer, contentRect) = frameProvider?() {
            // Legacy fallback for backwards compatibility
            if pixelBuffer !== lastPixelBuffer {
                currentTexture = renderer?.createTexture(from: pixelBuffer)
                currentContentRect = contentRect
                lastPixelBuffer = pixelBuffer
            }
        }

        guard let drawable = currentDrawable,
              let texture = currentTexture else { return }

        renderer?.render(texture: texture, to: drawable, contentRect: currentContentRect)
    }
}

// MARK: - Input Capturing View (iOS/iPadOS)

/// A view that wraps MirageMetalView and captures all input events
public class InputCapturingView: UIView {
    public let metalView: MirageMetalView

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal view fills entire screen.
    /// SwiftUI's .ignoresSafeArea() doesn't propagate through UIViewRepresentable boundaries,
    /// so we must explicitly return zero insets at the UIKit layer.
    public override var safeAreaInsets: UIEdgeInsets { .zero }

    /// Callback for input events - set by the SwiftUI representable's coordinator
    public var onInputEvent: ((MirageInputEvent) -> Void)? {
        didSet {
            if onInputEvent != nil {
                sendModifierStateIfNeeded(force: true)
            }
        }
    }

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)? {
        didSet {
            metalView.onDrawableSizeChanged = onDrawableSizeChanged
        }
    }

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// Forwards to the underlying Metal view
    public var streamID: StreamID? {
        didSet {
            metalView.streamID = streamID
        }
    }

    /// Legacy frame provider for backwards compatibility
    public var frameProvider: (() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?)? {
        didSet {
            metalView.frameProvider = frameProvider
        }
    }

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool = false

    // Cursor state from host
    private var currentCursorType: MirageCursorType = .arrow
    private var cursorIsVisible: Bool = true
    private var pointerInteraction: UIPointerInteraction?

    // Gesture recognizers
    private var tapGesture: UITapGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!
    private var scrollGesture: UIPanGestureRecognizer!
    private var hoverGesture: UIHoverGestureRecognizer!
    private var rightClickGesture: UITapGestureRecognizer!

    // Track drag state
    private var isDragging = false
    private var lastPanLocation: CGPoint = .zero

    // Track last cursor position for scroll events (normalized 0-1)
    private var lastCursorPosition: CGPoint?

    // Track keyboard modifier state - single source of truth
    // Gesture events read modifiers directly from gesture.modifierFlags at event time
    private var heldModifierKeys: Set<UIKeyboardHIDUsage> = []
    private var capsLockEnabled: Bool = false
    private var lastSentModifiers: MirageModifierFlags = []

    /// Get current modifier state from held keyboard keys
    private var keyboardModifiers: MirageModifierFlags {
        var modifiers: MirageModifierFlags = []
        for keyCode in heldModifierKeys {
            if let modifier = Self.modifierKeyMap[keyCode] {
                modifiers.insert(modifier)
            }
        }
        if capsLockEnabled {
            modifiers.insert(.capsLock)
        }
        return modifiers
    }

    private func sendModifierStateIfNeeded(force: Bool = false) {
        let modifiers = keyboardModifiers
        guard force || modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
        onInputEvent?(.flagsChanged(modifiers))
    }

    private func updateCapsLockState(from modifierFlags: UIKeyModifierFlags) {
        let isEnabled = modifierFlags.contains(.alphaShift)
        guard isEnabled != capsLockEnabled else { return }
        capsLockEnabled = isEnabled
        sendModifierStateIfNeeded(force: true)
    }

    private func resyncModifierState(from modifierFlags: UIKeyModifierFlags) {
        let flags = MirageModifierFlags(uiKeyModifierFlags: modifierFlags)
        var newHeldKeys = Set<UIKeyboardHIDUsage>()
        for (flag, keyCode) in Self.modifierFlagToKey where flags.contains(flag) {
            newHeldKeys.insert(keyCode)
        }

        let newCapsLockEnabled = flags.contains(.capsLock)

        guard newHeldKeys != heldModifierKeys || newCapsLockEnabled != capsLockEnabled else { return }
        heldModifierKeys = newHeldKeys
        capsLockEnabled = newCapsLockEnabled
        sendModifierStateIfNeeded(force: true)
    }

    /// Clear all held modifiers with a snapshot update
    private func resetAllModifiers() {
        guard !heldModifierKeys.isEmpty || capsLockEnabled else { return }
        heldModifierKeys.removeAll()
        capsLockEnabled = false
        sendModifierStateIfNeeded(force: true)
    }

    // Double-click detection state (left click)
    private var lastTapTime: TimeInterval = 0
    private var lastTapLocation: CGPoint = .zero
    private var currentClickCount: Int = 0

    // Double-click detection state (right click)
    private var lastRightTapTime: TimeInterval = 0
    private var lastRightTapLocation: CGPoint = .zero
    private var currentRightClickCount: Int = 0

    /// Maximum time between taps to count as multi-click (in seconds)
    private static let multiClickTimeThreshold: TimeInterval = 0.5
    /// Maximum distance between taps to count as multi-click (in normalized coordinates)
    private static let multiClickDistanceThreshold: CGFloat = 0.05

    // Scroll physics capturing view for native trackpad momentum/bounce
    private var scrollPhysicsView: ScrollPhysicsCapturingView?

    // Direct touch multi-finger gestures
    private var directPinchGesture: UIPinchGestureRecognizer!
    private var directRotationGesture: UIRotationGestureRecognizer!
    private var lastDirectPinchScale: CGFloat = 1.0
    private var lastDirectRotationAngle: CGFloat = 0.0

    /// Modifier key HID codes and their corresponding flags
    private static let modifierKeyMap: [UIKeyboardHIDUsage: MirageModifierFlags] = [
        .keyboardLeftShift: .shift,
        .keyboardRightShift: .shift,
        .keyboardLeftControl: .control,
        .keyboardRightControl: .control,
        .keyboardLeftAlt: .option,
        .keyboardRightAlt: .option,
        .keyboardLeftGUI: .command,
        .keyboardRightGUI: .command,
        .keyboardCapsLock: .capsLock
    ]

    /// Canonical key codes for modifier flag resync
    private static let modifierFlagToKey: [(flag: MirageModifierFlags, keyCode: UIKeyboardHIDUsage)] = [
        (.shift, .keyboardLeftShift),
        (.control, .keyboardLeftControl),
        (.option, .keyboardLeftAlt),
        (.command, .keyboardLeftGUI)
    ]


    // Key repeat handling
    /// Active key repeat timers keyed by HID usage code
    private var keyRepeatTimers: [UIKeyboardHIDUsage: Timer] = [:]
    /// Held key press references for generating repeat events
    private var heldKeyPresses: [UIKeyboardHIDUsage: UIPress] = [:]
    /// Initial delay before key repeat starts (matches macOS default)
    private static let keyRepeatInitialDelay: TimeInterval = 0.5
    /// Interval between repeat events (matches macOS default ~30 chars/sec)
    private static let keyRepeatInterval: TimeInterval = 0.033

    public override init(frame: CGRect) {
        metalView = MirageMetalView(frame: frame, device: nil)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        metalView = MirageMetalView(frame: .zero, device: nil)
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Ensure this view doesn't respect safe area insets
        insetsLayoutMarginsFromSafeArea = false

        // Create scroll physics view to wrap the Metal view
        // This provides native trackpad scrolling physics (momentum, bounce)
        scrollPhysicsView = ScrollPhysicsCapturingView(frame: .zero)
        scrollPhysicsView!.translatesAutoresizingMaskIntoConstraints = false

        // Add metal view to the scroll physics view's content view
        metalView.translatesAutoresizingMaskIntoConstraints = false
        scrollPhysicsView!.contentView.addSubview(metalView)

        // Add scroll physics view to self
        addSubview(scrollPhysicsView!)

        NSLayoutConstraint.activate([
            // Scroll physics view fills our bounds
            scrollPhysicsView!.topAnchor.constraint(equalTo: topAnchor),
            scrollPhysicsView!.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollPhysicsView!.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollPhysicsView!.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Metal view fills the content view
            metalView.topAnchor.constraint(equalTo: scrollPhysicsView!.contentView.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: scrollPhysicsView!.contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: scrollPhysicsView!.contentView.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: scrollPhysicsView!.contentView.bottomAnchor)
        ])

        // Configure scroll physics callback
        // Scroll events don't have a gesture recognizer with modifierFlags, so use keyboard state only
        scrollPhysicsView!.onScroll = { [weak self] deltaX, deltaY, phase, momentumPhase in
            guard let self else { return }
            let scrollEvent = MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: self.lastCursorPosition,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: self.keyboardModifiers,
                isPrecise: true  // Trackpad scrolling is precise
            )
            self.onInputEvent?(.scrollWheel(scrollEvent))
        }

        // Configure trackpad pinch callback
        scrollPhysicsView!.onPinch = { [weak self] magnification, phase in
            guard let self else { return }
            let event = MirageMagnifyEvent(magnification: magnification, phase: phase)
            self.onInputEvent?(.magnify(event))
        }

        // Configure trackpad rotation callback
        scrollPhysicsView!.onRotation = { [weak self] rotation, phase in
            guard let self else { return }
            let event = MirageRotateEvent(rotation: rotation, phase: phase)
            self.onInputEvent?(.rotate(event))
        }

        // Enable user interaction
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true

        setupGestureRecognizers()
        setupPointerInteraction()
        setupSceneLifecycleObservers()
    }

    private func setupSceneLifecycleObservers() {
        // Clear modifiers when app goes to background to prevent stuck modifiers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Handle app returning to foreground for stream recovery
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appWillResignActive() {
        // Clear all modifier and key repeat state when app loses focus
        stopAllKeyRepeats()
        resetAllModifiers()

        // Pause display link to avoid Metal GPU permission errors when backgrounded
        // iOS doesn't allow GPU work from background state
        metalView.pauseDisplayLink()
    }

    @objc private func appDidBecomeActive() {
        // Ensure display link is running after returning from background
        if window != nil {
            metalView.restartDisplayLinkIfNeeded()
        }

        sendModifierStateIfNeeded(force: true)

        // Notify SwiftUI layer to trigger stream recovery
        onBecomeActive?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupGestureRecognizers() {
        // Tap gesture (works with touch and pointer click)
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(tapGesture)

        // Right-click gesture (secondary click with pointer)
        rightClickGesture = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickGesture.buttonMaskRequired = .secondary
        rightClickGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(rightClickGesture)

        // Pan gesture for dragging (touch and pointer)
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(panGesture)

        // Scroll gesture - ONLY for direct touch (2-finger pan on screen)
        // Trackpad scrolling uses ScrollPhysicsCapturingView for native momentum/bounce
        scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.allowedScrollTypesMask = []  // Disable trackpad scroll handling
        scrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        addGestureRecognizer(scrollGesture)

        // Hover gesture for pointer movement tracking
        hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hoverGesture)

        // Pinch gesture for direct touch zoom
        directPinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handleDirectPinch(_:)))
        directPinchGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directPinchGesture.delegate = self
        addGestureRecognizer(directPinchGesture)

        // Rotation gesture for direct touch
        directRotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleDirectRotation(_:)))
        directRotationGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directRotationGesture.delegate = self
        addGestureRecognizer(directRotationGesture)

        // Allow simultaneous recognition
        tapGesture.delegate = self
        panGesture.delegate = self
        scrollGesture.delegate = self
    }

    private func setupPointerInteraction() {
        // Add pointer interaction for cursor customization
        let interaction = UIPointerInteraction(delegate: self)
        pointerInteraction = interaction
        addInteraction(interaction)
    }

    // MARK: - First Responder (for keyboard)

    public override var canBecomeFirstResponder: Bool { true }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    public override func resignFirstResponder() -> Bool {
        // Clear all modifier and key repeat state when losing focus
        stopAllKeyRepeats()
        resetAllModifiers()
        return super.resignFirstResponder()
    }

    // MARK: - Coordinate Helpers

    /// Normalize a point to 0-1 range relative to view bounds
    /// The gesture location is in self's coordinate space, so normalize against self.bounds
    /// This ensures correct mapping regardless of nested view hierarchy offsets
    private func normalizedLocation(_ point: CGPoint) -> CGPoint {
        // Normalize directly against our bounds - the view receiving the gesture
        // Scale factors cancel out: (point * scale) / (bounds * scale) = point / bounds
        guard bounds.width > 0 && bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)  // Default to center if bounds not ready
        }

        var normalized = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )

        if dockSnapEnabled {
            // Snap cursor to bottom edge when in dock trigger zone (bottom 1%)
            // This allows users to easily open the iPad dock without precise edge targeting
            if normalized.y >= 0.99 {
                normalized.y = 1.0
            }
        }

        return normalized
    }

    /// Get combined modifiers from a gesture (at event time) and keyboard state
    /// This is the proper way to get modifiers for pointer events - read from gesture directly
    private func modifiers(from gesture: UIGestureRecognizer) -> MirageModifierFlags {
        resyncModifierState(from: gesture.modifierFlags)
        let gestureModifiers = MirageModifierFlags(uiKeyModifierFlags: gesture.modifierFlags)
        return gestureModifiers.union(keyboardModifiers)
    }

    // MARK: - Gesture Handlers

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        let now = CACurrentMediaTime()

        // Detect multi-click: check if this tap is close enough in time and space to the previous one
        let timeSinceLastTap = now - lastTapTime
        let distance = hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y)

        if timeSinceLastTap < Self.multiClickTimeThreshold && distance < Self.multiClickDistanceThreshold {
            // Increment click count for multi-click (double-click, triple-click, etc.)
            currentClickCount += 1
        } else {
            // Reset to single click
            currentClickCount = 1
        }

        // Update tracking state for next tap
        lastTapTime = now
        lastTapLocation = location

        // Debug logging for coordinate tracking
        MirageLogger.client("TAP: raw=(\(Int(rawLocation.x)), \(Int(rawLocation.y))), bounds=(\(Int(bounds.width))x\(Int(bounds.height))), normalized=(\(String(format: "%.3f", location.x)), \(String(format: "%.3f", location.y))), clickCount=\(currentClickCount)")

        // Read modifiers directly from gesture at event time
        let eventModifiers = modifiers(from: gesture)

        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: currentClickCount,
            modifiers: eventModifiers
        )

        // Send mouse down then mouse up for a click
        onInputEvent?(.mouseDown(mouseEvent))
        onInputEvent?(.mouseUp(mouseEvent))
    }

    @objc private func handleRightClick(_ gesture: UITapGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))
        let now = CACurrentMediaTime()

        // Detect multi-click for right button
        let timeSinceLastTap = now - lastRightTapTime
        let distance = hypot(location.x - lastRightTapLocation.x, location.y - lastRightTapLocation.y)

        if timeSinceLastTap < Self.multiClickTimeThreshold && distance < Self.multiClickDistanceThreshold {
            currentRightClickCount += 1
        } else {
            currentRightClickCount = 1
        }

        lastRightTapTime = now
        lastRightTapLocation = location

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: currentRightClickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            isDragging = true
            lastPanLocation = location
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseDown(mouseEvent))

        case .changed:
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseDragged(mouseEvent))
            lastPanLocation = location

        case .ended, .cancelled:
            isDragging = false
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseUp(mouseEvent))

        default:
            break
        }
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        // For touch scrolling, use the gesture location (center of two fingers)
        let location = normalizedLocation(gesture.location(in: self))

        // Reset translation to get incremental deltas
        gesture.setTranslation(.zero, in: self)

        let eventModifiers = modifiers(from: gesture)
        let scrollEvent = MirageScrollEvent(
            deltaX: translation.x,
            deltaY: translation.y,
            location: location,
            phase: MirageScrollPhase(gestureState: gesture.state),
            modifiers: eventModifiers,
            isPrecise: true  // Trackpad/touch scrolling is precise
        )

        onInputEvent?(.scrollWheel(scrollEvent))
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))

        switch gesture.state {
        case .began, .changed:
            // Track cursor position for scroll events
            lastCursorPosition = location

            // Only send mouse moved if not dragging (pan gesture handles that)
            if !isDragging {
                let eventModifiers = modifiers(from: gesture)
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseMoved(mouseEvent))
            }
        default:
            break
        }
    }

    // MARK: - Direct Touch Gesture Handlers

    @objc private func handleDirectPinch(_ gesture: UIPinchGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastDirectPinchScale = 1.0
            let event = MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))

        case .changed:
            let magnification = gesture.scale - lastDirectPinchScale
            lastDirectPinchScale = gesture.scale
            let event = MirageMagnifyEvent(magnification: magnification, phase: phase)
            onInputEvent?(.magnify(event))

        case .ended, .cancelled:
            let event = MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))
            lastDirectPinchScale = 1.0

        default:
            break
        }
    }

    @objc private func handleDirectRotation(_ gesture: UIRotationGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastDirectRotationAngle = 0
            let event = MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))

        case .changed:
            // Convert radians to degrees for the delta
            let rotationDelta = (gesture.rotation - lastDirectRotationAngle) * (180.0 / .pi)
            lastDirectRotationAngle = gesture.rotation
            let event = MirageRotateEvent(rotation: rotationDelta, phase: phase)
            onInputEvent?(.rotate(event))

        case .ended, .cancelled:
            let event = MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))
            lastDirectRotationAngle = 0

        default:
            break
        }
    }

    // MARK: - Keyboard Input (External Keyboard)

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock

            if isCapsLockKey {
                capsLockEnabled.toggle()
                sendModifierStateIfNeeded(force: true)
                continue
            }

            updateCapsLockState(from: key.modifierFlags)
            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.insert(key.keyCode)
                sendModifierStateIfNeeded(force: true)
            } else {
                resyncModifierState(from: key.modifierFlags)
                startKeyRepeat(for: press)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyDown(keyEvent))
                }
            }
        }
        // Don't call super - we handle all key events
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock

            if isCapsLockKey {
                continue
            }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                sendModifierStateIfNeeded(force: true)
            } else {
                stopKeyRepeat(for: key.keyCode)
                resyncModifierState(from: key.modifierFlags)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyUp(keyEvent))
                }
            }
        }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock

            if isCapsLockKey {
                continue
            }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                sendModifierStateIfNeeded(force: true)
            } else {
                stopKeyRepeat(for: key.keyCode)
                resyncModifierState(from: key.modifierFlags)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyUp(keyEvent))
                }
            }
        }
    }

    public override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // pressesChanged is for force/altitude changes, not modifier state changes
        // We track modifier state via pressesBegan/pressesEnded instead
    }

    // MARK: - Key Repeat

    /// Start key repeat timer for a held key
    private func startKeyRepeat(for press: UIPress) {
        guard let key = press.key else { return }
        let keyCode = key.keyCode

        // Cancel any existing timer for this key
        stopKeyRepeat(for: keyCode)

        // Store the press reference for generating repeat events
        heldKeyPresses[keyCode] = press

        // Schedule initial delay timer, then switch to repeat interval
        let initialTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInitialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }

            // Start repeating timer
            let repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInterval, repeats: true) { [weak self] _ in
                self?.fireKeyRepeat(for: keyCode)
            }
            self.keyRepeatTimers[keyCode] = repeatTimer

            // Fire first repeat immediately after initial delay
            self.fireKeyRepeat(for: keyCode)
        }
        keyRepeatTimers[keyCode] = initialTimer
    }

    /// Stop key repeat timer for a key
    private func stopKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        keyRepeatTimers[keyCode]?.invalidate()
        keyRepeatTimers.removeValue(forKey: keyCode)
        heldKeyPresses.removeValue(forKey: keyCode)
    }

    /// Fire a key repeat event
    private func fireKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        guard let press = heldKeyPresses[keyCode],
              let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers, isRepeat: true) else { return }
        onInputEvent?(.keyDown(keyEvent))
    }

    /// Stop all active key repeat timers (call when view loses focus)
    private func stopAllKeyRepeats() {
        for (_, timer) in keyRepeatTimers {
            timer.invalidate()
        }
        keyRepeatTimers.removeAll()
        heldKeyPresses.removeAll()
    }

    // MARK: - System Shortcut Interception

    /// Override keyCommands to intercept system shortcuts (CMD+W, CMD+Q, etc.)
    /// and forward them to the host instead of letting iOS handle them
    public override var keyCommands: [UIKeyCommand]? {
        let passthroughShortcuts: [(String, UIKeyModifierFlags)] = [
            ("w", .command),           // Close window
            ("q", .command),           // Quit
            (".", .command),           // Cancel
            ("h", .command),           // Hide
            ("m", .command),           // Minimize
            (",", .command),           // Settings
            ("n", .command),           // New
            ("o", .command),           // Open
            ("s", .command),           // Save
            ("p", .command),           // Print
            ("z", .command),           // Undo
            ("z", [.command, .shift]), // Redo
            ("a", .command),           // Select all
            ("c", .command),           // Copy
            ("x", .command),           // Cut
            ("v", .command),           // Paste
            ("f", .command),           // Find
            ("g", .command),           // Find next
            ("g", [.command, .shift]), // Find previous
            ("t", .command),           // New tab
            ("w", [.command, .shift]), // Close all
        ]

        return passthroughShortcuts.map { (key, modifiers) in
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: key,
                modifierFlags: modifiers
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handlePassthroughShortcut(_ command: UIKeyCommand) {
        // UIKeyCommand intercepts key events BEFORE pressesBegan is called
        // So we must manually send the character key events here
        guard let input = command.input else { return }

        let macKeyCode = Self.characterToMacKeyCode(input)

        // Build modifiers from the command's modifier flags merged with our tracked keyboard state
        // This handles cases like CMD+Shift+Z where Shift is part of the command
        resyncModifierState(from: command.modifierFlags)
        var eventModifiers = keyboardModifiers
        if command.modifierFlags.contains(.shift) { eventModifiers.insert(.shift) }
        if command.modifierFlags.contains(.control) { eventModifiers.insert(.control) }
        if command.modifierFlags.contains(.alternate) { eventModifiers.insert(.option) }
        if command.modifierFlags.contains(.command) { eventModifiers.insert(.command) }

        // Send keyDown for the character key
        let keyDownEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: eventModifiers
        )
        onInputEvent?(.keyDown(keyDownEvent))

        // Send keyUp immediately (shortcuts are instant, not held)
        let keyUpEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: eventModifiers
        )
        onInputEvent?(.keyUp(keyUpEvent))
    }

    /// Convert a character to macOS virtual key code
    /// Used by handlePassthroughShortcut to send key events for UIKeyCommand shortcuts
    private static func characterToMacKeyCode(_ char: String) -> UInt16 {
        switch char.lowercased() {
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case "0": return 0x1D
        case ",": return 0x2B
        case ".": return 0x2F
        case "/": return 0x2C
        case ";": return 0x29
        case "'": return 0x27
        case "[": return 0x21
        case "]": return 0x1E
        case "\\": return 0x2A
        case "-": return 0x1B
        case "=": return 0x18
        case "`": return 0x32
        default: return 0x00  // Default to 'a' for unknown characters
        }
    }

    // MARK: - Cursor Updates

    /// Update cursor appearance based on host cursor state
    /// - Parameters:
    ///   - type: The cursor type from the host
    ///   - isVisible: Whether the cursor is within the host window bounds
    public func updateCursor(type: MirageCursorType, isVisible: Bool) {
        // Only update if something changed
        guard type != currentCursorType || isVisible != cursorIsVisible else { return }

        currentCursorType = type
        cursorIsVisible = isVisible

        // Invalidate the pointer interaction to force it to re-query the style
        // This is required because UIPointerInteraction only calls its delegate
        // when the pointer enters a region, not when the underlying state changes
        pointerInteraction?.invalidate()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InputCapturingView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow hover to work with other gestures
        if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
            return true
        }

        // Allow pinch and rotation to work simultaneously (map-style interaction)
        if (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) ||
           (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }

        return false
    }
}

// MARK: - UIPointerInteractionDelegate

extension InputCapturingView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Return appropriate pointer style based on host cursor state
        guard cursorIsVisible else {
            // Cursor is outside the host window, use default pointer
            return nil
        }
        return currentCursorType.pointerStyle(for: region)
    }
}

// MARK: - Scroll Physics Capturing View

/// Invisible scroll view that captures native trackpad scroll physics.
/// The actual content (Metal view) stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
private class ScrollPhysicsCapturingView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure content fills entire screen
    override var safeAreaInsets: UIEdgeInsets { .zero }

    /// The invisible scroll view for capturing trackpad physics
    let scrollView: UIScrollView

    /// Dummy content view that scrollView scrolls (never visible)
    private let scrollContent: UIView

    /// The actual content we display (stays pinned to bounds)
    let contentView: UIView

    /// Callback for scroll events: (deltaX, deltaY, phase, momentumPhase)
    var onScroll: ((CGFloat, CGFloat, MirageScrollPhase, MirageScrollPhase) -> Void)?

    /// Callback for pinch events: (magnification, phase)
    var onPinch: ((CGFloat, MirageScrollPhase) -> Void)?

    /// Callback for rotation events: (rotationDegrees, phase)
    var onRotation: ((CGFloat, MirageScrollPhase) -> Void)?

    /// Size of scrollable area - large enough for extended scrolling before recenter
    private let scrollableSize: CGFloat = 100_000

    /// Whether we're currently tracking a scroll gesture (finger on trackpad)
    private var isTracking = false

    /// Last content offset for calculating deltas
    private var lastContentOffset: CGPoint = .zero

    /// Flag to suppress scroll events during recenter operation
    private var isRecentering = false

    /// Gesture recognizers for trackpad pinch/rotation
    private var pinchGesture: UIPinchGestureRecognizer!
    private var rotationGesture: UIRotationGestureRecognizer!

    /// State tracking for incremental gesture deltas
    private var lastPinchScale: CGFloat = 1.0
    private var lastRotationAngle: CGFloat = 0.0

    override init(frame: CGRect) {
        scrollView = UIScrollView(frame: frame)
        scrollContent = UIView()
        contentView = UIView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        scrollView = UIScrollView()
        scrollContent = UIView()
        contentView = UIView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Ensure this view doesn't respect safe area insets
        insetsLayoutMarginsFromSafeArea = false

        // Configure scroll view for native physics
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Make scroll view invisible but still receive events
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false

        // CRITICAL: Only accept trackpad/mouse wheel scrolling, not direct touch
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]

        // Add scroll content (large enough to allow scrolling in all directions)
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContent)

        // Content view holds the actual Metal view (stays pinned to our bounds)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // Add scroll view as overlay on top (receives trackpad events, passes through other input)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Scroll view fills our bounds
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Content view also fills bounds (stays stationary)
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Set scroll content size explicitly (UIScrollView needs this)
        scrollContent.frame = CGRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize)
        scrollView.contentSize = CGSize(width: scrollableSize, height: scrollableSize)

        // Pinch gesture for trackpad zoom (indirectPointer only)
        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        // Rotation gesture for trackpad (indirectPointer only)
        rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Center content offset on initial layout
        recenterIfNeeded(force: lastContentOffset == .zero)
    }

    /// Center the scroll view's content offset
    /// - Parameter force: If true, recenter even if currently scrolling
    private func recenterIfNeeded(force: Bool = false) {
        let centerOffset = CGPoint(
            x: (scrollableSize - bounds.width) / 2,
            y: (scrollableSize - bounds.height) / 2
        )

        // Only recenter if not currently scrolling (unless forced)
        if force || (!isTracking && !scrollView.isDecelerating) {
            // Suppress scroll events during recenter operation
            isRecentering = true
            scrollView.contentOffset = centerOffset
            lastContentOffset = centerOffset
            isRecentering = false
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isTracking = true
        lastContentOffset = scrollView.contentOffset

        // Send scroll began phase
        onScroll?(0, 0, .began, .none)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Skip sending events during recenter operation
        guard !isRecentering else { return }

        let currentOffset = scrollView.contentOffset
        // Calculate deltas (inverted: content moving left = scrolling right)
        let deltaX = lastContentOffset.x - currentOffset.x
        let deltaY = lastContentOffset.y - currentOffset.y
        lastContentOffset = currentOffset

        // Determine phases based on tracking/decelerating state
        let phase: MirageScrollPhase = isTracking ? .changed : .none
        let momentumPhase: MirageScrollPhase = scrollView.isDecelerating ? .changed : .none

        // Send scroll delta if there's actual movement
        if deltaX != 0 || deltaY != 0 {
            onScroll?(deltaX, deltaY, phase, momentumPhase)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isTracking = false

        if !decelerate {
            // No momentum, end immediately and recenter
            onScroll?(0, 0, .ended, .none)
            recenterIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Momentum ended, send final event and recenter
        onScroll?(0, 0, .none, .ended)
        recenterIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // Animation ended (e.g., from programmatic scroll)
        recenterIfNeeded()
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch + rotation simultaneously (map-style interaction)
        // Allow gestures to work alongside scroll view's pan
        true
    }

    // MARK: - Trackpad Gesture Handlers

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastPinchScale = 1.0
            onPinch?(0, phase)

        case .changed:
            let magnification = gesture.scale - lastPinchScale
            lastPinchScale = gesture.scale
            onPinch?(magnification, phase)

        case .ended, .cancelled:
            onPinch?(0, phase)
            lastPinchScale = 1.0

        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastRotationAngle = 0
            onRotation?(0, phase)

        case .changed:
            // Convert radians to degrees for the delta
            let rotationDelta = (gesture.rotation - lastRotationAngle) * (180.0 / .pi)
            lastRotationAngle = gesture.rotation
            onRotation?(rotationDelta, phase)

        case .ended, .cancelled:
            onRotation?(0, phase)
            lastRotationAngle = 0

        default:
            break
        }
    }
}

#endif

// MARK: - SwiftUI Representables

#if os(macOS)
public struct MirageStreamViewRepresentable: NSViewRepresentable {
    public let streamID: StreamID
    @Binding public var latestFrame: CVPixelBuffer?

    /// The content rectangle within the frame (for SCK black bar cropping)
    public var contentRect: CGRect

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    public init(
        streamID: StreamID,
        latestFrame: Binding<CVPixelBuffer?>,
        contentRect: CGRect = .zero,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableSizeChanged: ((CGSize) -> Void)? = nil
    ) {
        self.streamID = streamID
        self._latestFrame = latestFrame
        self.contentRect = contentRect
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChanged = onDrawableSizeChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onDrawableSizeChanged: onDrawableSizeChanged, onInputEvent: onInputEvent)
    }

    public func makeNSView(context: Context) -> NSView {
        let wrapper = ScrollPhysicsCapturingNSView(frame: .zero)

        // Create Metal view and add to wrapper's content view
        let metalView = MirageMetalView(frame: .zero, device: nil)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.contentView.addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: wrapper.contentView.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: wrapper.contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: wrapper.contentView.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: wrapper.contentView.bottomAnchor)
        ])

        // Store Metal view reference in coordinator
        context.coordinator.metalView = metalView
        metalView.onDrawableSizeChanged = context.coordinator.handleDrawableSizeChanged
        metalView.streamID = streamID

        // Configure scroll callback for native trackpad physics
        wrapper.onScroll = { [weak coordinator = context.coordinator] deltaX, deltaY, location, phase, momentumPhase, isPrecise in
            let event = MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: location,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: [],  // Modifiers tracked separately via flagsChanged
                isPrecise: isPrecise
            )
            coordinator?.onInputEvent?(.scrollWheel(event))
        }

        // Configure mouse/keyboard event callback
        wrapper.onMouseEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.onInputEvent?(event)
        }

        return wrapper
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDrawableSizeChanged = onDrawableSizeChanged
        context.coordinator.onInputEvent = onInputEvent

        if let metalView = context.coordinator.metalView {
            metalView.streamID = streamID
        }

        if let frame = latestFrame, let metalView = context.coordinator.metalView {
            metalView.updateFrame(frame, contentRect: contentRect)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    public class Coordinator {
        var onDrawableSizeChanged: ((CGSize) -> Void)?
        var onInputEvent: ((MirageInputEvent) -> Void)?
        weak var metalView: MirageMetalView?

        init(onDrawableSizeChanged: ((CGSize) -> Void)?, onInputEvent: ((MirageInputEvent) -> Void)?) {
            self.onDrawableSizeChanged = onDrawableSizeChanged
            self.onInputEvent = onInputEvent
        }

        func handleDrawableSizeChanged(_ size: CGSize) {
            onDrawableSizeChanged?(size)
        }
    }
}
#else

// MARK: - SwiftUI Representable (iOS)

public struct MirageStreamViewRepresentable: UIViewRepresentable {
    public let streamID: StreamID
    @Binding public var latestFrame: CVPixelBuffer?

    /// The content rectangle within the frame (for SCK black bar cropping)
    public var contentRect: CGRect

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Frame provider for pull-based frame updates during gesture tracking
    /// When set, the Metal view will pull frames directly on each draw cycle,
    /// bypassing SwiftUI's observation which gets blocked during gestures
    public var frameProvider: (() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?)?

    /// Current cursor type from host
    public var cursorType: MirageCursorType

    /// Whether cursor is visible (within host window bounds)
    public var cursorVisible: Bool

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool

    public init(
        streamID: StreamID,
        latestFrame: Binding<CVPixelBuffer?>,
        contentRect: CGRect = .zero,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableSizeChanged: ((CGSize) -> Void)? = nil,
        frameProvider: (() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?)? = nil,
        cursorType: MirageCursorType = .arrow,
        cursorVisible: Bool = true,
        onBecomeActive: (() -> Void)? = nil,
        dockSnapEnabled: Bool = false
    ) {
        self.streamID = streamID
        self._latestFrame = latestFrame
        self.contentRect = contentRect
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChanged = onDrawableSizeChanged
        self.frameProvider = frameProvider
        self.cursorType = cursorType
        self.cursorVisible = cursorVisible
        self.onBecomeActive = onBecomeActive
        self.dockSnapEnabled = dockSnapEnabled
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onInputEvent: onInputEvent, onDrawableSizeChanged: onDrawableSizeChanged, onBecomeActive: onBecomeActive)
    }

    public func makeUIView(context: Context) -> InputCapturingView {
        let view = InputCapturingView(frame: .zero)
        view.onInputEvent = context.coordinator.handleInputEvent
        view.onDrawableSizeChanged = context.coordinator.handleDrawableSizeChanged
        view.onBecomeActive = context.coordinator.handleBecomeActive
        view.dockSnapEnabled = dockSnapEnabled
        // Set stream ID for direct frame cache access (bypasses all actor machinery)
        view.streamID = streamID
        view.frameProvider = frameProvider
        return view
    }

    public func updateUIView(_ uiView: InputCapturingView, context: Context) {
        // Update coordinator's callbacks in case they changed
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onDrawableSizeChanged = onDrawableSizeChanged
        context.coordinator.onBecomeActive = onBecomeActive

        // Update stream ID for direct frame cache access
        // CRITICAL: This allows Metal view to read frames without any Swift actor overhead
        uiView.streamID = streamID

        // Legacy frame provider (not needed if using direct cache access)
        uiView.frameProvider = frameProvider

        uiView.dockSnapEnabled = dockSnapEnabled

        // Also push the frame via SwiftUI observation (works when not dragging)
        if let frame = latestFrame {
            uiView.metalView.updateFrame(frame, contentRect: contentRect)
        }

        // Update cursor appearance
        uiView.updateCursor(type: cursorType, isVisible: cursorVisible)
    }

    public class Coordinator {
        var onInputEvent: ((MirageInputEvent) -> Void)?
        var onDrawableSizeChanged: ((CGSize) -> Void)?
        var onBecomeActive: (() -> Void)?

        init(onInputEvent: ((MirageInputEvent) -> Void)?, onDrawableSizeChanged: ((CGSize) -> Void)?, onBecomeActive: (() -> Void)?) {
            self.onInputEvent = onInputEvent
            self.onDrawableSizeChanged = onDrawableSizeChanged
            self.onBecomeActive = onBecomeActive
        }

        func handleInputEvent(_ event: MirageInputEvent) {
            onInputEvent?(event)
        }

        func handleDrawableSizeChanged(_ size: CGSize) {
            onDrawableSizeChanged?(size)
        }

        func handleBecomeActive() {
            onBecomeActive?()
        }
    }
}
#endif
