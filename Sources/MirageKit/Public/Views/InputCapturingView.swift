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
    public override var safeAreaInsets: UIEdgeInsets { .zero }

    /// Callback for input events - set by the SwiftUI representable's coordinator
    public var onInputEvent: ((MirageInputEvent) -> Void)? {
        didSet {
            if onInputEvent != nil {
                sendModifierStateIfNeeded(force: true)
            }
        }
    }

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? {
        didSet {
            metalView.onDrawableMetricsChanged = onDrawableMetricsChanged
        }
    }

    /// Callback when the view decides on a refresh rate override (60 or 120).
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
            if let previousID, previousID != streamID {
                MirageCursorUpdateRouter.shared.unregister(streamID: previousID)
            }
            registeredCursorStreamID = streamID
            if let streamID {
                MirageCursorUpdateRouter.shared.register(view: self, for: streamID)
            }
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

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool = false

    // Cursor state from host
    var currentCursorType: MirageCursorType = .arrow
    var cursorIsVisible: Bool = true
    var pointerInteraction: UIPointerInteraction?
    var cursorSequence: UInt64 = 0
    var lastCursorRefreshTime: CFTimeInterval = 0
    let cursorRefreshInterval: CFTimeInterval = 1.0 / 30.0
    // nonisolated(unsafe) allows access from deinit for cleanup
    private nonisolated(unsafe) var registeredCursorStreamID: StreamID?

    // Gesture recognizers
    var tapGesture: UITapGestureRecognizer!
    var panGesture: UIPanGestureRecognizer!
    var scrollGesture: UIPanGestureRecognizer!
    var hoverGesture: UIHoverGestureRecognizer!
    var rightClickGesture: UITapGestureRecognizer!

    // Track drag state
    var isDragging = false
    var lastPanLocation: CGPoint = .zero

    // Track last cursor position for scroll events (normalized 0-1)
    var lastCursorPosition: CGPoint?

    // Track keyboard modifier state - single source of truth
    // Gesture events read modifiers directly from gesture.modifierFlags at event time
    var heldModifierKeys: Set<UIKeyboardHIDUsage> = []
    var capsLockEnabled: Bool = false
    var lastSentModifiers: MirageModifierFlags = []
    var modifierRefreshTask: Task<Void, Never>?
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
        .capsLock
    ]
#endif

    /// Get current modifier state from held keyboard keys
    var keyboardModifiers: MirageModifierFlags {
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

    func sendModifierStateIfNeeded(force: Bool = false) {
        let modifiers = keyboardModifiers
        guard force || modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
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
                if let primaryKey = keys.first {
                    newHeldKeys.insert(primaryKey)
                }
            } else {
                newHeldKeys.formUnion(existingKeys)
            }
        }

        let newCapsLockEnabled = flags.contains(.capsLock)

        guard newHeldKeys != heldModifierKeys || newCapsLockEnabled != capsLockEnabled else { return }
        heldModifierKeys = newHeldKeys
        capsLockEnabled = newCapsLockEnabled
        sendModifierStateIfNeeded(force: true)
    }

    /// Clear all held modifiers with a snapshot update
    func resetAllModifiers() {
        guard !heldModifierKeys.isEmpty || capsLockEnabled else { return }
        stopModifierRefresh()
        heldModifierKeys.removeAll()
        capsLockEnabled = false
        sendModifierStateIfNeeded(force: true)
    }

    func startModifierRefreshIfNeeded() {
        guard modifierRefreshTask == nil else { return }
        modifierRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.refreshModifierStateFromHardware() else {
                    self.modifierRefreshTask = nil
                    return
                }

                if self.heldModifierKeys.isEmpty {
                    self.modifierRefreshTask = nil
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

    @discardableResult
    func refreshModifierStateFromHardware() -> Bool {
#if canImport(GameController)
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        var refreshedKeys: Set<UIKeyboardHIDUsage> = []

        if keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true {
            refreshedKeys.insert(.keyboardLeftShift)
        }
        if keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true {
            refreshedKeys.insert(.keyboardRightShift)
        }
        if keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true {
            refreshedKeys.insert(.keyboardLeftControl)
        }
        if keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true {
            refreshedKeys.insert(.keyboardRightControl)
        }
        if keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true {
            refreshedKeys.insert(.keyboardLeftAlt)
        }
        if keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true {
            refreshedKeys.insert(.keyboardRightAlt)
        }
        if keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true {
            refreshedKeys.insert(.keyboardLeftGUI)
        }
        if keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true {
            refreshedKeys.insert(.keyboardRightGUI)
        }

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

    // Scroll physics capturing view for native trackpad momentum/bounce
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
        .keyboardCapsLock: .capsLock
    ]

    /// Preferred key codes for modifier flag resync (preserve left/right when possible)
    static let modifierFlagToKeys: [(flag: MirageModifierFlags, keys: [UIKeyboardHIDUsage])] = [
        (.shift, [.keyboardLeftShift, .keyboardRightShift]),
        (.control, [.keyboardLeftControl, .keyboardRightControl]),
        (.option, [.keyboardLeftAlt, .keyboardRightAlt]),
        (.command, [.keyboardLeftGUI, .keyboardRightGUI])
    ]

    // Key repeat handling
    /// Active key repeat timers keyed by HID usage code
    var keyRepeatTimers: [UIKeyboardHIDUsage: Timer] = [:]
    /// Held key press references for generating repeat events
    var heldKeyPresses: [UIKeyboardHIDUsage: UIPress] = [:]
    /// Initial delay before key repeat starts (matches macOS default)
    static let keyRepeatInitialDelay: TimeInterval = 0.5
    /// Interval between repeat events (matches macOS default ~30 chars/sec)
    static let keyRepeatInterval: TimeInterval = 0.033

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

        installHardwareKeyboardHandler()
#endif
    }

    @objc private func appWillResignActive() {
        // Clear all modifier and key repeat state when app loses focus
        stopAllKeyRepeats()
        resetAllModifiers()

        // Suspend rendering to avoid Metal GPU permission errors when backgrounded
        // iOS doesn't allow GPU work from background state
        metalView.suspendRendering()
    }

    @objc private func appDidBecomeActive() {
        if window != nil {
            metalView.resumeRendering()
        }

        sendModifierStateIfNeeded(force: true)
#if canImport(GameController)
        installHardwareKeyboardHandler()
#endif

        // Notify SwiftUI layer to trigger stream recovery
        onBecomeActive?()
    }

#if canImport(GameController)
    @objc private func keyboardDidConnect(_ notification: Notification) {
        installHardwareKeyboardHandler()
        refreshModifierStateFromHardware()
    }

    @objc private func keyboardDidDisconnect(_ notification: Notification) {
        HardwareKeyboardCoordinator.shared.handleKeyboardDisconnect()
        stopModifierRefresh()
        resetAllModifiers()
    }
#endif

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

    deinit {
        stopModifierRefresh()
#if canImport(GameController)
        uninstallHardwareKeyboardHandler()
#endif
        if let registeredCursorStreamID {
            MirageCursorUpdateRouter.shared.unregister(streamID: registeredCursorStreamID)
        }
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

            if view.heldModifierKeys.isEmpty {
                view.stopModifierRefresh()
            } else {
                view.startModifierRefreshIfNeeded()
            }
        }
    }
}
#endif
#endif
