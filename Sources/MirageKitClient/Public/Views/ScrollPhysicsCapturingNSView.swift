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

    /// Cursor position store for desktop cursor sync.
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
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether locked desktop cursor input may move beyond the streamed view bounds.
    var allowsExtendedCursorBounds: Bool = false {
        didSet {
            guard allowsExtendedCursorBounds != oldValue else { return }
            lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
            lockedCursorTargetPosition = resolvedLockedCursorEventPosition(lockedCursorTargetPosition)
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether cursor lock can be recaptured after a temporary local unlock.
    var canRecaptureCursorLock: Bool = false

    /// Callback when unmodified Escape should temporarily unlock cursor capture.
    var onCursorLockEscapeRequested: (() -> Void)?

    /// Callback when the next click should recapture cursor capture.
    var onCursorLockRecaptureRequested: (() -> Void)?

    /// Whether Mirage should render its synthetic locked-cursor overlay.
    var syntheticCursorEnabled: Bool = true {
        didSet {
            guard syntheticCursorEnabled != oldValue else { return }
            updateLockedCursorViewVisibility()
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether event handling is enabled for this capture view.
    var inputEnabled: Bool = true {
        didSet {
            guard inputEnabled != oldValue else { return }
            handleInputActivityStateChange()
        }
    }

    /// The actual content we display (stays pinned to bounds)
    let contentView: NSView

    /// Callback for scroll events: (deltaX, deltaY, location, phase, momentumPhase, modifiers, isPrecise)
    /// Location is normalized in stream space and may exceed 0...1 for secondary desktop travel.
    var onScroll: ((CGFloat, CGFloat, CGPoint?, MirageScrollPhase, MirageScrollPhase, MirageModifierFlags, Bool) -> Void)?

    /// Callback for mouse events - used for forwarding clicks to host
    var onMouseEvent: ((MirageInputEvent) -> Void)?

    /// Client-reserved shortcuts that should NOT be forwarded to the host.
    /// All other key equivalents are intercepted and forwarded.
    var clientShortcuts: [MirageClientShortcut] = []

    /// Callback for client-reserved shortcut actions (e.g. exit stream).
    var onClientShortcut: ((MirageClientShortcut) -> Void)?

    /// Unified actions that can be triggered by shortcuts.
    var actions: [MirageAction] = []

    /// Callback when a unified action is triggered.
    var onActionTriggered: ((MirageAction) -> Void)?

    /// Track current modifier state
    private var currentModifiers: MirageModifierFlags = []
    private var modifierPollTimer: Timer?
    private let modifierPollInterval: TimeInterval = 0.1

    /// Last known mouse location in stream space for scroll events.
    /// Secondary desktop cursor-lock travel may temporarily exceed `0...1`.
    private var lastMouseLocation: CGPoint?

    /// Locked cursor view for secondary display mode
    private let lockedCursorView = NSImageView(frame: .zero)
    private var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private var lockedCursorVisible: Bool = false
    private var lockedCursorTargetVisible: Bool = false
    private var lockedCursorSequence: UInt64 = 0
    private var lastLockedCursorRefreshTime: CFTimeInterval = 0
    private let lockedCursorRefreshInterval: CFTimeInterval = MirageInteractionCadence.frameInterval120Seconds
    private var lastCursorLocalInputTime: CFTimeInterval = 0
    private let cursorLocalHoldInterval: CFTimeInterval = 0.12
    private let lockedCursorLerpAlpha: CGFloat = 0.25
    private let lockedCursorSnapThreshold: CGFloat = 0.08
    private let lockedCursorStopThreshold: CGFloat = 0.002
    private var lockedCursorSmoothingTimer: Timer?
    private var mirroredSystemCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private var mirroredSystemCursorVisible: Bool = true
    private var mirroredSystemCursorType: MirageCursorType = .arrow
    private var mirroredSystemCursorPositionSequence: UInt64 = 0
    private var mirroredSystemCursorTypeSequence: UInt64 = 0
    private let mirroredSystemCursorWarpThreshold: CGFloat = 0.5
    private var cursorLockAnchor: CGPoint = .zero
    private var cursorHidden: Bool = false
    private var cursorHiddenForTyping: Bool = false
    private var suppressEscapeKeyUpForCursorUnlock = false
    private nonisolated(unsafe) var registeredCursorStreamID: StreamID?

    override init(frame: CGRect) {
        contentView = NSView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        contentView = NSView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setupLockedCursorView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        handleInputActivityStateChange()
        if let window, isInputProcessingActive {
            window.makeFirstResponder(self)
        }
    }

    private func setupLockedCursorView() {
        lockedCursorView.imageScaling = .scaleNone
        lockedCursorView.isHidden = true
        updateLockedCursorImage()
        contentView.addSubview(lockedCursorView)
    }

    private func updateLockedCursorImage() {
        let cursorType = mirroredSystemCursorType
        let image = NSImage(named: cursorType.cursorImageName)
            ?? Bundle.module.image(forResource: cursorType.cursorImageName)
        lockedCursorView.image = image
        if let image {
            lockedCursorView.frame.size = image.size
        }
    }

    override func layout() {
        super.layout()
        if cursorLockEnabled, isInputProcessingActive {
            updateCursorLockAnchor()
            warpCursorToAnchor()
        } else if shouldMirrorHostCursorToSystemCursor {
            applyMirroredSystemCursorPosition(force: true)
        }
        updateLockedCursorViewPosition()
    }

    private var isInputProcessingActive: Bool {
        inputEnabled && window != nil
    }

    private var shouldMirrorHostCursorToSystemCursor: Bool {
        isInputProcessingActive && !cursorLockEnabled && !syntheticCursorEnabled
    }

    private var isKeyboardInputActive: Bool {
        guard isInputProcessingActive, let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    private func handleInputActivityStateChange() {
        if isInputProcessingActive {
            updateCursorLockMode()
            startModifierPollingIfNeeded()
            syncModifierStateFromSystem(force: true)
        } else {
            stopLockedCursorSmoothing()
            stopModifierPolling()
            cursorHiddenForTyping = false
            restoreCursorLockIfNeeded()
            lockedCursorView.isHidden = true
            syncModifierState([], force: true)
        }

        invalidateHostCursorRects()
        applyMirroredSystemCursorAppearance()
        updateTrackingAreas()
    }

    private func startModifierPollingIfNeeded() {
        guard modifierPollTimer == nil else { return }
        let timer = Timer(timeInterval: modifierPollInterval, repeats: true) { [weak self] _ in
            self?.pollModifierState()
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPollTimer = timer
    }

    private func stopModifierPolling() {
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
    }

    private func syncModifierState(_ modifiers: MirageModifierFlags, force: Bool = false) {
        guard force || modifiers != currentModifiers else { return }
        currentModifiers = modifiers
        onMouseEvent?(.flagsChanged(modifiers))
    }

    private func syncModifierStateFromSystem(force: Bool = false) {
        syncModifierState(MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags), force: force)
    }

    private func pollModifierState() {
        guard isKeyboardInputActive else { return }
        let modifiers = MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags)
        if modifiers != currentModifiers {
            syncModifierState(modifiers, force: true)
            return
        }

        // Keep the host's held-modifier timestamps fresh for long holds.
        if !modifiers.isEmpty { onMouseEvent?(.flagsChanged(modifiers)) }
    }

    // MARK: - Cursor Lock

    private var shouldHideSystemCursor: Bool {
        cursorLockEnabled ||
            cursorHiddenForTyping ||
            (shouldMirrorHostCursorToSystemCursor && !mirroredSystemCursorVisible)
    }

    private func updateSystemCursorVisibility() {
        if shouldHideSystemCursor {
            if !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
        } else if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func updateLockedCursorViewVisibility() {
        let shouldShow = cursorLockEnabled && syntheticCursorEnabled && !cursorHiddenForTyping
        lockedCursorView.isHidden = !shouldShow
    }

    private func hideCursorForTypingUntilPointerMovement() {
        guard !cursorHiddenForTyping else { return }
        cursorHiddenForTyping = true
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
    }

    private func revealCursorAfterPointerMovement() {
        guard cursorHiddenForTyping else { return }
        cursorHiddenForTyping = false
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
    }

    private func updateCursorLockMode() {
        guard isInputProcessingActive else {
            stopLockedCursorSmoothing()
            restoreCursorLockIfNeeded()
            return
        }

        if cursorLockEnabled {
            updateSystemCursorVisibility()
            CGAssociateMouseAndMouseCursorPosition(0)
            updateCursorLockAnchor()
            warpCursorToAnchor()
            startLockedCursorSmoothingIfNeeded()
            refreshCursorUpdates(force: true)
            setLockedCursorVisible(lockedCursorVisible)
        } else {
            stopLockedCursorSmoothing()
            restoreCursorLockIfNeeded()
            refreshCursorUpdates(force: true)
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
        updateSystemCursorVisibility()
        updateLockedCursorViewVisibility()
        applyMirroredSystemCursorAppearance()
    }

    private func invalidateHostCursorRects() {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    private func applyMirroredSystemCursorAppearance() {
        updateSystemCursorVisibility()
        invalidateHostCursorRects()

        guard shouldMirrorHostCursorToSystemCursor, mirroredSystemCursorVisible, isMouseInsideView else { return }
        mirroredSystemCursorType.nsCursor.set()
    }

    private var isMouseInsideView: Bool {
        guard let window else { return false }
        let locationInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(locationInView)
    }

    private func applyMirroredSystemCursorPosition(force: Bool = false) {
        guard shouldMirrorHostCursorToSystemCursor, mirroredSystemCursorVisible else { return }
        guard !isCursorLocalInputActive() else { return }
        guard let targetScreenPoint = mirroredSystemCursorScreenPoint() else { return }

        let currentLocation = NSEvent.mouseLocation
        let delta = hypot(currentLocation.x - targetScreenPoint.x, currentLocation.y - targetScreenPoint.y)
        guard force || delta >= mirroredSystemCursorWarpThreshold else { return }

        CGWarpMouseCursorPosition(targetScreenPoint)
        lastMouseLocation = mirroredSystemCursorPosition
    }

    private func mirroredSystemCursorScreenPoint() -> CGPoint? {
        guard let window else { return nil }
        let localPoint = Self.localPoint(forNormalizedCursorPosition: mirroredSystemCursorPosition, in: bounds)
        let windowPoint = convert(localPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func refreshMirroredSystemCursorIfNeeded(force: Bool = false) -> Bool {
        guard shouldMirrorHostCursorToSystemCursor, let streamID else { return false }

        let positionSnapshot = cursorPositionStore?.snapshot(for: streamID)
        let cursorSnapshot = cursorStore?.snapshot(for: streamID)
        let resolvedVisibility = positionSnapshot?.isVisible ?? cursorSnapshot?.isVisible ?? mirroredSystemCursorVisible
        var didUpdate = force

        if let positionSnapshot, force || positionSnapshot.sequence != mirroredSystemCursorPositionSequence {
            mirroredSystemCursorPositionSequence = positionSnapshot.sequence
            mirroredSystemCursorPosition = Self.clampedNormalizedCursorPosition(positionSnapshot.position)
            didUpdate = true
        }

        if let cursorSnapshot, force || cursorSnapshot.sequence != mirroredSystemCursorTypeSequence {
            mirroredSystemCursorTypeSequence = cursorSnapshot.sequence
            let typeChanged = mirroredSystemCursorType != cursorSnapshot.cursorType
            mirroredSystemCursorType = cursorSnapshot.cursorType
            if typeChanged {
                updateLockedCursorImage()
            }
            didUpdate = true
        }

        if mirroredSystemCursorVisible != resolvedVisibility {
            mirroredSystemCursorVisible = resolvedVisibility
            didUpdate = true
        }

        guard didUpdate else { return false }
        applyMirroredSystemCursorAppearance()
        applyMirroredSystemCursorPosition(force: force)
        return true
    }

    nonisolated static func clampedNormalizedCursorPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }

    nonisolated static func normalizedCursorPosition(
        _ position: CGPoint,
        allowsExtendedBounds: Bool
    )
    -> CGPoint {
        LockedCursorPositionResolver.resolve(position, allowsExtendedBounds: allowsExtendedBounds)
    }

    nonisolated static func localPoint(forNormalizedCursorPosition position: CGPoint, in bounds: CGRect) -> CGPoint {
        let clampedPosition = clampedNormalizedCursorPosition(position)
        return CGPoint(
            x: clampedPosition.x * bounds.width,
            y: (1.0 - clampedPosition.y) * bounds.height
        )
    }

    @discardableResult
    private func requestCursorLockRecaptureIfNeeded() -> Bool {
        guard canRecaptureCursorLock else { return false }
        window?.makeFirstResponder(self)
        onCursorLockRecaptureRequested?()
        return true
    }

    @discardableResult
    private func requestCursorLockEscapeIfNeeded(for event: NSEvent) -> Bool {
        guard cursorLockEnabled else { return false }
        let modifiers = MirageModifierFlags(nsEventFlags: event.modifierFlags)
        guard modifiers.isEmpty else { return false }
        onCursorLockEscapeRequested?()
        return true
    }

    private func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = isVisible
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    private func resolvedLockedCursorEventPosition(_ position: CGPoint) -> CGPoint {
        Self.normalizedCursorPosition(position, allowsExtendedBounds: allowsExtendedCursorBounds)
    }

    private func lockedCursorActionPosition() -> CGPoint {
        resolvedLockedCursorEventPosition(lockedCursorPosition)
    }

    private func updateLockedCursorViewPosition() {
        guard cursorLockEnabled, !lockedCursorView.isHidden else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = Self.localPoint(forNormalizedCursorPosition: lockedCursorPosition, in: bounds)
        let hotspot = mirroredSystemCursorType.cursorHotspot
        // macOS uses flipped coordinates for the hotspot Y (bottom-left origin)
        lockedCursorView.frame.origin = CGPoint(
            x: point.x - hotspot.x,
            y: point.y - (lockedCursorView.frame.height - hotspot.y)
        )
    }

    private func applyLockedCursorDelta(dx: CGFloat, dy: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        lockedCursorPosition.x += dx / bounds.width
        lockedCursorPosition.y -= dy / bounds.height
        lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
        noteCursorLocalInput()
        setLockedCursorVisible(true)
        lastMouseLocation = lockedCursorPosition
    }

    private func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = resolvedLockedCursorEventPosition(position)
        lockedCursorTargetVisible = isVisible
        guard cursorLockEnabled else { return }
        guard !isCursorLocalInputActive() else { return }
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
        lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
        lastMouseLocation = lockedCursorPosition
        updateLockedCursorViewPosition()
    }

    private func noteCursorLocalInput() {
        lastCursorLocalInputTime = CACurrentMediaTime()
        if cursorLockEnabled {
            lockedCursorTargetPosition = lockedCursorPosition
            lockedCursorTargetVisible = true
        }
    }

    private func isCursorLocalInputActive() -> Bool {
        let now = CACurrentMediaTime()
        return now - lastCursorLocalInputTime < cursorLocalHoldInterval
    }

    private func startLockedCursorSmoothingIfNeeded() {
        guard lockedCursorSmoothingTimer == nil else { return }
        lockedCursorSmoothingTimer = Timer.scheduledTimer(
            withTimeInterval: MirageInteractionCadence.frameInterval120Seconds,
            repeats: true
        ) { [weak self] _ in
            self?.handleLockedCursorSmoothing()
        }
    }

    private func stopLockedCursorSmoothing() {
        lockedCursorSmoothingTimer?.invalidate()
        lockedCursorSmoothingTimer = nil
    }

    private func handleLockedCursorSmoothing() {
        guard isInputProcessingActive, cursorLockEnabled else {
            stopLockedCursorSmoothing()
            return
        }
        guard !isCursorLocalInputActive() else { return }
        applyLockedCursorTargetStep()
    }

    private func refreshLockedCursorIfNeeded(force: Bool = false) -> Bool {
        guard isInputProcessingActive, cursorLockEnabled, let cursorPositionStore, let streamID else { return false }
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
        guard isInputProcessingActive else { return }
        _ = refreshMirroredSystemCursorIfNeeded(force: force)
        let updatedFromPosition = refreshLockedCursorIfNeeded(force: force)
        guard cursorLockEnabled else { return }
        if !updatedFromPosition, let cursorStore, let streamID,
           let snapshot = cursorStore.snapshot(for: streamID) {
            setLockedCursorVisible(snapshot.isVisible)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInputProcessingActive else { return }

        let phase = MirageScrollPhase(from: event.phase)
        let momentumPhase = MirageScrollPhase(from: event.momentumPhase)
        let isPrecise = event.hasPreciseScrollingDeltas

        if cursorLockEnabled {
            lastMouseLocation = lockedCursorPosition
        } else {
            let locationInView = convert(event.locationInWindow, from: nil)
            if bounds.width > 0, bounds.height > 0 {
                lastMouseLocation = CGPoint(
                    x: locationInView.x / bounds.width,
                    y: 1.0 - (locationInView.y / bounds.height)
                )
            }
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        if deltaX != 0 || deltaY != 0 || phase != .none || momentumPhase != .none {
            let modifiers = MirageModifierFlags(nsEventFlags: event.modifierFlags)
            onScroll?(deltaX, deltaY, lastMouseLocation, phase, momentumPhase, modifiers, isPrecise)
        }
    }

    // MARK: - Mouse Event Handling

    override func mouseDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition()
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            lastMouseLocation = location
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
        guard isInputProcessingActive else { return }

        let location: CGPoint
        let movedByDelta = event.deltaX != 0 || event.deltaY != 0
        if cursorLockEnabled {
            if movedByDelta { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            lastMouseLocation = location
        }

        guard movedByDelta else { return }

        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: 0,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseMoved(mouseEvent))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition()
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            lastMouseLocation = location
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
        guard isInputProcessingActive else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
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
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition()
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            lastMouseLocation = location
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

    /// Intercept key equivalents before AppKit's menu bar dispatching.
    /// Client-reserved shortcuts (exit stream, dictation toggle) are handled locally.
    /// All other key equivalents (including Cmd+Q, Cmd+W) are forwarded to the host.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isInputProcessingActive else { return super.performKeyEquivalent(with: event) }

        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: event.isARepeat
        )

        // Check if this matches a unified action
        for action in actions {
            guard let binding = action.shortcut else { continue }
            if binding.matches(keyEvent) {
                onActionTriggered?(action)
                return true
            }
        }

        // Check if this matches a client-reserved shortcut
        for shortcut in clientShortcuts where shortcut.matches(keyEvent) {
            onClientShortcut?(shortcut)
            return true
        }

        // Forward all other key equivalents to the host
        hideCursorForTypingUntilPointerMovement()
        onMouseEvent?(.keyDown(keyEvent))
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { syncModifierStateFromSystem(force: true) }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        // Clear modifier state when losing focus to prevent stuck modifiers
        syncModifierState([], force: true)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        if event.keyCode == 53, requestCursorLockEscapeIfNeeded(for: event) {
            suppressEscapeKeyUpForCursorUnlock = true
            syncModifierState([], force: true)
            return
        }
        hideCursorForTypingUntilPointerMovement()
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
        guard isInputProcessingActive else { return }
        if event.keyCode == 53, suppressEscapeKeyUpForCursorUnlock {
            suppressEscapeKeyUpForCursorUnlock = false
            return
        }
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
        guard isInputProcessingActive else { return }
        syncModifierState(MirageModifierFlags(nsEventFlags: event.modifierFlags), force: true)
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

        guard isInputProcessingActive else { return }

        // Add new tracking area for the entire view
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard shouldMirrorHostCursorToSystemCursor, mirroredSystemCursorVisible else { return }
        addCursorRect(bounds, cursor: mirroredSystemCursorType.nsCursor)
    }

    deinit {
        MainActor.assumeIsolated {
            stopModifierPolling()
        }
        if let registeredCursorStreamID { MirageCursorUpdateRouter.shared.unregister(streamID: registeredCursorStreamID) }
        MainActor.assumeIsolated {
            cursorHiddenForTyping = false
            stopLockedCursorSmoothing()
        }
        MainActor.assumeIsolated {
            restoreCursorLockIfNeeded()
        }
    }
}

extension ScrollPhysicsCapturingNSView: MirageCursorUpdateHandling {}
#endif
