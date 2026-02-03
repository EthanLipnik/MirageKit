//
//  InputCapturingView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController
#endif

/// A view that wraps MirageMetalView and captures all input events
public class InputCapturingView: UIView {
    public let metalView: MirageMetalView

    // MARK: - Safe Area Override

    /// Override safe area insets to ensure Metal view fills entire screen.
    /// SwiftUI's .ignoresSafeArea() doesn't propagate through UIViewRepresentable boundaries,
    /// so we must explicitly return zero insets at the UIKit layer.
    override public var safeAreaInsets: UIEdgeInsets { .zero }

    /// Callback for input events - set by the SwiftUI representable's coordinator
    public var onInputEvent: ((MirageInputEvent) -> Void)? {
        didSet {
            if onInputEvent != nil { sendModifierStateIfNeeded(force: true) }
        }
    }

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? {
        didSet {
            metalView.onDrawableMetricsChanged = onDrawableMetricsChanged
        }
    }

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)? {
        didSet {
            metalView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        }
    }

    /// Stream ID for direct frame cache access (iOS gesture tracking support)
    /// Forwards to the underlying Metal view
    public var streamID: StreamID? {
        didSet {
            metalView.streamID = streamID
            let previousID = registeredCursorStreamID
            if let previousID, previousID != streamID { MirageCursorUpdateRouter.shared.unregister(streamID: previousID) }
            registeredCursorStreamID = streamID
            if let streamID { MirageCursorUpdateRouter.shared.register(view: self, for: streamID) }
            cursorSequence = 0
            refreshCursorIfNeeded(force: true)
        }
    }

    /// Cursor store for pointer updates (decoupled from SwiftUI observation).
    public var cursorStore: MirageClientCursorStore? {
        didSet {
            cursorSequence = 0
            refreshCursorIfNeeded(force: true)
        }
    }

    /// Cursor position store for secondary display sync.
    public var cursorPositionStore: MirageClientCursorPositionStore? {
        didSet {
            lockedCursorSequence = 0
            refreshLockedCursorIfNeeded(force: true)
        }
    }

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool = false {
        didSet {
            guard cursorLockEnabled != oldValue else { return }
            updateCursorLockMode()
        }
    }

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Callback when hardware keyboard presence changes.
    public var onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? {
        didSet {
            onHardwareKeyboardPresenceChanged?(hardwareKeyboardPresent)
        }
    }

    /// Callback when software keyboard visibility changes.
    public var onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool = false

    /// Whether direct touch should use a draggable virtual cursor.
    public var usesVirtualTrackpad: Bool = false {
        didSet {
            guard usesVirtualTrackpad != oldValue else { return }
            updateVirtualTrackpadMode()
        }
    }

    // Cursor state from host
    var currentCursorType: MirageCursorType = .arrow
    var cursorIsVisible: Bool = true
    var pointerInteraction: UIPointerInteraction?
    var cursorSequence: UInt64 = 0
    var lastCursorRefreshTime: CFTimeInterval = 0
    let cursorRefreshInterval: CFTimeInterval = 1.0 / 30.0
    var lockedCursorSequence: UInt64 = 0
    var lastLockedCursorRefreshTime: CFTimeInterval = 0
    let lockedCursorRefreshInterval: CFTimeInterval = 1.0 / 30.0
    // nonisolated(unsafe) allows access from deinit for cleanup
    private nonisolated(unsafe) var registeredCursorStreamID: StreamID?
    private(set) var hardwareKeyboardPresent: Bool = false

    // Virtual cursor state (direct touch trackpad mode)
    #if os(iOS)
    private let virtualCursorView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    #else
    private let virtualCursorView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    #endif
    #if os(iOS)
    private let lockedCursorView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    #else
    private let lockedCursorView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    #endif
    var virtualCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private let virtualCursorSize: CGFloat = 14
    var virtualCursorVelocity: CGPoint = .zero
    var virtualCursorDecelerationLink: CADisplayLink?
    var virtualDragActive: Bool = false
    var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    private let lockedCursorSize: CGFloat = 12
    var lockedCursorVisible: Bool = false
    var lockedCursorTargetVisible: Bool = false
    var lockedPointerButtonDown: Bool = false
    var lockedCursorLocalInputTime: CFTimeInterval = 0
    private let lockedCursorLocalHoldInterval: CFTimeInterval = 0.12
    private let lockedCursorLerpAlpha: CGFloat = 0.25
    private let lockedCursorSnapThreshold: CGFloat = 0.08
    private let lockedCursorStopThreshold: CGFloat = 0.002
    var lockedCursorDisplayLink: CADisplayLink?
    var lockedPointerLastHoverLocation: CGPoint?
    var usesMouseInputDeltas: Bool = false
    var pointerLockActive: Bool = false
    #if canImport(GameController)
    private var mouseInput: GCMouseInput?
    #endif
    var touchScrollDecelerationVelocity: CGPoint = .zero
    var touchScrollDecelerationLink: CADisplayLink?
    var touchScrollDecelerationLocation: CGPoint = .zero

    /// Software keyboard state
    public var softwareKeyboardVisible: Bool = false {
        didSet {
            guard softwareKeyboardVisible != oldValue else { return }
            updateSoftwareKeyboardVisibility()
        }
    }

    var softwareKeyboardField: SoftwareKeyboardTextField?
    var softwareKeyboardAccessoryView: SoftwareKeyboardAccessoryView?
    var isSoftwareKeyboardShown: Bool = false
    var softwareHeldModifiers: MirageModifierFlags = []

    // Gesture recognizers
    var longPressGesture: UILongPressGestureRecognizer!
    var scrollGesture: UIPanGestureRecognizer!
    var hoverGesture: UIHoverGestureRecognizer!
    var rightClickGesture: UITapGestureRecognizer!
    var virtualCursorPanGesture: UIPanGestureRecognizer!
    var virtualCursorTapGesture: UITapGestureRecognizer!
    var virtualCursorRightTapGesture: UITapGestureRecognizer!
    var virtualCursorLongPressGesture: UILongPressGestureRecognizer!
    var lockedPointerPanGesture: UIPanGestureRecognizer!
    var lockedPointerPressGesture: UILongPressGestureRecognizer!

    // Track drag state
    var isDragging = false
    var lastPanLocation: CGPoint = .zero

    /// Track last cursor position for scroll events (normalized 0-1)
    var lastCursorPosition: CGPoint?

    // Track keyboard modifier state - single source of truth
    // Gesture events read modifiers directly from gesture.modifierFlags at event time
    var heldModifierKeys: Set<UIKeyboardHIDUsage> = []
    var capsLockEnabled: Bool = false
    var lastSentModifiers: MirageModifierFlags = []
    var modifierRefreshTask: Task<Void, Never>?
    var hardwareRefreshFailureCount: Int = 0
    #if canImport(GameController)
    static let hardwareModifierKeyCodes: Set<GCKeyCode> = [
        .leftShift,
        .rightShift,
        .leftControl,
        .rightControl,
        .leftAlt,
        .rightAlt,
        .leftGUI,
        .rightGUI,
        .capsLock,
    ]
    #endif

    /// Get current modifier state from held keyboard keys
    var keyboardModifiers: MirageModifierFlags {
        var modifiers: MirageModifierFlags = []
        for keyCode in heldModifierKeys {
            if let modifier = Self.modifierKeyMap[keyCode] { modifiers.insert(modifier) }
        }
        if capsLockEnabled { modifiers.insert(.capsLock) }
        modifiers.formUnion(softwareHeldModifiers)
        return modifiers
    }

    func sendModifierStateIfNeeded(force: Bool = false) {
        let modifiers = keyboardModifiers
        guard force || modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
        updateSoftwareModifierButtons()
        onInputEvent?(.flagsChanged(modifiers))
    }

    @discardableResult
    func refreshModifiersForInput() -> Bool {
        let hardwareAvailable = refreshModifierStateFromHardware()
        if hardwareAvailable { sendModifierSnapshotIfNeeded(keyboardModifiers) }
        return hardwareAvailable
    }

    func sendModifierSnapshotIfNeeded(_ modifiers: MirageModifierFlags) {
        guard modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
        updateSoftwareModifierButtons()
        onInputEvent?(.flagsChanged(modifiers))
    }

    func updateCapsLockState(from modifierFlags: UIKeyModifierFlags) {
        let isEnabled = modifierFlags.contains(.alphaShift)
        guard isEnabled != capsLockEnabled else { return }
        capsLockEnabled = isEnabled
        sendModifierStateIfNeeded(force: true)
    }

    func resyncModifierState(from modifierFlags: UIKeyModifierFlags) {
        let flags = MirageModifierFlags(uiKeyModifierFlags: modifierFlags)
        var newHeldKeys = Set<UIKeyboardHIDUsage>()
        for (flag, keys) in Self.modifierFlagToKeys where flags.contains(flag) {
            let existingKeys = keys.filter { heldModifierKeys.contains($0) }
            if existingKeys.isEmpty {
                if let primaryKey = keys.first { newHeldKeys.insert(primaryKey) }
            } else {
                newHeldKeys.formUnion(existingKeys)
            }
        }

        let newCapsLockEnabled = flags.contains(.capsLock)

        guard newHeldKeys != heldModifierKeys || newCapsLockEnabled != capsLockEnabled else { return }
        heldModifierKeys = newHeldKeys
        capsLockEnabled = newCapsLockEnabled
        sendModifierStateIfNeeded(force: true)
        if heldModifierKeys.isEmpty { stopModifierRefresh() } else {
            startModifierRefreshIfNeeded()
        }
    }

    /// Clear all held modifiers with a snapshot update
    func resetAllModifiers() {
        guard !heldModifierKeys.isEmpty || !softwareHeldModifiers.isEmpty || capsLockEnabled || !lastSentModifiers
            .isEmpty else {
            return
        }
        stopModifierRefresh()
        heldModifierKeys.removeAll()
        softwareHeldModifiers = []
        capsLockEnabled = false
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
    }

    func startModifierRefreshIfNeeded() {
        guard modifierRefreshTask == nil else { return }
        modifierRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if refreshModifierStateFromHardware() {
                    hardwareRefreshFailureCount = 0

                    // Always send heartbeat while modifiers are held.
                    // This keeps host timestamps fresh even when state is unchanged,
                    // preventing the host's 0.5s timeout from clearing held modifiers.
                    if !heldModifierKeys.isEmpty {
                        let modifiers = keyboardModifiers
                        lastSentModifiers = modifiers
                        onInputEvent?(.flagsChanged(modifiers))
                    }
                } else {
                    hardwareRefreshFailureCount += 1
                    if hardwareRefreshFailureCount >= 3 {
                        // Hardware unavailable, clear modifiers to prevent stuck state
                        MirageLogger.client("Hardware keyboard unavailable, clearing modifiers")
                        resetAllModifiers()
                        modifierRefreshTask = nil
                        return
                    }
                }

                if heldModifierKeys.isEmpty {
                    modifierRefreshTask = nil
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
        }
    }

    func stopModifierRefresh() {
        modifierRefreshTask?.cancel()
        modifierRefreshTask = nil
    }

    func updateHardwareKeyboardPresence(_ isPresent: Bool) {
        guard hardwareKeyboardPresent != isPresent else { return }
        hardwareKeyboardPresent = isPresent
        onHardwareKeyboardPresenceChanged?(isPresent)
        if isPresent { clearSoftwareKeyboardState() }
    }

    @discardableResult
    func refreshModifierStateFromHardware() -> Bool {
        #if canImport(GameController)
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        var refreshedKeys: Set<UIKeyboardHIDUsage> = []

        if keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true { refreshedKeys.insert(.keyboardLeftShift) }
        if keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true { refreshedKeys.insert(.keyboardRightShift) }
        if keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true { refreshedKeys.insert(.keyboardLeftControl) }
        if keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true { refreshedKeys.insert(.keyboardRightControl) }
        if keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true { refreshedKeys.insert(.keyboardLeftAlt) }
        if keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true { refreshedKeys.insert(.keyboardRightAlt) }
        if keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true { refreshedKeys.insert(.keyboardLeftGUI) }
        if keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true { refreshedKeys.insert(.keyboardRightGUI) }

        guard refreshedKeys != heldModifierKeys else { return true }
        heldModifierKeys = refreshedKeys
        sendModifierStateIfNeeded(force: true)
        return true
        #else
        return false
        #endif
    }

    #if canImport(GameController)
    func installHardwareKeyboardHandler() {
        HardwareKeyboardCoordinator.shared.register(self)
    }

    func uninstallHardwareKeyboardHandler() {
        HardwareKeyboardCoordinator.shared.unregister(self)
    }
    #endif

    // Double-click detection state (left click)
    var lastTapTime: TimeInterval = 0
    var lastTapLocation: CGPoint = .zero
    var currentClickCount: Int = 0

    // Double-click detection state (right click)
    var lastRightTapTime: TimeInterval = 0
    var lastRightTapLocation: CGPoint = .zero
    var currentRightClickCount: Int = 0

    /// Maximum time between taps to count as multi-click (in seconds)
    static let multiClickTimeThreshold: TimeInterval = 0.5
    /// Maximum distance between taps to count as multi-click (in normalized coordinates)
    static let multiClickDistanceThreshold: CGFloat = 0.05

    /// Scroll physics capturing view for native trackpad momentum/bounce
    var scrollPhysicsView: ScrollPhysicsCapturingView?

    // Direct touch multi-finger gestures
    var directPinchGesture: UIPinchGestureRecognizer!
    var directRotationGesture: UIRotationGestureRecognizer!
    var lastDirectPinchScale: CGFloat = 1.0
    var lastDirectRotationAngle: CGFloat = 0.0

    /// Modifier key HID codes and their corresponding flags
    static let modifierKeyMap: [UIKeyboardHIDUsage: MirageModifierFlags] = [
        .keyboardLeftShift: .shift,
        .keyboardRightShift: .shift,
        .keyboardLeftControl: .control,
        .keyboardRightControl: .control,
        .keyboardLeftAlt: .option,
        .keyboardRightAlt: .option,
        .keyboardLeftGUI: .command,
        .keyboardRightGUI: .command,
        .keyboardCapsLock: .capsLock,
    ]

    /// Preferred key codes for modifier flag resync (preserve left/right when possible)
    static let modifierFlagToKeys: [(flag: MirageModifierFlags, keys: [UIKeyboardHIDUsage])] = [
        (.shift, [.keyboardLeftShift, .keyboardRightShift]),
        (.control, [.keyboardLeftControl, .keyboardRightControl]),
        (.option, [.keyboardLeftAlt, .keyboardRightAlt]),
        (.command, [.keyboardLeftGUI, .keyboardRightGUI]),
    ]

    /// Key repeat handling
    /// Active key repeat timers keyed by HID usage code
    var keyRepeatTimers: [UIKeyboardHIDUsage: Timer] = [:]
    /// Held key press references for generating repeat events
    var heldKeyPresses: [UIKeyboardHIDUsage: UIPress] = [:]
    /// Initial delay before key repeat starts (matches macOS default)
    static let keyRepeatInitialDelay: TimeInterval = 0.5
    /// Interval between repeat events (matches macOS default ~30 chars/sec)
    static let keyRepeatInterval: TimeInterval = 0.033

    override public init(frame: CGRect) {
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
            metalView.bottomAnchor.constraint(equalTo: scrollPhysicsView!.contentView.bottomAnchor),
        ])

        // Configure scroll physics callback
        // Scroll events don't have a gesture recognizer with modifierFlags, so use keyboard state only
        scrollPhysicsView!.onScroll = { [weak self] deltaX, deltaY, phase, momentumPhase in
            guard let self else { return }
            refreshModifiersForInput()
            let modifiers = keyboardModifiers
            sendModifierSnapshotIfNeeded(modifiers)
            let scrollEvent = MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: lastCursorPosition,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: modifiers,
                isPrecise: true // Trackpad scrolling is precise
            )
            onInputEvent?(.scrollWheel(scrollEvent))
        }

        // Configure trackpad rotation callback
        scrollPhysicsView!.onRotation = { [weak self] rotation, phase in
            guard let self else { return }
            refreshModifiersForInput()
            let event = MirageRotateEvent(rotation: rotation, phase: phase)
            onInputEvent?(.rotate(event))
        }

        // Enable user interaction
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true

        setupGestureRecognizers()
        setupPointerInteraction()
        setupVirtualCursorView()
        setupLockedCursorView()
        setupSoftwareKeyboardField()
        updateVirtualTrackpadMode()
        updateCursorLockMode()
        setupSceneLifecycleObservers()
    }

    private func setupVirtualCursorView() {
        virtualCursorView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: virtualCursorSize, height: virtualCursorSize)
        )
        virtualCursorView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        virtualCursorView.clipsToBounds = true
        virtualCursorView.layer.cornerRadius = virtualCursorSize / 2
        virtualCursorView.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
        virtualCursorView.layer.borderWidth = 1
        virtualCursorView.layer.shadowColor = UIColor.black.cgColor
        virtualCursorView.layer.shadowOpacity = 0.2
        virtualCursorView.layer.shadowRadius = 2
        virtualCursorView.layer.shadowOffset = CGSize(width: 0, height: 1)
        virtualCursorView.isUserInteractionEnabled = false
        virtualCursorView.isHidden = true
        addSubview(virtualCursorView)
    }

    private func setupLockedCursorView() {
        lockedCursorView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: lockedCursorSize, height: lockedCursorSize)
        )
        lockedCursorView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        lockedCursorView.clipsToBounds = true
        lockedCursorView.layer.cornerRadius = lockedCursorSize / 2
        lockedCursorView.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
        lockedCursorView.layer.borderWidth = 1
        lockedCursorView.layer.shadowColor = UIColor.black.cgColor
        lockedCursorView.layer.shadowOpacity = 0.2
        lockedCursorView.layer.shadowRadius = 2
        lockedCursorView.layer.shadowOffset = CGSize(width: 0, height: 1)
        lockedCursorView.isUserInteractionEnabled = false
        lockedCursorView.isHidden = true
        addSubview(lockedCursorView)
    }

    func updateVirtualTrackpadMode() {
        let directTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let indirectTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        if cursorLockEnabled {
            longPressGesture.allowedTouchTypes = directTouchTypes
            virtualCursorPanGesture.isEnabled = false
            virtualCursorTapGesture.isEnabled = false
            virtualCursorRightTapGesture.isEnabled = false
            virtualCursorLongPressGesture.isEnabled = false
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            setVirtualCursorVisible(false)
        } else if usesVirtualTrackpad {
            longPressGesture.allowedTouchTypes = indirectTouchTypes
            virtualCursorPanGesture.isEnabled = true
            virtualCursorTapGesture.isEnabled = true
            virtualCursorRightTapGesture.isEnabled = true
            virtualCursorLongPressGesture.isEnabled = true
            lastCursorPosition = virtualCursorPosition
            setVirtualCursorVisible(true)
        } else {
            longPressGesture.allowedTouchTypes = directTouchTypes + indirectTouchTypes
            virtualCursorPanGesture.isEnabled = false
            virtualCursorTapGesture.isEnabled = false
            virtualCursorRightTapGesture.isEnabled = false
            virtualCursorLongPressGesture.isEnabled = false
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            setVirtualCursorVisible(false)
        }
    }

    func setVirtualCursorVisible(_ isVisible: Bool) {
        guard usesVirtualTrackpad else {
            virtualCursorView.isHidden = true
            return
        }
        virtualCursorView.isHidden = !isVisible
        updateVirtualCursorViewPosition()
    }

    func updateVirtualCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !virtualCursorView.isHidden else { return }
        virtualCursorView.center = CGPoint(
            x: virtualCursorPosition.x * bounds.width,
            y: virtualCursorPosition.y * bounds.height
        )
    }

    func updateCursorLockMode() {
        updateVirtualTrackpadMode()
        let directTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        if cursorLockEnabled {
            longPressGesture.allowedTouchTypes = directTouchTypes
            updateMouseInputHandler()
            hoverGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPressGesture.isEnabled = true
            lockedPointerLastHoverLocation = nil
            startLockedCursorSmoothingIfNeeded()
            refreshLockedCursorIfNeeded(force: true)
            setLockedCursorVisible(lockedCursorVisible)
        } else {
            updateMouseInputHandler()
            hoverGesture.isEnabled = true
            lockedPointerPanGesture.isEnabled = false
            lockedPointerPressGesture.isEnabled = false
            lockedPointerButtonDown = false
            lockedPointerLastHoverLocation = nil
            stopLockedCursorSmoothing()
            setLockedCursorVisible(false)
        }
    }

    func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = isVisible
        lockedCursorView.isHidden = !(cursorLockEnabled && isVisible)
        updateLockedCursorViewPosition()
    }

    func updateLockedCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !lockedCursorView.isHidden else { return }
        let clamped = CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
        lockedCursorView.center = CGPoint(
            x: clamped.x * bounds.width,
            y: clamped.y * bounds.height
        )
    }

    func applyLockedCursorDelta(_ translation: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        lockedCursorPosition.x += translation.x / bounds.width
        lockedCursorPosition.y += translation.y / bounds.height
        lockedCursorPosition = CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
        noteLockedCursorLocalInput()
        setLockedCursorVisible(true)
        lastCursorPosition = CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
    }

    func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = position
        lockedCursorTargetVisible = isVisible
        guard cursorLockEnabled else { return }
        guard !isLockedCursorLocalInputActive() else { return }
        setLockedCursorVisible(isVisible)
        guard isVisible else { return }
        applyLockedCursorTargetStep()
    }

    private func applyLockedCursorTargetStep() {
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
        lastCursorPosition = CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
        updateLockedCursorViewPosition()
    }

    func noteLockedCursorLocalInput() {
        lockedCursorLocalInputTime = CACurrentMediaTime()
        lockedCursorTargetPosition = lockedCursorPosition
        lockedCursorTargetVisible = true
    }

    private func isLockedCursorLocalInputActive() -> Bool {
        let now = CACurrentMediaTime()
        return now - lockedCursorLocalInputTime < lockedCursorLocalHoldInterval
    }

    private func startLockedCursorSmoothingIfNeeded() {
        guard lockedCursorDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleLockedCursorSmoothing(_:)))
        displayLink.add(to: .main, forMode: .common)
        lockedCursorDisplayLink = displayLink
    }

    private func stopLockedCursorSmoothing() {
        lockedCursorDisplayLink?.invalidate()
        lockedCursorDisplayLink = nil
    }

    @objc
    private func handleLockedCursorSmoothing(_: CADisplayLink) {
        guard cursorLockEnabled else {
            stopLockedCursorSmoothing()
            return
        }
        guard !isLockedCursorLocalInputActive() else { return }
        guard lockedCursorTargetVisible else {
            setLockedCursorVisible(false)
            return
        }
        applyLockedCursorTargetStep()
    }

    private func updateMouseInputHandler() {
        #if canImport(GameController)
        if cursorLockEnabled,
           let mouse = GCMouse.mice().first,
           let input = mouse.mouseInput {
            if mouseInput !== input {
                mouseInput?.mouseMovedHandler = nil
                mouseInput = input
            }
            usesMouseInputDeltas = true
            input.mouseMovedHandler = { [weak self] (_: GCMouseInput, deltaX: Float, deltaY: Float) in
                Task { @MainActor [weak self] in
                    self?.handleLockedMouseDelta(deltaX: deltaX, deltaY: deltaY)
                }
            }
        } else {
            usesMouseInputDeltas = false
            mouseInput?.mouseMovedHandler = nil
            mouseInput = nil
        }
        if cursorLockEnabled {
            hoverGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPressGesture.isEnabled = true
        }
        #else
        usesMouseInputDeltas = false
        #endif
    }

    private func handleLockedMouseDelta(deltaX: Float, deltaY: Float) {
        guard cursorLockEnabled else { return }
        guard deltaX != 0 || deltaY != 0 else { return }
        _ = refreshModifiersForInput()
        let translation = CGPoint(x: CGFloat(deltaX), y: CGFloat(-deltaY))
        applyLockedCursorDelta(translation)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: lockedCursorPosition,
            modifiers: keyboardModifiers
        )
        if lockedPointerButtonDown {
            onInputEvent?(.mouseDragged(mouseEvent))
        } else {
            onInputEvent?(.mouseMoved(mouseEvent))
        }
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

        #if canImport(GameController)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidDisconnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidConnect(_:)),
            name: .GCMouseDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidDisconnect(_:)),
            name: .GCMouseDidDisconnect,
            object: nil
        )

        installHardwareKeyboardHandler()
        updateHardwareKeyboardPresence(GCKeyboard.coalesced != nil)
        #endif
    }

    @objc
    private func appWillResignActive() {
        // Clear all modifier and key repeat state when app loses focus
        stopAllKeyRepeats()
        resetAllModifiers()
        clearSoftwareKeyboardState()
        stopTouchScrollDeceleration()

        // Suspend rendering to avoid Metal GPU permission errors when backgrounded
        // iOS doesn't allow GPU work from background state
        metalView.suspendRendering()
    }

    @objc
    private func appDidBecomeActive() {
        if window != nil { metalView.resumeRendering() }

        sendModifierStateIfNeeded(force: true)
        #if canImport(GameController)
        installHardwareKeyboardHandler()
        updateHardwareKeyboardPresence(GCKeyboard.coalesced != nil)
        updateMouseInputHandler()
        #endif

        // Notify SwiftUI layer to trigger stream recovery
        onBecomeActive?()
    }

    #if canImport(GameController)
    @objc
    private func keyboardDidConnect(_: Notification) {
        installHardwareKeyboardHandler()
        refreshModifierStateFromHardware()
        updateHardwareKeyboardPresence(true)
    }

    @objc
    private func keyboardDidDisconnect(_: Notification) {
        HardwareKeyboardCoordinator.shared.handleKeyboardDisconnect()
        stopModifierRefresh()
        updateHardwareKeyboardPresence(false)

        // Always notify the host to clear modifiers on keyboard disconnect,
        // even if client-side modifiers are already empty (host may have drifted state)
        heldModifierKeys.removeAll()
        capsLockEnabled = false
        lastSentModifiers = []
        onInputEvent?(.flagsChanged([]))
    }

    @objc
    private func mouseDidConnect(_: Notification) {
        updateMouseInputHandler()
    }

    @objc
    private func mouseDidDisconnect(_: Notification) {
        updateMouseInputHandler()
    }
    #endif

    override public var canBecomeFirstResponder: Bool { true }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override public func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()
        updateVirtualCursorViewPosition()
        updateLockedCursorViewPosition()
    }

    override public func resignFirstResponder() -> Bool {
        // Clear all modifier and key repeat state when losing focus
        stopAllKeyRepeats()
        resetAllModifiers()
        return super.resignFirstResponder()
    }

    deinit {
        stopModifierRefresh()
        stopVirtualCursorDeceleration()
        stopTouchScrollDeceleration()
        stopLockedCursorSmoothing()
        #if canImport(GameController)
        MainActor.assumeIsolated {
            mouseInput?.mouseMovedHandler = nil
        }
        uninstallHardwareKeyboardHandler()
        #endif
        if let registeredCursorStreamID { MirageCursorUpdateRouter.shared.unregister(streamID: registeredCursorStreamID) }
        NotificationCenter.default.removeObserver(self)
    }
}

#if canImport(GameController)
@MainActor
private final class HardwareKeyboardCoordinator {
    static let shared = HardwareKeyboardCoordinator()

    private let views = NSHashTable<InputCapturingView>.weakObjects()
    private var installedKeyboardInputID: ObjectIdentifier?

    func register(_ view: InputCapturingView) {
        views.add(view)
        installHandlerIfNeeded()
    }

    func unregister(_ view: InputCapturingView) {
        views.remove(view)
    }

    func handleKeyboardDisconnect() {
        installedKeyboardInputID = nil
    }

    private func installHandlerIfNeeded() {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return }
        let inputID = ObjectIdentifier(keyboardInput)
        guard installedKeyboardInputID != inputID else { return }

        keyboardInput.keyChangedHandler = { [weak self] _, _, keyCode, _ in
            guard InputCapturingView.hardwareModifierKeyCodes.contains(keyCode) else { return }
            Task { @MainActor [weak self] in
                self?.handleModifierKeyChange()
            }
        }

        installedKeyboardInputID = inputID
    }

    private func handleModifierKeyChange() {
        for view in views.allObjects {
            guard view.window?.isKeyWindow == true, view.isFirstResponder else { continue }
            guard view.refreshModifierStateFromHardware() else { continue }

            if view.heldModifierKeys.isEmpty { view.stopModifierRefresh() } else {
                view.startModifierRefreshIfNeeded()
            }
        }
    }
}
#endif
#endif
