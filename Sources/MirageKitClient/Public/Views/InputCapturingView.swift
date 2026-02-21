//
//  InputCapturingView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import AVFAudio
import Speech
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

    /// Callback when a non-stylus direct touch is detected.
    public var onDirectTouchActivity: (() -> Void)?

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? {
        didSet {
            metalView.onDrawableMetricsChanged = onDrawableMetricsChanged
        }
    }

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize? {
        didSet {
            metalView.maxDrawableSize = maxDrawableSize
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

    /// Direct-touch behavior mode for iPad and visionOS clients.
    public var directTouchInputMode: MirageDirectTouchInputMode = .normal {
        didSet {
            guard directTouchInputMode != oldValue else { return }
            updateVirtualTrackpadMode()
        }
    }

    @available(*, deprecated, message: "Use directTouchInputMode instead.")
    public var usesVirtualTrackpad: Bool {
        get { directTouchInputMode == .dragCursor }
        set { directTouchInputMode = newValue ? .dragCursor : .normal }
    }

    /// Apple Pencil behavior mode.
    public var pencilInputMode: MiragePencilInputMode = .drawingTablet

    /// Monotonic toggle token for dictation requests.
    public var dictationToggleRequestID: UInt64 = 0 {
        didSet {
            guard dictationToggleRequestID != oldValue else { return }
            handleDictationToggleRequest(dictationToggleRequestID)
        }
    }

    /// Callback when dictation active state changes.
    public var onDictationStateChanged: ((Bool) -> Void)?

    /// Callback when dictation fails with a user-facing message.
    public var onDictationError: ((String) -> Void)?

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode = .best

    var isDictationActive: Bool = false
    var lastHandledDictationToggleRequestID: UInt64 = 0
    var dictationTask: Task<Void, Never>?
    var dictationFinalizeTask: Task<Void, Never>?
    var dictationResultTask: Task<Void, Never>?
    var dictationAudioEngine: AVAudioEngine?
    var dictationAnalyzer: AnyObject?
    var dictationAnalyzerInputSink: AnyObject?
    var dictationRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var dictationRecognitionTask: SFSpeechRecognitionTask?
    var dictationReservedLocale: Locale?
    var dictationLastCommittedText: String = ""

    // Cursor state from host
    var currentCursorType: MirageCursorType = .arrow
    var cursorIsVisible: Bool = true
    var cursorHiddenForTyping: Bool = false
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
    private var didEnterBackgroundSinceLastActive = false

    // Virtual cursor state (direct touch trackpad mode)
    private let virtualCursorView = InputCapturingView.makeCursorEffectView()
    private let lockedCursorView = InputCapturingView.makeCursorEffectView()
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
    var lockedPointerDraggedSinceDown: Bool = false
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
    var activePencilTouchID: ObjectIdentifier?
    var lastPencilPressure: CGFloat = 0
    #if os(iOS)
    private var pencilInteraction: UIPencilInteraction?
    #endif

    private static func makeCursorEffectView() -> UIVisualEffectView {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        #endif
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }

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

    func nextPrimaryClickCount(at location: CGPoint, timestamp: TimeInterval) -> Int {
        let timeSinceLastTap = timestamp - lastTapTime
        let distance = clickDistanceInPoints(from: location, to: lastTapLocation)

        guard lastCompletedClickCount > 0,
              timeSinceLastTap >= 0,
              timeSinceLastTap < Self.multiClickTimeThreshold,
              distance < Self.multiClickDistanceThresholdPoints else {
            return 1
        }

        return lastCompletedClickCount + 1
    }

    func commitPrimaryClick(at location: CGPoint, timestamp: TimeInterval, clickCount: Int) {
        lastTapTime = timestamp
        lastTapLocation = location
        lastCompletedClickCount = clickCount
    }

    func resetPrimaryClickTracking() {
        lastCompletedClickCount = 0
        lastTapTime = 0
    }

    func nextSecondaryClickCount(at location: CGPoint, timestamp: TimeInterval) -> Int {
        let timeSinceLastTap = timestamp - lastRightTapTime
        let distance = clickDistanceInPoints(from: location, to: lastRightTapLocation)

        guard lastCompletedRightClickCount > 0,
              timeSinceLastTap >= 0,
              timeSinceLastTap < Self.multiClickTimeThreshold,
              distance < Self.multiClickDistanceThresholdPoints else {
            return 1
        }

        return lastCompletedRightClickCount + 1
    }

    func commitSecondaryClick(at location: CGPoint, timestamp: TimeInterval, clickCount: Int) {
        lastRightTapTime = timestamp
        lastRightTapLocation = location
        lastCompletedRightClickCount = clickCount
    }

    func resetSecondaryClickTracking() {
        lastCompletedRightClickCount = 0
        lastRightTapTime = 0
    }

    func clickDistanceInPoints(from source: CGPoint, to target: CGPoint) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else {
            return .greatestFiniteMagnitude
        }

        let deltaX = (source.x - target.x) * bounds.width
        let deltaY = (source.y - target.y) * bounds.height
        return hypot(deltaX, deltaY)
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
    var lastCompletedClickCount: Int = 0
    var currentClickCount: Int = 0

    // Double-click detection state (right click)
    var lastRightTapTime: TimeInterval = 0
    var lastRightTapLocation: CGPoint = .zero
    var lastCompletedRightClickCount: Int = 0
    var currentRightClickCount: Int = 0

    /// Maximum time between taps to count as multi-click (in seconds)
    static let multiClickTimeThreshold: TimeInterval = 0.5
    /// Maximum distance between taps to count as multi-click (in view points)
    static let multiClickDistanceThresholdPoints: CGFloat = 12

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
    /// Active repeat session for intercepted UIKeyCommand shortcuts.
    var passthroughShortcutRepeatState: PassthroughShortcutRepeatState?
    /// Timer that polls physical key state for intercepted shortcut repeats.
    var passthroughShortcutRepeatTimer: Timer?
    /// Polling interval for intercepted shortcut repeat sessions.
    static let passthroughShortcutRepeatPollInterval: TimeInterval = 1.0 / 60.0

    struct PassthroughShortcutRepeatState {
        let keyCode: UInt16
        let input: String
        let modifiers: MirageModifierFlags
        let requiresShift: Bool
        var nextRepeatDeadline: TimeInterval
    }

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
        scrollPhysicsView!.onPencilTouchesBegan = { [weak self] touches, event in
            self?.handlePencilTouchesBegan(touches, event: event)
        }
        scrollPhysicsView!.onPencilTouchesMoved = { [weak self] touches, event in
            self?.handlePencilTouchesMoved(touches, event: event)
        }
        scrollPhysicsView!.onPencilTouchesEnded = { [weak self] touches, event in
            self?.handlePencilTouchesEnded(touches, event: event)
        }
        scrollPhysicsView!.onPencilTouchesCancelled = { [weak self] touches, event in
            self?.handlePencilTouchesCancelled(touches, event: event)
        }
        scrollPhysicsView!.onDirectTouchActivity = { [weak self] in
            self?.onDirectTouchActivity?()
        }

        // Enable user interaction
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true

        setupGestureRecognizers()
        setupPointerInteraction()
        setupVirtualCursorView()
        setupLockedCursorView()
        setupPencilInteraction()
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

    private func setupPencilInteraction() {
        #if os(iOS)
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        addInteraction(interaction)
        pencilInteraction = interaction
        #endif
    }

    func updateVirtualTrackpadMode() {
        let directTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let indirectTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        if cursorLockEnabled {
            longPressGesture.allowedTouchTypes = directTouchTypes
            scrollGesture.isEnabled = true
            directRotationGesture.isEnabled = true
            scrollPhysicsView?.directTouchScrollEnabled = false
            virtualCursorPanGesture.isEnabled = false
            virtualCursorTapGesture.isEnabled = false
            virtualCursorRightTapGesture.isEnabled = false
            virtualCursorLongPressGesture.isEnabled = false
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            setVirtualCursorVisible(false)
        } else {
            switch directTouchInputMode {
            case .dragCursor:
                longPressGesture.allowedTouchTypes = indirectTouchTypes
                scrollGesture.isEnabled = true
                directRotationGesture.isEnabled = true
                scrollPhysicsView?.directTouchScrollEnabled = false
                virtualCursorPanGesture.isEnabled = true
                virtualCursorTapGesture.isEnabled = true
                virtualCursorRightTapGesture.isEnabled = true
                virtualCursorLongPressGesture.isEnabled = true
                lastCursorPosition = virtualCursorPosition
                setVirtualCursorVisible(true)
            case .normal:
                longPressGesture.allowedTouchTypes = directTouchTypes + indirectTouchTypes
                scrollGesture.isEnabled = true
                directRotationGesture.isEnabled = true
                scrollPhysicsView?.directTouchScrollEnabled = false
                virtualCursorPanGesture.isEnabled = false
                virtualCursorTapGesture.isEnabled = false
                virtualCursorRightTapGesture.isEnabled = false
                virtualCursorLongPressGesture.isEnabled = false
                virtualDragActive = false
                stopVirtualCursorDeceleration()
                setVirtualCursorVisible(false)
            case .pencilBased:
                longPressGesture.allowedTouchTypes = indirectTouchTypes
                scrollGesture.isEnabled = false
                directRotationGesture.isEnabled = false
                scrollPhysicsView?.directTouchScrollEnabled = true
                virtualCursorPanGesture.isEnabled = false
                virtualCursorTapGesture.isEnabled = false
                virtualCursorRightTapGesture.isEnabled = false
                virtualCursorLongPressGesture.isEnabled = false
                virtualDragActive = false
                stopVirtualCursorDeceleration()
                setVirtualCursorVisible(false)
            }
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
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func updateLockedCursorViewVisibility() {
        let shouldShow = cursorLockEnabled && lockedCursorVisible && !cursorHiddenForTyping
        lockedCursorView.isHidden = !shouldShow
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
        revealCursorAfterPointerMovement()
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
        // Clear modifiers and transient input state when app loses focus.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Suspend rendering only when the app actually enters background.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Handle app returning to active state.
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
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        activePencilTouchID = nil
        isDragging = false
        lastPencilPressure = 0
        clearSoftwareKeyboardState()
        stopDictation()
        stopTouchScrollDeceleration()
    }

    @objc
    private func appDidEnterBackground() {
        didEnterBackgroundSinceLastActive = true
        // iOS does not allow foreground rendering work while backgrounded.
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

        let shouldRequestRecovery = didEnterBackgroundSinceLastActive || metalView.hasDisplayLayerFailure
        didEnterBackgroundSinceLastActive = false
        if shouldRequestRecovery { onBecomeActive?() }
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
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        activePencilTouchID = nil
        isDragging = false
        lastPencilPressure = 0
        return super.resignFirstResponder()
    }

    // MARK: - Pencil Input

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesBegan(touchSplit.stylus, event: event)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesBegan(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesMoved(touchSplit.stylus, event: event)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesMoved(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesEnded(touchSplit.stylus, event: event)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesEnded(touchSplit.nonStylus, with: event)
        }
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchSplit = splitStylusTouches(touches)
        handlePencilTouchesCancelled(touchSplit.stylus, event: event)

        if !touchSplit.nonStylus.isEmpty {
            super.touchesCancelled(touchSplit.nonStylus, with: event)
        }
    }

    func splitStylusTouches(_ touches: Set<UITouch>) -> (stylus: Set<UITouch>, nonStylus: Set<UITouch>) {
        var stylusTouches = Set<UITouch>()
        var nonStylusTouches = Set<UITouch>()

        for touch in touches {
            if isStylusTouch(touch) {
                stylusTouches.insert(touch)
            } else {
                nonStylusTouches.insert(touch)
            }
        }

        return (stylusTouches, nonStylusTouches)
    }

    func isStylusTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        guard touch.type == .direct else { return false }

        // Some iPadOS builds report Pencil contact as direct while still exposing
        // stylus-only metrics. Prefer those metrics over touch.type for routing.
        if touch.maximumPossibleForce > 1.0 { return true }
        if touch.force > 1.0 { return true }
        if touch.estimatedProperties.contains(.force) ||
            touch.estimatedProperties.contains(.azimuth) ||
            touch.estimatedProperties.contains(.altitude) {
            return true
        }
        if touch.estimatedPropertiesExpectingUpdates.contains(.force) ||
            touch.estimatedPropertiesExpectingUpdates.contains(.azimuth) ||
            touch.estimatedPropertiesExpectingUpdates.contains(.altitude) {
            return true
        }
        return false
    }

    private func handlePencilTouchesBegan(_ touches: Set<UITouch>, event _: UIEvent?) {
        guard !touches.isEmpty else { return }
        if let touch = touches.first, activePencilTouchID == nil {
            activePencilTouchID = ObjectIdentifier(touch)
            sendPencilDown(for: touch)
        }
    }

    private func handlePencilTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard !touches.isEmpty else { return }
        guard let activePencilTouchID else { return }
        if let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            sendPencilMovedSamples(for: touch, event: event)
        }
    }

    private func handlePencilTouchesEnded(_ touches: Set<UITouch>, event _: UIEvent?) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            sendPencilUp(for: touch)
            self.activePencilTouchID = nil
        }
    }

    private func handlePencilTouchesCancelled(_ touches: Set<UITouch>, event _: UIEvent?) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            sendPencilUp(for: touch)
            self.activePencilTouchID = nil
        }
    }

    func sendPencilDown(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let modifiers = currentPencilModifiers()

        if cursorLockEnabled {
            lockedCursorPosition = location
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            updateLockedCursorViewPosition()
        }

        if usesVirtualTrackpad {
            setVirtualCursorVisible(false)
            updateVirtualCursorPosition(location, updateVisibility: false)
        }

        lastCursorPosition = location
        isDragging = true

        let pressure = normalizedPencilPressure(for: touch)
        let stylus = stylusEvent(from: touch)
        let mouseEvent = pointerEventForPencil(
            location: location,
            modifiers: modifiers,
            pressure: pressure,
            stylus: stylus,
            clickCount: 1
        )
        onInputEvent?(.mouseDown(mouseEvent))
    }

    func sendPencilMovedSamples(for touch: UITouch, event: UIEvent?) {
        let modifiers = currentPencilModifiers()
        let samples = event?.coalescedTouches(for: touch) ?? [touch]

        for sample in samples {
            let rawLocation = sample.preciseLocation(in: self)
            let location = normalizedLocation(rawLocation)

            if cursorLockEnabled {
                lockedCursorPosition = location
                noteLockedCursorLocalInput()
                setLockedCursorVisible(true)
                updateLockedCursorViewPosition()
            }

            if usesVirtualTrackpad {
                setVirtualCursorVisible(false)
                updateVirtualCursorPosition(location, updateVisibility: false)
            }

            lastCursorPosition = location
            let pressure = normalizedPencilPressure(for: sample)
            let stylus = stylusEvent(from: sample)
            let mouseEvent = pointerEventForPencil(
                location: location,
                modifiers: modifiers,
                pressure: pressure,
                stylus: stylus
            )
            onInputEvent?(.mouseDragged(mouseEvent))
        }
    }

    func sendPencilUp(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let modifiers = currentPencilModifiers()
        let stylus = stylusEvent(from: touch)
        let mouseEvent = pointerEventForPencil(
            location: location,
            modifiers: modifiers,
            pressure: 0,
            stylus: stylus,
            clickCount: 1
        )
        onInputEvent?(.mouseUp(mouseEvent))
        isDragging = false
        lastPencilPressure = 0
    }

    func resolvedPencilSecondaryClickLocation(hoverLocation: CGPoint?) -> CGPoint {
        if let hoverLocation {
            let location = normalizedLocation(hoverLocation)
            if cursorLockEnabled {
                lockedCursorPosition = location
                noteLockedCursorLocalInput()
                setLockedCursorVisible(true)
                updateLockedCursorViewPosition()
            }
            if usesVirtualTrackpad {
                setVirtualCursorVisible(false)
                updateVirtualCursorPosition(location, updateVisibility: false)
            }
            lastCursorPosition = location
            return location
        }

        if cursorLockEnabled { return lockedCursorPosition }
        if let lastCursorPosition { return lastCursorPosition }
        if usesVirtualTrackpad { return virtualCursorPosition }
        return CGPoint(x: 0.5, y: 0.5)
    }

    func sendPencilSecondaryClick(at location: CGPoint) {
        let now = CACurrentMediaTime()
        let clickCount = nextSecondaryClickCount(at: location, timestamp: now)
        currentRightClickCount = clickCount

        let modifiers = currentPencilModifiers()
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: clickCount,
            modifiers: modifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
        commitSecondaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    func currentPencilModifiers() -> MirageModifierFlags {
        _ = refreshModifiersForInput()
        let snapshot = keyboardModifiers
        sendModifierSnapshotIfNeeded(snapshot)
        return snapshot
    }

    func normalizedPencilPressure(for touch: UITouch) -> CGFloat {
        let maxForce = touch.maximumPossibleForce
        if maxForce > 0 {
            let normalized = min(max(touch.force / maxForce, 0), 1)
            if normalized > 0 {
                lastPencilPressure = normalized
                return normalized
            }

            if isDragging, lastPencilPressure > 0 { return lastPencilPressure }
            return 0.01
        }

        if isDragging, lastPencilPressure > 0 { return lastPencilPressure }
        return 1
    }

    func stylusEvent(from touch: UITouch) -> MirageStylusEvent {
        let altitude = min(max(touch.altitudeAngle, 0), .pi / 2)
        let azimuth = touch.azimuthAngle(in: self)
        let azimuthUnitVector = touch.azimuthUnitVector(in: self)
        let tiltMagnitude = min(max(cos(altitude), 0), 1)
        let tiltX = min(max(azimuthUnitVector.dx * tiltMagnitude, -1), 1)
        let tiltY = min(max(azimuthUnitVector.dy * tiltMagnitude, -1), 1)
        let rollAngle: CGFloat?
        #if os(iOS)
        if #available(iOS 17.5, *) {
            rollAngle = touch.rollAngle
        } else {
            rollAngle = nil
        }
        #else
        rollAngle = nil
        #endif

        return MirageStylusEvent(
            altitudeAngle: altitude,
            azimuthAngle: azimuth,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: rollAngle
        )
    }

    func stylusHoverEvent(from gesture: UIHoverGestureRecognizer) -> MirageStylusEvent? {
        guard gesture.zOffset > 0 else { return nil }

        let altitude = min(max(gesture.altitudeAngle, 0), .pi / 2)
        let azimuth = gesture.azimuthAngle(in: self)
        let azimuthUnitVector = gesture.azimuthUnitVector(in: self)
        let tiltMagnitude = min(max(cos(altitude), 0), 1)
        let tiltX = min(max(azimuthUnitVector.dx * tiltMagnitude, -1), 1)
        let tiltY = min(max(azimuthUnitVector.dy * tiltMagnitude, -1), 1)
        let rollAngle: CGFloat?
        #if os(iOS)
        if #available(iOS 17.5, *) {
            rollAngle = gesture.rollAngle
        } else {
            rollAngle = nil
        }
        #else
        rollAngle = nil
        #endif

        return MirageStylusEvent(
            altitudeAngle: altitude,
            azimuthAngle: azimuth,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: rollAngle,
            zOffset: gesture.zOffset,
            isHovering: true
        )
    }

    func pointerEventForPencil(
        location: CGPoint,
        modifiers: MirageModifierFlags,
        pressure: CGFloat,
        stylus: MirageStylusEvent?,
        clickCount: Int = 1
    ) -> MirageMouseEvent {
        return MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: clickCount,
            modifiers: modifiers,
            pressure: pressure,
            stylus: stylus
        )
    }

    deinit {
        stopDictation()
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

#if os(iOS)
extension InputCapturingView: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    public func pencilInteraction(
        _: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .ended else { return }
        let location = resolvedPencilSecondaryClickLocation(hoverLocation: squeeze.hoverPose?.location)
        sendPencilSecondaryClick(at: location)
    }
}
#endif

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
