//
//  ScrollPhysicsCapturingNSView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

/// Invisible scroll view that captures native trackpad scroll physics on macOS.
/// The actual content (Metal view) stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
final class ScrollPhysicsCapturingNSView: NSView {
    /// Stream ID for cursor update routing
    var streamID: StreamID? {
        didSet {
            let previousID = registeredCursorStreamID
            if let previousID, previousID != streamID { MirageCursorUpdateRouter.shared.unregister(streamID: previousID) }
            registeredCursorStreamID = streamID
            if let streamID { MirageCursorUpdateRouter.shared.register(view: self, for: streamID) }
            refreshCursorUpdates(force: true)
        }
    }

    /// Cursor store for visibility updates
    var cursorStore: MirageClientCursorStore? {
        didSet {
            refreshCursorUpdates(force: true)
        }
    }

    /// Cursor position store for secondary display sync
    var cursorPositionStore: MirageClientCursorPositionStore? {
        didSet {
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether the system cursor should be locked/hidden
    var cursorLockEnabled: Bool = false {
        didSet {
            guard cursorLockEnabled != oldValue else { return }
            updateCursorLockMode()
        }
    }

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

    /// Locked cursor view for secondary display mode
    private let lockedCursorView = NSView(frame: .zero)
    private var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private var lockedCursorVisible: Bool = false
    private var lockedCursorTargetVisible: Bool = false
    private var lockedCursorSequence: UInt64 = 0
    private var lastLockedCursorRefreshTime: CFTimeInterval = 0
    private let lockedCursorRefreshInterval: CFTimeInterval = 1.0 / 30.0
    private var lastLockedCursorLocalInputTime: CFTimeInterval = 0
    private let lockedCursorLocalHoldInterval: CFTimeInterval = 0.12
    private let lockedCursorLerpAlpha: CGFloat = 0.25
    private let lockedCursorSnapThreshold: CGFloat = 0.08
    private let lockedCursorStopThreshold: CGFloat = 0.002
    private var lockedCursorSmoothingTimer: Timer?
    private var cursorLockAnchor: CGPoint = .zero
    private var cursorHidden: Bool = false
    private nonisolated(unsafe) var registeredCursorStreamID: StreamID?

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

        setupLockedCursorView()

        // Listen for scroll changes via bounds notification
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupLockedCursorView() {
        lockedCursorView.wantsLayer = true
        lockedCursorView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        lockedCursorView.layer?.cornerRadius = 6
        lockedCursorView.layer?.borderWidth = 1
        lockedCursorView.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        lockedCursorView.layer?.shadowColor = NSColor.black.cgColor
        lockedCursorView.layer?.shadowOpacity = 0.2
        lockedCursorView.layer?.shadowRadius = 2
        lockedCursorView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        lockedCursorView.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        lockedCursorView.isHidden = true
        contentView.addSubview(lockedCursorView)
    }

    override func layout() {
        super.layout()

        // Ensure documentView maintains its large size (NSScrollView may resize it)
        if documentView.frame.size.width != scrollableSize || documentView.frame.size.height != scrollableSize { documentView.frame = NSRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize) }

        recenterIfNeeded(force: lastScrollPosition == .zero)
        if cursorLockEnabled {
            updateCursorLockAnchor()
            warpCursorToAnchor()
        }
        updateLockedCursorViewPosition()
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

    // MARK: - Cursor Lock

    private func updateCursorLockMode() {
        if cursorLockEnabled {
            if !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            updateCursorLockAnchor()
            warpCursorToAnchor()
            startLockedCursorSmoothingIfNeeded()
            refreshCursorUpdates(force: true)
            setLockedCursorVisible(lockedCursorVisible)
        } else {
            stopLockedCursorSmoothing()
            restoreCursorLockIfNeeded()
        }
    }

    private func updateCursorLockAnchor() {
        guard let window else { return }
        let localPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(localPoint, to: nil)
        cursorLockAnchor = window.convertPoint(toScreen: windowPoint)
    }

    private func warpCursorToAnchor() {
        guard cursorLockEnabled else { return }
        guard window != nil else { return }
        CGWarpMouseCursorPosition(cursorLockAnchor)
    }

    private func restoreCursorLockIfNeeded() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        lockedCursorView.isHidden = true
    }

    private func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = isVisible
        lockedCursorView.isHidden = !(cursorLockEnabled && isVisible)
        updateLockedCursorViewPosition()
    }

    private func clampedLockedCursorPosition() -> CGPoint {
        CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
    }

    private func updateLockedCursorViewPosition() {
        guard cursorLockEnabled, !lockedCursorView.isHidden else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let clamped = clampedLockedCursorPosition()
        let center = CGPoint(
            x: clamped.x * bounds.width,
            y: (1.0 - clamped.y) * bounds.height
        )
        lockedCursorView.frame.origin = CGPoint(
            x: center.x - lockedCursorView.frame.width * 0.5,
            y: center.y - lockedCursorView.frame.height * 0.5
        )
    }

    private func applyLockedCursorDelta(dx: CGFloat, dy: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        lockedCursorPosition.x += dx / bounds.width
        lockedCursorPosition.y -= dy / bounds.height
        lockedCursorPosition = clampedLockedCursorPosition()
        noteLockedCursorLocalInput()
        setLockedCursorVisible(true)
        lastMouseLocation = clampedLockedCursorPosition()
    }

    private func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = position
        lockedCursorTargetVisible = isVisible
        guard cursorLockEnabled else { return }
        guard !isLockedCursorLocalInputActive() else { return }
        applyLockedCursorTargetStep()
    }

    private func applyLockedCursorTargetStep() {
        setLockedCursorVisible(lockedCursorTargetVisible)
        guard lockedCursorTargetVisible else { return }
        let deltaX = lockedCursorTargetPosition.x - lockedCursorPosition.x
        let deltaY = lockedCursorTargetPosition.y - lockedCursorPosition.y
        let distance = hypot(deltaX, deltaY)
        if distance < lockedCursorStopThreshold { return }
        if distance > lockedCursorSnapThreshold {
            lockedCursorPosition = lockedCursorTargetPosition
        } else {
            lockedCursorPosition = CGPoint(
                x: lockedCursorPosition.x + deltaX * lockedCursorLerpAlpha,
                y: lockedCursorPosition.y + deltaY * lockedCursorLerpAlpha
            )
        }
        lastMouseLocation = clampedLockedCursorPosition()
        updateLockedCursorViewPosition()
    }

    private func noteLockedCursorLocalInput() {
        lastLockedCursorLocalInputTime = CACurrentMediaTime()
        lockedCursorTargetPosition = lockedCursorPosition
        lockedCursorTargetVisible = true
    }

    private func isLockedCursorLocalInputActive() -> Bool {
        let now = CACurrentMediaTime()
        return now - lastLockedCursorLocalInputTime < lockedCursorLocalHoldInterval
    }

    private func startLockedCursorSmoothingIfNeeded() {
        guard lockedCursorSmoothingTimer == nil else { return }
        lockedCursorSmoothingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLockedCursorSmoothing()
            }
        }
    }

    private func stopLockedCursorSmoothing() {
        lockedCursorSmoothingTimer?.invalidate()
        lockedCursorSmoothingTimer = nil
    }

    private func handleLockedCursorSmoothing() {
        guard cursorLockEnabled else {
            stopLockedCursorSmoothing()
            return
        }
        guard !isLockedCursorLocalInputActive() else { return }
        applyLockedCursorTargetStep()
    }

    private func refreshLockedCursorIfNeeded(force: Bool = false) -> Bool {
        guard cursorLockEnabled, let cursorPositionStore, let streamID else { return false }
        let now = CACurrentMediaTime()
        if !force, now - lastLockedCursorRefreshTime < lockedCursorRefreshInterval { return false }
        lastLockedCursorRefreshTime = now
        guard let snapshot = cursorPositionStore.snapshot(for: streamID) else { return false }
        guard force || snapshot.sequence != lockedCursorSequence else { return false }
        lockedCursorSequence = snapshot.sequence
        applyLockedCursorHostUpdate(position: snapshot.position, isVisible: snapshot.isVisible)
        return true
    }

    func refreshCursorUpdates(force: Bool) {
        let updatedFromPosition = refreshLockedCursorIfNeeded(force: force)
        guard cursorLockEnabled else { return }
        if !updatedFromPosition, let cursorStore, let streamID,
           let snapshot = cursorStore.snapshot(for: streamID) {
            setLockedCursorVisible(snapshot.isVisible)
        }
    }

    @objc
    private func boundsDidChange(_: Notification) {
        // Skip sending events during recenter operation
        guard !isRecentering else { return }

        let currentPos = scrollView.documentVisibleRect.origin
        // Calculate deltas (content moving = scroll in opposite direction)
        let deltaX = lastScrollPosition.x - currentPos.x
        let deltaY = currentPos.y - lastScrollPosition.y // NSScrollView Y is flipped
        lastScrollPosition = currentPos

        if deltaX != 0 || deltaY != 0 {
            // Phase determination based on scroll state
            let phase: MirageScrollPhase = .changed
            let momentumPhase: MirageScrollPhase = .none
            // Use last known mouse location for scroll position
            onScroll?(deltaX, deltaY, lastMouseLocation, phase, momentumPhase, true)
        }
    }

    /// Override scrollWheel to capture phases and handle momentum
    override func scrollWheel(with event: NSEvent) {
        // Extract phases from NSEvent
        let phase = MirageScrollPhase(from: event.phase)
        let momentumPhase = MirageScrollPhase(from: event.momentumPhase)

        // Get mouse location and normalize to 0-1 within view bounds
        if cursorLockEnabled {
            lastMouseLocation = clampedLockedCursorPosition()
        } else {
            let locationInView = convert(event.locationInWindow, from: nil)
            if bounds.width > 0, bounds.height > 0 {
                lastMouseLocation = CGPoint(
                    x: locationInView.x / bounds.width,
                    y: 1.0 - (locationInView.y / bounds.height) // Flip Y for normalized coords
                )
            }
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
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDown(mouseEvent))
    }

    override func mouseUp(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseUp(mouseEvent))
    }

    override func mouseDragged(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDragged(mouseEvent))
    }

    override func mouseMoved(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
            lastMouseLocation = location
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: 0,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseMoved(mouseEvent))
    }

    override func rightMouseDown(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDown(mouseEvent))
    }

    override func rightMouseUp(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseUp(mouseEvent))
    }

    override func rightMouseDragged(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDragged(mouseEvent))
    }

    override func otherMouseDown(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseDown(mouseEvent))
    }

    override func otherMouseUp(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
        let mouseEvent = MirageMouseEvent(
            button: MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseUp(mouseEvent))
    }

    override func otherMouseDragged(with event: NSEvent) {
        let location: CGPoint
        if cursorLockEnabled {
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
        }
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
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: locationInView.x / bounds.width,
            y: 1.0 - (locationInView.y / bounds.height) // Flip Y for normalized coords
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
        if let registeredCursorStreamID { MirageCursorUpdateRouter.shared.unregister(streamID: registeredCursorStreamID) }
        MainActor.assumeIsolated {
            stopLockedCursorSmoothing()
        }
        MainActor.assumeIsolated {
            restoreCursorLockIfNeeded()
        }
        NotificationCenter.default.removeObserver(self)
    }
}

extension ScrollPhysicsCapturingNSView: MirageCursorUpdateHandling {}
#endif
