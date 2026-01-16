//
//  MirageHostInputController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/16/26.
//

#if os(macOS)
import Foundation
import AppKit
import ApplicationServices

// MARK: - Private Accessibility API

/// Private but stable API to get CGWindowID from AXUIElement.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Manages input event processing, batching, scroll smoothing, and injection for remote input.
///
/// Handles mouse batching, scroll smoothing (120Hz), and CGEvent injection on macOS hosts.
public final class MirageHostInputController: @unchecked Sendable {
    // MARK: - Dependencies

    /// Reference to window controller for AX lookups and resizing.
    public weak var windowController: MirageHostWindowController?

    /// Reference to host service for frame updates and virtual display queries.
    public weak var hostService: MirageHostService?

    /// Optional permission manager for accessibility checks.
    public var permissionManager: MirageAccessibilityPermissionManager?

    // MARK: - Queue

    /// Serial queue for blocking Accessibility API operations.
    private let accessibilityQueue = DispatchQueue(label: "com.mirage.accessibility", qos: .userInteractive)

    // MARK: - Mouse Batching State (accessed from accessibilityQueue only)

    /// Pending mouse move event waiting to be flushed.
    private var pendingMouseMove: (type: CGEventType, event: MirageMouseEvent, frame: CGRect, windowID: WindowID, app: MirageApplication?)?

    /// Timer for flushing batched mouse moves.
    private var mouseBatchTimer: DispatchSourceTimer?

    /// Batch window in milliseconds.
    private let mouseBatchIntervalMs: UInt64 = 2

    // MARK: - Modifier State Tracking (accessed from accessibilityQueue only)

    /// Track the last time modifiers were updated.
    private var lastModifierEventTime: TimeInterval = 0

    /// Track the last sent modifier state (for detecting stuck modifiers).
    private var lastSentModifiers: MirageModifierFlags = []

    /// Track which modifier key codes are currently held (for injecting keyUp on release).
    private var heldModifierKeyCodes: Set<CGKeyCode> = []

    /// Timer to periodically check for stuck modifiers.
    private var modifierResetTimer: DispatchSourceTimer?

    /// Maximum time modifiers can be held before being considered stuck.
    private let modifierStuckTimeoutSeconds: TimeInterval = 2.0

    /// Mapping from modifier flags to their corresponding virtual key codes.
    private static let modifierKeyCodes: [(flag: MirageModifierFlags, keyCode: CGKeyCode)] = [
        (.shift, 0x38),
        (.control, 0x3B),
        (.option, 0x3A),
        (.command, 0x37),
        (.capsLock, 0x39),
    ]

    /// Mapping from CGEventFlags to MirageModifierFlags for system state comparison.
    private static let cgFlagToMirageFlag: [(cgFlag: CGEventFlags, mirageFlag: MirageModifierFlags)] = [
        (.maskShift, .shift),
        (.maskControl, .control),
        (.maskAlternate, .option),
        (.maskCommand, .command),
        (.maskAlphaShift, .capsLock),
    ]

    // MARK: - Scroll Rate Smoothing State (accessed from accessibilityQueue only)

    /// Smoothed scroll rate in pixels per second.
    private var scrollRateX: CGFloat = 0
    private var scrollRateY: CGFloat = 0

    /// Timestamp of last scroll input.
    private var lastScrollInputTime: TimeInterval = 0

    /// Fractional remainders to preserve precision.
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    /// Context for scroll injection.
    private var scrollContext: (frame: CGRect, app: MirageApplication?, location: CGPoint?, modifiers: MirageModifierFlags, isPrecise: Bool)?

    /// Timer for smooth scroll output (120Hz).
    private var scrollOutputTimer: DispatchSourceTimer?

    /// Scroll smoothing constants.
    private let scrollRateAlpha: CGFloat = 0.5
    private let scrollRateDecay: CGFloat = 0.85
    private let scrollDecayDelay: TimeInterval = 0.03
    private let scrollRateThreshold: CGFloat = 10.0
    private let scrollOutputIntervalMs: UInt64 = 8

    // MARK: - Gesture Translation State (accessed from accessibilityQueue only)

    /// Accumulated magnification for command+scroll translation.
    private var magnifyAccumulator: CGFloat = 0

    /// Threshold before triggering a zoom scroll event.
    private let magnifyScrollThreshold: CGFloat = 0.02

    /// Accumulated rotation for option+scroll translation.
    private var rotationAccumulator: CGFloat = 0

    /// Threshold before triggering a rotation scroll event.
    private let rotationScrollThreshold: CGFloat = 2.0

    /// Creates an input controller for host-side injection.
    /// - Parameters:
    ///   - windowController: Window controller for AX lookups and resizing.
    ///   - hostService: Host service for capture and stream updates.
    ///   - permissionManager: Optional accessibility permission manager.
    public init(
        windowController: MirageHostWindowController? = nil,
        hostService: MirageHostService? = nil,
        permissionManager: MirageAccessibilityPermissionManager? = nil
    ) {
        self.windowController = windowController
        self.hostService = hostService
        self.permissionManager = permissionManager
    }

    // MARK: - Main Entry Point

    /// Handle input events from the host's input queue.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - window: The target window for the input event.
    public func handleInputEvent(_ event: MirageInputEvent, window: MirageWindow) {
        if window.id == 0 {
            handleDesktopInputEvent(event, bounds: window.frame)
            return
        }

        switch event {
        case .windowResize(let resizeEvent):
            Task { @MainActor [weak self] in
                self?.handleWindowResize(window, resizeEvent: resizeEvent)
            }
        case .relativeResize(let event):
            Task { @MainActor [weak self] in
                self?.handleRelativeResize(window, event: event)
            }
        case .pixelResize(let event):
            Task { @MainActor [weak self] in
                self?.handlePixelResize(window, event: event)
            }
        default:
            handleInput(event, window: window)
        }
    }

    // MARK: - Desktop Input Handling

    /// Handle input events for desktop streaming.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - bounds: Bounds of the virtual display or mirrored desktop.
    public func handleDesktopInputEvent(_ event: MirageInputEvent, bounds: CGRect) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case .mouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.leftMouseDown, e, at: point)
            case .mouseUp(let e):
                self.flushPendingMouseMove()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.leftMouseUp, e, at: point)
            case .rightMouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.rightMouseDown, e, at: point)
            case .rightMouseUp(let e):
                self.flushPendingMouseMove()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.rightMouseUp, e, at: point)
            case .otherMouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.otherMouseDown, e, at: point)
            case .otherMouseUp(let e):
                self.flushPendingMouseMove()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.otherMouseUp, e, at: point)

            case .mouseMoved(let e):
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.mouseMoved, e, at: point)
            case .mouseDragged(let e):
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.leftMouseDragged, e, at: point)
            case .rightMouseDragged(let e):
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.rightMouseDragged, e, at: point)
            case .otherMouseDragged(let e):
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.otherMouseDragged, e, at: point)

            case .scrollWheel(let e):
                self.injectDesktopScrollEvent(e, bounds: bounds)

            case .keyDown(let e):
                self.flushPendingMouseMove()
                self.injectKeyEvent(isKeyDown: true, e, app: nil)
            case .keyUp(let e):
                self.flushPendingMouseMove()
                self.injectKeyEvent(isKeyDown: false, e, app: nil)
            case .flagsChanged(let modifiers):
                self.injectFlagsChanged(modifiers, app: nil)

            case .magnify(let e):
                self.handleMagnifyGesture(e, windowFrame: bounds)

            case .rotate(let e):
                self.handleRotateGesture(e, windowFrame: bounds)

            case .windowResize, .relativeResize, .pixelResize:
                break

            case .windowFocus:
                break
            }
        }
    }

    /// Convert normalized coordinates (0-1) to screen coordinates using display bounds.
    private func screenPoint(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.origin.x + normalized.x * bounds.width,
            y: bounds.origin.y + normalized.y * bounds.height
        )
    }

    /// Inject mouse event at a specific screen point (for desktop streaming).
    private func injectDesktopMouseEvent(_ type: CGEventType, _ event: MirageMouseEvent, at point: CGPoint) {
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: event.button.cgMouseButton
        ) else { return }

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        default:
            break
        }

        postEvent(cgEvent)
    }

    /// Inject scroll event for desktop streaming.
    private func injectDesktopScrollEvent(_ event: MirageScrollEvent, bounds: CGRect) {
        let scrollPoint: CGPoint
        if let normalizedLocation = event.location {
            scrollPoint = screenPoint(normalizedLocation, in: bounds)
        } else {
            scrollPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }

    // MARK: - Resize Handling

    @MainActor
    private func handleWindowResize(_ window: MirageWindow, resizeEvent: MirageResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window) else { return }

        let settable = windowController.isWindowSizeSettable(axWindow)
        let minSize = windowController.getMinimumSize(for: window.id)

        var newSize = resizeEvent.newSize
        if let minSize {
            newSize = CGSize(
                width: max(newSize.width, minSize.width),
                height: max(newSize.height, minSize.height)
            )
        }

        if let maxSize = windowController.maxWindowSize(for: window) {
            newSize.width = min(newSize.width, maxSize.width)
            newSize.height = min(newSize.height, maxSize.height)
        }

        if settable == false {
            if let actualFrame = windowController.axWindowFrame(axWindow) ?? windowController.currentWindowFrame(for: window.id) {
                windowController.updateMinimumSizeCache(for: window.id, size: actualFrame.size)
                notifyWindowResized(window, with: actualFrame, clientPixelSize: resizeEvent.pixelSize)
            }
            return
        }

        var mutableSize = newSize
        guard let newSizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }

        let setResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, newSizeValue)

        if setResult == .success {
            let updatedFrame = windowController.axWindowFrame(axWindow)
                ?? windowController.currentWindowFrame(for: window.id)
                ?? CGRect(origin: window.frame.origin, size: newSize)

            notifyWindowResized(window, with: updatedFrame, clientPixelSize: resizeEvent.pixelSize)
        }
    }

    @MainActor
    private func handleRelativeResize(_ window: MirageWindow, event: MirageRelativeResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window),
              let visibleFrame = windowController.maxWindowSizeRect(for: window) else { return }

        let clientAspectRatio = event.aspectRatio
        let isOnVirtualDisplay = hostService?.isStreamUsingVirtualDisplay(windowID: window.id) ?? false
        let hostScale: CGFloat = isOnVirtualDisplay ? 2.0 : (NSScreen.main?.backingScaleFactor ?? 2.0)

        let initialTargetSize: CGSize
        if event.pixelWidth > 0 && event.pixelHeight > 0 {
            let rawSize = CGSize(
                width: CGFloat(event.pixelWidth) / hostScale,
                height: CGFloat(event.pixelHeight) / hostScale
            )
            initialTargetSize = windowController.constrainSizeToFrame(rawSize, frame: visibleFrame)
        } else {
            let minSize = windowController.getMinimumSize(for: window.id) ?? CGSize(width: 400, height: 300)
            initialTargetSize = windowController.calculateHostWindowSize(
                aspectRatio: clientAspectRatio,
                relativeScale: event.relativeScale,
                visibleFrame: visibleFrame,
                minSize: minSize
            )
        }

        Task {
            var currentTargetSize = initialTargetSize
            var finalSize: CGSize?

            for _ in 0..<15 {
                var mutableSize = currentTargetSize
                guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { break }
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

                try? await Task.sleep(for: .milliseconds(30))

                let actualSize = (windowController.axWindowFrame(axWindow) ?? windowController.currentWindowFrame(for: window.id))?.size ?? currentTargetSize

                let actualAspectRatio = actualSize.width / actualSize.height
                let aspectDiff = abs(actualAspectRatio - clientAspectRatio)

                if aspectDiff < 0.02 {
                    finalSize = actualSize
                    break
                }

                let widthConstrained = CGSize(width: actualSize.width, height: actualSize.width / clientAspectRatio)
                let heightConstrained = CGSize(width: actualSize.height * clientAspectRatio, height: actualSize.height)

                let newTarget = widthConstrained.height <= actualSize.height ? widthConstrained : heightConstrained

                if newTarget.width < 200 || newTarget.height < 200 {
                    finalSize = actualSize
                    break
                }

                let sizeDiff = abs(newTarget.width - currentTargetSize.width) + abs(newTarget.height - currentTargetSize.height)
                if sizeDiff < 2 {
                    finalSize = actualSize
                    break
                }

                currentTargetSize = newTarget
            }

            guard let size = finalSize else { return }

            let captureWidth = Int(size.width * hostScale)
            let captureHeight = Int(size.height * hostScale)

            if captureWidth > 0 && captureHeight > 0 {
                windowController.scheduleResizeUpdate(windowID: window.id, width: captureWidth, height: captureHeight)
            }

            windowController.centerWindowOnScreen(axWindow, newSize: size, windowID: window.id)
        }
    }

    @MainActor
    private func handlePixelResize(_ window: MirageWindow, event: MiragePixelResizeEvent) {
        guard let windowController else { return }
        guard let axWindow = windowController.getOrCacheAXWindow(for: window) else { return }

        let hostScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetSize = CGSize(
            width: CGFloat(event.pixelWidth) / hostScale,
            height: CGFloat(event.pixelHeight) / hostScale
        )

        var mutableSize = targetSize
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return }

        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

        if result == .success {
            windowController.centerWindowOnScreen(axWindow, newSize: targetSize, windowID: window.id)

            Task { [weak self] in
                await self?.hostService?.updateCaptureResolution(
                    for: window.id,
                    width: event.pixelWidth,
                    height: event.pixelHeight
                )
            }
        }
    }

    @MainActor
    private func notifyWindowResized(_ window: MirageWindow, with updatedFrame: CGRect, clientPixelSize: CGSize?) {
        let updatedWindow = MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: updatedFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        Task { [weak self] in
            await self?.hostService?.notifyWindowResized(updatedWindow, preferredPixelSize: clientPixelSize)
        }
    }

    // MARK: - Input Handling

    private func handleInput(_ event: MirageInputEvent, window: MirageWindow) {
        let windowFrame = window.frame

        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case .mouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.leftMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .mouseUp(let e):
                self.flushPendingMouseMove()
                self.injectMouseEvent(.leftMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case .rightMouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.rightMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .rightMouseUp(let e):
                self.flushPendingMouseMove()
                self.injectMouseEvent(.rightMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case .otherMouseDown(let e):
                self.flushPendingMouseMove()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.otherMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .otherMouseUp(let e):
                self.flushPendingMouseMove()
                self.injectMouseEvent(.otherMouseUp, e, windowFrame, windowID: window.id, app: window.application)

            case .mouseMoved(let e):
                self.batchMouseMove(.mouseMoved, e, windowFrame, windowID: window.id, app: window.application)
            case .mouseDragged(let e):
                self.batchMouseMove(.leftMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case .rightMouseDragged(let e):
                self.batchMouseMove(.rightMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case .otherMouseDragged(let e):
                self.batchMouseMove(.otherMouseDragged, e, windowFrame, windowID: window.id, app: window.application)

            case .scrollWheel(let e):
                self.batchScroll(e, windowFrame, app: window.application)

            case .keyDown(let e):
                self.flushPendingMouseMove()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectKeyEvent(isKeyDown: true, e, app: window.application)
            case .keyUp(let e):
                self.flushPendingMouseMove()
                self.injectKeyEvent(isKeyDown: false, e, app: window.application)
            case .flagsChanged(let modifiers):
                self.injectFlagsChanged(modifiers, app: window.application)

            case .magnify(let e):
                self.handleMagnifyGesture(e, windowFrame: windowFrame)

            case .rotate(let e):
                self.handleRotateGesture(e, windowFrame: windowFrame)

            case .windowResize, .relativeResize, .pixelResize:
                break

            case .windowFocus:
                self.activateWindow(windowID: window.id, app: window.application)
            }
        }
    }

    // MARK: - Mouse Batching (runs on accessibilityQueue)

    private func batchMouseMove(_ type: CGEventType, _ event: MirageMouseEvent, _ windowFrame: CGRect, windowID: WindowID, app: MirageApplication?) {
        pendingMouseMove = (type, event, windowFrame, windowID, app)

        mouseBatchTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(mouseBatchIntervalMs)))
        timer.setEventHandler { [weak self] in
            self?.flushPendingMouseMove()
        }
        timer.resume()
        mouseBatchTimer = timer
    }

    private func flushPendingMouseMove() {
        mouseBatchTimer?.cancel()
        mouseBatchTimer = nil

        guard let pending = pendingMouseMove else { return }
        pendingMouseMove = nil

        injectMouseEvent(pending.type, pending.event, pending.frame, windowID: pending.windowID, app: pending.app)
    }

    // MARK: - Scroll Rate Smoothing (runs on accessibilityQueue)

    private func batchScroll(_ event: MirageScrollEvent, _ windowFrame: CGRect, app: MirageApplication?) {
        let now = CACurrentMediaTime()

        if event.phase == .began || event.phase == .ended || event.phase == .cancelled ||
           event.momentumPhase == .began || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            if event.phase == .began || event.momentumPhase == .began {
                scrollRateX = 0
                scrollRateY = 0
                scrollRemainderX = 0
                scrollRemainderY = 0
            }
            injectScrollEvent(event, windowFrame, app: app)
            lastScrollInputTime = now
            return
        }

        let dt = now - lastScrollInputTime
        lastScrollInputTime = now

        let effectiveDt = max(0.004, min(dt, 0.1))
        let instantRateX = event.deltaX / CGFloat(effectiveDt)
        let instantRateY = event.deltaY / CGFloat(effectiveDt)

        if abs(scrollRateX) < 1 && abs(scrollRateY) < 1 {
            scrollRateX = instantRateX
            scrollRateY = instantRateY
        } else {
            scrollRateX = scrollRateAlpha * instantRateX + (1 - scrollRateAlpha) * scrollRateX
            scrollRateY = scrollRateAlpha * instantRateY + (1 - scrollRateAlpha) * scrollRateY
        }

        scrollContext = (windowFrame, app, event.location, event.modifiers, event.isPrecise)

        if scrollOutputTimer == nil {
            startScrollOutputTimer()
        }
    }

    private func startScrollOutputTimer() {
        scrollOutputTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(scrollOutputIntervalMs)),
            repeating: .milliseconds(Int(scrollOutputIntervalMs)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.scrollOutputTick()
        }
        timer.resume()
        scrollOutputTimer = timer
    }

    private func scrollOutputTick() {
        guard let context = scrollContext else {
            stopScrollOutputTimer()
            return
        }

        let now = CACurrentMediaTime()
        let timeSinceInput = now - lastScrollInputTime

        if timeSinceInput > scrollDecayDelay {
            scrollRateX *= scrollRateDecay
            scrollRateY *= scrollRateDecay
        }

        let tickDuration: CGFloat = CGFloat(scrollOutputIntervalMs) / 1000.0
        let deltaX = scrollRateX * tickDuration
        let deltaY = scrollRateY * tickDuration

        scrollRemainderX += deltaX
        scrollRemainderY += deltaY

        let injectX = trunc(scrollRemainderX)
        let injectY = trunc(scrollRemainderY)

        if abs(injectX) >= 1 || abs(injectY) >= 1 {
            scrollRemainderX -= injectX
            scrollRemainderY -= injectY
            injectScrollPixels(Int32(injectX), Int32(injectY), context: context)
        }

        let rateMagnitude = sqrt(scrollRateX * scrollRateX + scrollRateY * scrollRateY)
        if rateMagnitude < scrollRateThreshold {
            let finalX = trunc(scrollRemainderX)
            let finalY = trunc(scrollRemainderY)
            if abs(finalX) >= 1 || abs(finalY) >= 1 {
                injectScrollPixels(Int32(finalX), Int32(finalY), context: context)
            }

            scrollRateX = 0
            scrollRateY = 0
            scrollRemainderX = 0
            scrollRemainderY = 0
            scrollContext = nil
            stopScrollOutputTimer()
        }
    }

    private func stopScrollOutputTimer() {
        scrollOutputTimer?.cancel()
        scrollOutputTimer = nil
    }

    private func injectScrollPixels(
        _ pixelsX: Int32,
        _ pixelsY: Int32,
        context: (frame: CGRect, app: MirageApplication?, location: CGPoint?, modifiers: MirageModifierFlags, isPrecise: Bool)
    ) {
        let scrollPoint: CGPoint
        if let normalizedLocation = context.location {
            scrollPoint = CGPoint(
                x: context.frame.origin.x + normalizedLocation.x * context.frame.width,
                y: context.frame.origin.y + normalizedLocation.y * context.frame.height
            )
        } else {
            scrollPoint = CGPoint(x: context.frame.midX, y: context.frame.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: context.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: pixelsY,
            wheel2: pixelsX,
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }

    // MARK: - Mouse Event Injection (runs on accessibilityQueue)

    private func injectMouseEvent(_ type: CGEventType, _ event: MirageMouseEvent, _ windowFrame: CGRect, windowID: WindowID, app: MirageApplication?) {
        let actualFrame = currentWindowFrame(for: windowID)
        let useActualFrame = actualFrame.map { framesAreClose($0, windowFrame) } ?? false
        let resolvedFrame = useActualFrame ? (actualFrame ?? windowFrame) : windowFrame

        let screenPoint = CGPoint(
            x: resolvedFrame.origin.x + event.location.x * resolvedFrame.width,
            y: resolvedFrame.origin.y + event.location.y * resolvedFrame.height
        )

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            CGWarpMouseCursorPosition(screenPoint)
        default:
            break
        }

        let pixelX = event.location.x * resolvedFrame.width
        let pixelY = event.location.y * resolvedFrame.height
        if pixelX < 80 && pixelY < 30 && (type == .leftMouseDown || type == .leftMouseUp) {
            MirageLogger.host("Blocked click in traffic light area")
            return
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: screenPoint,
            mouseButton: event.button.cgMouseButton
        ) else { return }

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        default:
            break
        }

        postEvent(cgEvent)
    }

    // MARK: - Scroll Event Injection (runs on accessibilityQueue)

    private func injectScrollEvent(_ event: MirageScrollEvent, _ windowFrame: CGRect, app: MirageApplication?) {
        let scrollPoint: CGPoint
        if let normalizedLocation = event.location {
            scrollPoint = CGPoint(
                x: windowFrame.origin.x + normalizedLocation.x * windowFrame.width,
                y: windowFrame.origin.y + normalizedLocation.y * windowFrame.height
            )
        } else {
            scrollPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }

    // MARK: - Key Event Injection (runs on accessibilityQueue)

    private func injectKeyEvent(isKeyDown: Bool, _ event: MirageKeyEvent, app: MirageApplication?) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isKeyDown
        ) else { return }

        cgEvent.flags = event.modifiers.cgEventFlags

        if event.isRepeat {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }

        postEvent(cgEvent)

        if !event.modifiers.isEmpty {
            lastModifierEventTime = CACurrentMediaTime()
        }
    }

    private func injectFlagsChanged(_ modifiers: MirageModifierFlags, app: MirageApplication?) {
        var newlyPressed: [CGKeyCode] = []
        var newlyReleased: [CGKeyCode] = []

        for (flag, keyCode) in Self.modifierKeyCodes {
            let wasHeld = lastSentModifiers.contains(flag)
            let isHeld = modifiers.contains(flag)

            if isHeld && !wasHeld {
                newlyPressed.append(keyCode)
            } else if !isHeld && wasHeld {
                newlyReleased.append(keyCode)
            }
        }

        var cumulativeFlags = lastSentModifiers
        for (flag, keyCode) in Self.modifierKeyCodes where newlyPressed.contains(keyCode) {
            cumulativeFlags.insert(flag)
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                keyEvent.flags = cumulativeFlags.cgEventFlags
                postEvent(keyEvent)
                heldModifierKeyCodes.insert(keyCode)
            }
        }

        var releaseFlags = cumulativeFlags
        for (flag, keyCode) in Self.modifierKeyCodes where newlyReleased.contains(keyCode) {
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyEvent.flags = releaseFlags.cgEventFlags
                postEvent(keyEvent)
                heldModifierKeyCodes.remove(keyCode)
            }
            releaseFlags.remove(flag)
        }

        if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            cgEvent.type = .flagsChanged
            cgEvent.flags = modifiers.cgEventFlags
            postEvent(cgEvent)
        }

        lastSentModifiers = modifiers
        lastModifierEventTime = CACurrentMediaTime()

        if !modifiers.isEmpty {
            startModifierResetTimerIfNeeded()
        } else {
            stopModifierResetTimer()
        }
    }

    // MARK: - Stuck Modifier Detection

    private func startModifierResetTimerIfNeeded() {
        guard modifierResetTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + modifierStuckTimeoutSeconds,
            repeating: modifierStuckTimeoutSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.checkForStuckModifiers()
        }
        timer.resume()
        modifierResetTimer = timer
    }

    private func stopModifierResetTimer() {
        modifierResetTimer?.cancel()
        modifierResetTimer = nil
    }

    private func checkForStuckModifiers() {
        let now = CACurrentMediaTime()
        let timeSinceLastModifierEvent = now - lastModifierEventTime

        if !lastSentModifiers.isEmpty && timeSinceLastModifierEvent > modifierStuckTimeoutSeconds {
            let roundedDuration = (timeSinceLastModifierEvent * 10).rounded() / 10
            MirageLogger.host("Clearing stuck modifiers after \(roundedDuration)s of inactivity")
            injectFlagsChanged([], app: nil)
        }
    }

    /// Query the actual system modifier state and clear any modifiers that shouldn't be there.
    private func clearUnexpectedSystemModifiers() {
        let systemFlags = CGEventSource.flagsState(.hidSystemState)

        var actualModifiers: MirageModifierFlags = []
        for (cgFlag, mirageFlag) in Self.cgFlagToMirageFlag {
            if systemFlags.contains(cgFlag) {
                actualModifiers.insert(mirageFlag)
            }
        }

        if !actualModifiers.isEmpty && lastSentModifiers.isEmpty {
            MirageLogger.host("Clearing unexpected system modifiers: \(actualModifiers)")

            for (flag, keyCode) in Self.modifierKeyCodes where actualModifiers.contains(flag) {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = actualModifiers.cgEventFlags
                    postEvent(keyEvent)
                }
                actualModifiers.remove(flag)
            }

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                postEvent(cgEvent)
            }
        }
    }

    /// Clear all modifier state.
    /// - Note: Call when starting a new stream or reconnecting to avoid stuck modifiers.
    public func clearAllModifiers() {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            guard !self.lastSentModifiers.isEmpty || !self.heldModifierKeyCodes.isEmpty else { return }

            MirageLogger.host("Clearing all modifiers on session change")

            for keyCode in self.heldModifierKeyCodes {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = []
                    self.postEvent(keyEvent)
                }
            }
            self.heldModifierKeyCodes.removeAll()

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                self.postEvent(cgEvent)
            }

            self.lastSentModifiers = []
            self.stopModifierResetTimer()
        }
    }

    // MARK: - Gesture Translation (runs on accessibilityQueue)

    private func handleMagnifyGesture(_ event: MirageMagnifyEvent, windowFrame: CGRect) {
        switch event.phase {
        case .began:
            magnifyAccumulator = 0
        case .changed:
            magnifyAccumulator += event.magnification

            if abs(magnifyAccumulator) >= magnifyScrollThreshold {
                let scrollDelta = Int32(-magnifyAccumulator * 50)
                injectScrollWithModifier(
                    deltaY: scrollDelta,
                    modifier: .maskCommand,
                    windowFrame: windowFrame
                )
                magnifyAccumulator = 0
            }
        case .ended, .cancelled:
            if abs(magnifyAccumulator) > 0.005 {
                let scrollDelta = Int32(-magnifyAccumulator * 50)
                injectScrollWithModifier(
                    deltaY: scrollDelta,
                    modifier: .maskCommand,
                    windowFrame: windowFrame
                )
            }
            magnifyAccumulator = 0
        default:
            break
        }
    }

    private func handleRotateGesture(_ event: MirageRotateEvent, windowFrame: CGRect) {
        switch event.phase {
        case .began:
            rotationAccumulator = 0
        case .changed:
            rotationAccumulator += event.rotation

            if abs(rotationAccumulator) >= rotationScrollThreshold {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
                rotationAccumulator = 0
            }
        case .ended, .cancelled:
            if abs(rotationAccumulator) > 0.5 {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
            }
            rotationAccumulator = 0
        default:
            break
        }
    }

    private func injectScrollWithModifier(
        deltaX: Int32 = 0,
        deltaY: Int32 = 0,
        modifier: CGEventFlags,
        windowFrame: CGRect
    ) {
        let scrollPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        cgEvent.flags = modifier
        postEvent(cgEvent)
    }

    // MARK: - Window Activation (runs on accessibilityQueue)

    private func activateWindow(windowID: WindowID, app: MirageApplication?) {
        guard let app,
              let runningApp = NSRunningApplication(processIdentifier: app.id) else { return }

        runningApp.activate()

        let appElement = AXUIElementCreateApplication(app.id)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let axWindow = findAXWindowByID(appElement: appElement, windowID: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else {
            Task {
                await MainActor.run {
                    _ = MirageHostService.bringWindowToFront(windowID)
                }
            }
        }
    }

    private func findAXWindowByID(appElement: AXUIElement, windowID: WindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in windows {
            var cgWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success,
               cgWindowID == windowID {
                return axWindow
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func postEvent(_ event: CGEvent) {
        event.post(tap: .cgSessionEventTap)
    }

    private func currentWindowFrame(for windowID: WindowID) -> CGRect? {
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let windowInfo = windowList.first,
           let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"],
           let w = bounds["Width"], let h = bounds["Height"] {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    private func framesAreClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
        abs(a.origin.y - b.origin.y) <= tolerance &&
        abs(a.width - b.width) <= tolerance &&
        abs(a.height - b.height) <= tolerance
    }
}
#endif
