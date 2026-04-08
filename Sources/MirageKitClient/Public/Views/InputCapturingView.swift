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
            guard onInputEvent != nil else { return }
            if oldValue == nil {
                sendModifierStateIfNeeded(force: true)
                return
            }
            suppressedOnInputEventRebindCount &+= 1
            logOnInputEventRebindSuppressionIfNeeded()
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

    /// Callback when the platform container/window bounds change.
    public var onContainerSizeChanged: ((CGSize) -> Void)? {
        didSet {
            if onContainerSizeChanged != nil {
                reportContainerSizeIfChanged(force: true)
            }
        }
    }

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize? {
        didSet {
            metalView.maxDrawableSize = maxDrawableSize
        }
    }

    /// Whether the stream should present locally using aspect fit.
    public var prefersLocalAspectFitPresentation: Bool = false {
        didSet {
            metalView.prefersLocalAspectFitPresentation = prefersLocalAspectFitPresentation
        }
    }

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)? {
        didSet {
            metalView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        }
    }

    /// Active vs passive presentation tier for local rendering cadence.
    public var presentationTier: StreamPresentationTier = .activeLive {
        didSet {
            metalView.streamPresentationTier = presentationTier
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
            lockedCursorConfirmedHostPosition = nil
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

    /// Cursor position store for desktop cursor sync.
    public var cursorPositionStore: MirageClientCursorPositionStore? {
        didSet {
            lockedCursorSequence = 0
            lockedCursorConfirmedHostPosition = nil
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

    /// Whether locked desktop cursor input may move beyond the streamed view bounds.
    public var allowsExtendedCursorBounds: Bool = false {
        didSet {
            guard allowsExtendedCursorBounds != oldValue else { return }
            lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
            lockedCursorTargetPosition = resolvedLockedCursorEventPosition(lockedCursorTargetPosition)
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether cursor lock can be recaptured after a temporary local unlock.
    public var canRecaptureCursorLock: Bool = false

    /// Callback when unmodified Escape should temporarily unlock cursor capture.
    public var onCursorLockEscapeRequested: (() -> Void)?

    /// Callback when the next click/tap should recapture cursor capture.
    public var onCursorLockRecaptureRequested: (() -> Void)?

    /// Whether Mirage should render its synthetic local cursor presentation.
    public var syntheticCursorEnabled: Bool = true {
        didSet {
            guard syntheticCursorEnabled != oldValue else { return }
            updateVirtualTrackpadMode()
            updateLockedCursorViewVisibility()
            pointerInteraction?.invalidate()
            refreshCursorUpdates(force: true)
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

    var usesVirtualTrackpad: Bool { directTouchInputMode == .dragCursor }
    var usesVisibleVirtualCursor: Bool { usesVirtualTrackpad && !cursorLockEnabled }
    var usesLockedTrackpadCursor: Bool { usesVirtualTrackpad && cursorLockEnabled }

    /// Configured actions for Apple Pencil hardware gestures.
    public var pencilGestureConfiguration: MiragePencilGestureConfiguration = .default

    /// Client-reserved shortcuts handled locally instead of being forwarded to the host.
    public var clientShortcuts: [MirageClientShortcut] = []

    /// Callback when a client-reserved shortcut is triggered.
    public var onClientShortcut: ((MirageClientShortcut) -> Void)?

    /// Unified actions (navigation, local, custom) that can be triggered by shortcuts.
    public var actions: [MirageAction] = []

    /// Callback when a unified action is triggered (by shortcut, gesture, or control bar).
    public var onActionTriggered: ((MirageAction) -> Void)?

    /// Callback when a Pencil gesture maps to a client-side action.
    public var onPencilGestureAction: ((MiragePencilGestureAction) -> Void)?

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

    /// Callback when UIKit resolves pointer-lock availability for the current scene.
    public var onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode = .best

    /// Dictation language selection. System default follows the current device locale.
    public var dictationLocalePreference: MirageDictationLocalePreference = .system

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
    var dictationResultBuffer = MirageDictationResultBuffer()

    // Cursor state from host
    var currentCursorType: MirageCursorType = .arrow
    var cursorIsVisible: Bool = true
    var cursorHiddenForTyping: Bool = false
    var pointerInteraction: UIPointerInteraction?
    var cursorSequence: UInt64 = 0
    var lastCursorRefreshTime: CFTimeInterval = 0
    let cursorRefreshInterval: CFTimeInterval = MirageInteractionCadence.frameInterval120Seconds
    var lockedCursorSequence: UInt64 = 0
    var lastLockedCursorRefreshTime: CFTimeInterval = 0
    let lockedCursorRefreshInterval: CFTimeInterval = MirageInteractionCadence.frameInterval120Seconds
    // nonisolated(unsafe) allows access from deinit for cleanup
    private nonisolated(unsafe) var registeredCursorStreamID: StreamID?
    private(set) var hardwareKeyboardPresent: Bool = false
    private var didResignActiveSinceLastActivation = false
    private var didEnterBackgroundSinceLastActive = false

    // Virtual cursor state (direct touch trackpad mode)
    private let virtualCursorView = UIImageView()
    private let lockedCursorView = UIImageView()
    var virtualCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var virtualCursorVelocity: CGPoint = .zero
    var virtualCursorDecelerationLink: CADisplayLink?
    var virtualDragActive: Bool = false
    var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorConfirmedHostPosition: CGPoint?
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
    var suppressEscapeKeyUpForCursorUnlock = false
    var swallowingLongPressForCursorRecapture = false
    var swallowingVirtualCursorLongPressForCursorRecapture = false
    var usesMouseInputDeltas: Bool = false
    var pointerLockActive: Bool = false {
        didSet {
            guard pointerLockActive != oldValue else { return }
            handlePointerLockStateChange()
        }
    }
    #if canImport(GameController)
    private var mouseInput: GCMouseInput?
    #endif
    var touchScrollDecelerationVelocity: CGPoint = .zero
    var touchScrollDecelerationLink: CADisplayLink?
    var touchScrollDecelerationLocation: CGPoint = .zero
    var activePencilTouchID: ObjectIdentifier?
    var pencilButtonDown = false
    var pencilTapEligible = false
    var pencilTouchStartLocation: CGPoint = .zero
    var pencilCurrentLocation: CGPoint = .zero
    var pencilCurrentStylus: MirageStylusEvent?
    var pencilLongPressTask: Task<Void, Never>?
    var lastPencilPressure: CGFloat = 0
    #if os(iOS)
    private var pencilInteraction: UIPencilInteraction?
    #endif


    /// Software keyboard state
    public var softwareKeyboardVisible: Bool = false {
        didSet {
            guard softwareKeyboardVisible != oldValue else { return }
            updateSoftwareKeyboardVisibility()
        }
    }

    private var lastReportedContainerSize: CGSize = .zero

    var softwareKeyboardField: SoftwareKeyboardTextField?
    var softwareKeyboardAccessoryView: SoftwareKeyboardAccessoryView?
    var isSoftwareKeyboardShown: Bool = false
    var softwareHeldModifiers: MirageModifierFlags = []
    var suppressedOnInputEventRebindCount: UInt64 = 0
    var lastOnInputEventRebindLogTime: CFAbsoluteTime = 0
    let onInputEventRebindLogInterval: CFTimeInterval = 5.0
    var softwareModifierSyncRequestCount: UInt64 = 0
    var softwareModifierVisualUpdateCount: UInt64 = 0
    var lastSoftwareModifierSyncLogTime: CFAbsoluteTime = 0
    let softwareModifierSyncLogInterval: CFTimeInterval = 5.0

    // Gesture recognizers
    var longPressGesture: UILongPressGestureRecognizer!
    var scrollGesture: UIPanGestureRecognizer!
    var hoverGesture: UIHoverGestureRecognizer!
    var rightClickGesture: UITapGestureRecognizer!
    var directTapGesture: UITapGestureRecognizer!
    var directLongPressGesture: UILongPressGestureRecognizer!
    var directTwoFingerTapGesture: UITapGestureRecognizer!
    var directTwoFingerDragGesture: UIPanGestureRecognizer!
    var navigationSwipeGestures: [UISwipeGestureRecognizer] = []

    /// Whether two-finger swipe gestures trigger navigation actions.
    public var navigationGesturesEnabled: Bool = true
    var virtualCursorPanGesture: UIPanGestureRecognizer!
    var virtualCursorTapGesture: UITapGestureRecognizer!
    var virtualCursorRightTapGesture: UITapGestureRecognizer!
    var virtualCursorLongPressGesture: UILongPressGestureRecognizer!
    var lockedPointerPanGesture: UIPanGestureRecognizer!
    var lockedPointerPressGesture: UILongPressGestureRecognizer!

    // Track drag state
    var isDragging = false
    var lastPanLocation: CGPoint = .zero
    var longPressButtonDown = false
    var longPressCancelledForMultiTouch = false
    var directLongPressButtonDown = false
    var directTwoFingerDragButtonDown = false
    var swallowingDirectLongPressForCursorRecapture = false
    var swallowingDirectTwoFingerDragForCursorRecapture = false

    /// Track last cursor position for scroll events in stream space.
    /// Secondary desktop cursor-lock travel may temporarily exceed `0...1`.
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
    /// Key codes currently claimed by GCKeyboard (modifier+key combos).
    /// Used to deduplicate against pressesBegan/pressesEnded which may fire for the same event.
    var gcClaimedKeyCodes: Set<GCKeyCode> = []
    /// HID key codes currently owned by a client-reserved shortcut path.
    /// These key releases should not emit an additional raw key-up event.
    var clientShortcutClaimedKeyCodes: Set<UIKeyboardHIDUsage> = []
    /// HID key codes currently owned by the synthesized intercepted-shortcut path.
    /// These key releases should not emit an additional raw key-up event.
    var passthroughClaimedKeyCodes: Set<UIKeyboardHIDUsage> = []
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

    func recordSoftwareModifierSyncResult(visualUpdates: Int) {
        softwareModifierSyncRequestCount &+= 1
        if visualUpdates > 0 {
            softwareModifierVisualUpdateCount &+= UInt64(visualUpdates)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if lastSoftwareModifierSyncLogTime == 0 {
            lastSoftwareModifierSyncLogTime = now
            return
        }
        guard now - lastSoftwareModifierSyncLogTime >= softwareModifierSyncLogInterval else {
            return
        }
        let requests = softwareModifierSyncRequestCount
        let visualUpdates = softwareModifierVisualUpdateCount
        softwareModifierSyncRequestCount = 0
        softwareModifierVisualUpdateCount = 0
        lastSoftwareModifierSyncLogTime = now
        MirageLogger.client(
            "Software modifier sync stats: requests=\(requests), visualUpdates=\(visualUpdates), windowSeconds=5"
        )
    }

    func logOnInputEventRebindSuppressionIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastOnInputEventRebindLogTime == 0 {
            lastOnInputEventRebindLogTime = now
            return
        }
        guard now - lastOnInputEventRebindLogTime >= onInputEventRebindLogInterval else {
            return
        }
        let suppressedCount = suppressedOnInputEventRebindCount
        suppressedOnInputEventRebindCount = 0
        lastOnInputEventRebindLogTime = now
        MirageLogger.client(
            "Input callback rebind suppressed: count=\(suppressedCount), windowSeconds=5"
        )
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
        #if canImport(GameController)
        gcClaimedKeyCodes.removeAll()
        clientShortcutClaimedKeyCodes.removeAll()
        passthroughClaimedKeyCodes.removeAll()
        #endif
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
                    try await Task.sleep(for: Self.modifierRefreshPollInterval)
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
    /// Hold duration before direct touch or Pencil contact becomes a drag.
    static let dragActivationDuration: Duration = .milliseconds(250)
    /// Maximum drift allowed before long-press drag activation cancels.
    static let dragActivationMovementThresholdPoints: CGFloat = 10

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
    /// Most recent client-reserved shortcut dispatched through a UIKit command/action path.
    var lastClientShortcutDispatch: ClientShortcutDispatch?
    /// Most recent intercepted shortcut forwarded through a UIKit command/action path.
    var lastPassthroughShortcutDispatch: PassthroughShortcutDispatch?
    /// Polling interval for intercepted shortcut repeat sessions.
    static let passthroughShortcutRepeatPollInterval: TimeInterval = 1.0 / 60.0
    /// Window for suppressing duplicate delivery when UIKit invokes both keyCommand and
    /// responder edit-action paths for the same physical shortcut press.
    static let passthroughShortcutDuplicateSuppressionWindow: CFTimeInterval = 0.05
    /// Polling cadence for hardware modifier reconciliation while modifiers are held.
    static let modifierRefreshPollInterval: Duration = .milliseconds(100)

    struct PassthroughShortcutRepeatState {
        let keyCode: UInt16
        let input: String
        let modifiers: MirageModifierFlags
        let requiresShift: Bool
        var nextRepeatDeadline: TimeInterval
    }

    enum ClientShortcutDispatchSource {
        case hardwareKey
        case keyCommand
        case responderAction
    }

    struct ClientShortcutDispatch {
        let shortcut: MirageClientShortcut
        let source: ClientShortcutDispatchSource
        let timestamp: CFAbsoluteTime
    }

    enum PassthroughShortcutDispatchSource {
        case hardwareKey
        case keyCommand
        case responderAction
    }

    struct PassthroughShortcutDispatch {
        let shortcut: MirageInterceptedShortcut
        let source: PassthroughShortcutDispatchSource
        let timestamp: CFAbsoluteTime
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
                location: cursorLockEnabled ? lockedCursorPosition : lastCursorPosition,
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
        scrollPhysicsView!.onDirectTouchLocationChanged = { [weak self] rawLocation in
            self?.handleDirectTouchLocationChange(rawLocation)
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
        virtualCursorView.contentMode = .scaleAspectFit
        virtualCursorView.isUserInteractionEnabled = false
        virtualCursorView.isHidden = true
        updateCursorImage()
        addSubview(virtualCursorView)
    }

    private func setupLockedCursorView() {
        lockedCursorView.contentMode = .scaleAspectFit
        lockedCursorView.isUserInteractionEnabled = false
        lockedCursorView.isHidden = true
        updateCursorImage()
        addSubview(lockedCursorView)
    }

    func updateCursorImage() {
        let cursorType = currentCursorType
        let image = UIImage(named: cursorType.cursorImageName, in: .module, compatibleWith: nil)
        for view in [virtualCursorView, lockedCursorView] {
            view.image = image
            if let image {
                view.bounds = CGRect(
                    origin: .zero,
                    size: image.size
                )
            }
        }
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
        let indirectTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]

        if usesLockedTrackpadCursor {
            longPressGesture.allowedTouchTypes = indirectTouchTypes
            scrollGesture.isEnabled = true
            directRotationGesture.isEnabled = true
            scrollPhysicsView?.directTouchScrollEnabled = false
            directTapGesture.isEnabled = false
            directLongPressGesture.isEnabled = false
            directTwoFingerTapGesture.isEnabled = false
            directTwoFingerDragGesture.isEnabled = false
            virtualCursorPanGesture.isEnabled = true
            virtualCursorTapGesture.isEnabled = true
            virtualCursorRightTapGesture.isEnabled = true
            virtualCursorLongPressGesture.isEnabled = true
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            lastCursorPosition = lockedCursorPosition
            setVirtualCursorVisible(false)
        } else if cursorLockEnabled {
            longPressGesture.allowedTouchTypes = indirectTouchTypes
            scrollGesture.isEnabled = false
            directRotationGesture.isEnabled = false
            scrollPhysicsView?.directTouchScrollEnabled = true
            directTapGesture.isEnabled = true
            directLongPressGesture.isEnabled = true
            directTwoFingerTapGesture.isEnabled = true
            directTwoFingerDragGesture.isEnabled = true
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
                directTapGesture.isEnabled = false
                directLongPressGesture.isEnabled = false
                directTwoFingerTapGesture.isEnabled = false
                directTwoFingerDragGesture.isEnabled = false
                virtualCursorPanGesture.isEnabled = true
                virtualCursorTapGesture.isEnabled = true
                virtualCursorRightTapGesture.isEnabled = true
                virtualCursorLongPressGesture.isEnabled = true
                lastCursorPosition = virtualCursorPosition
                setVirtualCursorVisible(true)
            case .normal:
                longPressGesture.allowedTouchTypes = indirectTouchTypes
                scrollGesture.isEnabled = false
                directRotationGesture.isEnabled = false
                scrollPhysicsView?.directTouchScrollEnabled = true
                directTapGesture.isEnabled = true
                directLongPressGesture.isEnabled = true
                directTwoFingerTapGesture.isEnabled = true
                directTwoFingerDragGesture.isEnabled = true
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
        guard usesVisibleVirtualCursor else {
            virtualCursorView.isHidden = true
            return
        }
        virtualCursorView.isHidden = !syntheticCursorEnabled || !isVisible
        updateVirtualCursorViewPosition()
    }

    func updateVirtualCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !virtualCursorView.isHidden else { return }
        let hotspot = currentCursorType.cursorHotspot
        virtualCursorView.frame.origin = CGPoint(
            x: virtualCursorPosition.x * bounds.width - hotspot.x,
            y: virtualCursorPosition.y * bounds.height - hotspot.y
        )
    }

    func updateCursorLockMode() {
        updateVirtualTrackpadMode()
        // Locked cursor mode uses the dedicated locked-pointer recognizers.
        // The generic indirect long-press recognizer can still receive absolute
        // pointer coordinates from UIKit, which can yank the locked cursor to an edge.
        longPressGesture.isEnabled = !cursorLockEnabled
        if cursorLockEnabled {
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
            lockedPointerDraggedSinceDown = false
            lockedPointerLastHoverLocation = nil
            stopLockedCursorSmoothing()
            setLockedCursorVisible(false)
            // Force UIKit to re-query the pointer style so the system cursor
            // becomes visible again now that cursor lock is off.
            pointerInteraction?.invalidate()
        }
    }

    func handlePointerLockStateChange() {
        guard cursorLockEnabled else { return }
        updateMouseInputHandler()
        hoverGesture.isEnabled = !usesMouseInputDeltas
        lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
        refreshLockedCursorIfNeeded(force: true)
        updateLockedCursorViewVisibility()
    }

    @discardableResult
    func requestCursorLockRecaptureIfNeeded() -> Bool {
        guard canRecaptureCursorLock else { return false }
        onCursorLockRecaptureRequested?()
        return true
    }

    @discardableResult
    func requestCursorLockEscapeIfNeeded() -> Bool {
        guard cursorLockEnabled else { return false }
        onCursorLockEscapeRequested?()
        return true
    }

    func updatePointerLocationForLocalContact(_ location: CGPoint) {
        if cursorLockEnabled {
            lockedCursorPosition = location
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            updateLockedCursorViewPosition()
        }

        if usesVisibleVirtualCursor {
            setVirtualCursorVisible(false)
            updateVirtualCursorPosition(location, updateVisibility: false)
        }

        lastCursorPosition = cursorLockEnabled ? lockedCursorPosition : location
    }

    func handleDirectTouchLocationChange(_ rawLocation: CGPoint) {
        let location = normalizedLocation(rawLocation)
        let pointerMoved = lastCursorPosition.map { previousLocation in
            hypot(location.x - previousLocation.x, location.y - previousLocation.y) > 0.0001
        } ?? true

        updatePointerLocationForLocalContact(location)

        #if os(visionOS)
        // On visionOS, every direct touch interaction must update the host cursor
        // position because the user's gaze moves between interactions. Without this,
        // scroll events arrive at a stale cursor position on the host.
        guard pointerMoved else { return }
        let pointerButtonActive = longPressButtonDown ||
            directLongPressButtonDown ||
            directTwoFingerDragButtonDown ||
            lockedPointerButtonDown ||
            virtualDragActive ||
            pencilButtonDown
        guard !pointerButtonActive, !isDragging else { return }
        #else
        let pointerButtonActive = longPressButtonDown ||
            directLongPressButtonDown ||
            directTwoFingerDragButtonDown ||
            lockedPointerButtonDown ||
            virtualDragActive ||
            pencilButtonDown
        guard directTouchInputMode == .normal,
              !cursorLockEnabled,
              !pointerButtonActive,
              !isDragging,
              pointerMoved else { return }
        #endif

        revealCursorAfterPointerMovement()
        refreshModifiersForInput()
        let modifiers = keyboardModifiers
        sendModifierSnapshotIfNeeded(modifiers)

        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            modifiers: modifiers
        )
        onInputEvent?(.mouseMoved(mouseEvent))
    }

    func setTrackpadCursorVisible(_ isVisible: Bool) {
        if usesLockedTrackpadCursor {
            setLockedCursorVisible(isVisible)
        } else {
            setVirtualCursorVisible(isVisible)
        }
    }

    func trackpadCursorPosition() -> CGPoint {
        if usesLockedTrackpadCursor {
            lockedCursorPosition
        } else {
            virtualCursorPosition
        }
    }

    func trackpadCursorActionPosition() -> CGPoint {
        if usesLockedTrackpadCursor {
            lockedCursorActionPosition()
        } else {
            virtualCursorPosition
        }
    }

    func updateTrackpadCursorPosition(_ position: CGPoint, updateVisibility: Bool) {
        if usesLockedTrackpadCursor {
            lockedCursorPosition = resolvedLockedCursorEventPosition(position)
            noteLockedCursorLocalInput()
            if updateVisibility {
                setLockedCursorVisible(true)
            } else {
                updateLockedCursorViewPosition()
            }
            lastCursorPosition = lockedCursorPosition
        } else {
            updateVirtualCursorPosition(position, updateVisibility: updateVisibility)
        }
    }

    func moveTrackpadCursor(by translation: CGPoint) {
        if usesLockedTrackpadCursor {
            applyLockedCursorDelta(translation)
        } else {
            moveVirtualCursor(by: translation)
        }
    }

    func sendTrackpadMovementEvent(modifiers: MirageModifierFlags) {
        let location = if virtualDragActive {
            trackpadCursorActionPosition()
        } else {
            trackpadCursorPosition()
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            modifiers: modifiers
        )

        if virtualDragActive {
            onInputEvent?(.mouseDragged(mouseEvent))
        } else {
            onInputEvent?(.mouseMoved(mouseEvent))
        }
    }

    func cancelPendingPencilLongPress() {
        pencilLongPressTask?.cancel()
        pencilLongPressTask = nil
    }

    func resetPencilGestureState() {
        cancelPendingPencilLongPress()
        activePencilTouchID = nil
        pencilButtonDown = false
        pencilTapEligible = false
        pencilTouchStartLocation = .zero
        pencilCurrentLocation = .zero
        pencilCurrentStylus = nil
        lastPencilPressure = 0
    }

    func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = isVisible
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func updateLockedCursorViewVisibility() {
        let shouldShow = cursorLockEnabled && syntheticCursorEnabled && lockedCursorVisible && !cursorHiddenForTyping
        lockedCursorView.isHidden = !shouldShow
    }

    func resolvedLockedCursorEventPosition(_ position: CGPoint) -> CGPoint {
        LockedCursorPositionResolver.resolve(position, allowsExtendedBounds: allowsExtendedCursorBounds)
    }

    func lockedCursorActionPosition() -> CGPoint {
        resolvedLockedCursorEventPosition(lockedCursorPosition)
    }

    func shouldIgnoreLockedPointerHoverJump(from lastLocation: CGPoint, to location: CGPoint) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let translation = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
        let distance = hypot(translation.x, translation.y)
        let jumpThreshold = max(bounds.width, bounds.height) * 0.35
        let edgeInset: CGFloat = 2
        let landsOnEdge = location.x <= edgeInset ||
            location.x >= bounds.width - edgeInset ||
            location.y <= edgeInset ||
            location.y >= bounds.height - edgeInset

        return landsOnEdge && distance >= jumpThreshold
    }

    func updateLockedCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !lockedCursorView.isHidden else { return }
        let clamped = CGPoint(
            x: min(max(lockedCursorPosition.x, 0), 1),
            y: min(max(lockedCursorPosition.y, 0), 1)
        )
        let hotspot = currentCursorType.cursorHotspot
        lockedCursorView.frame.origin = CGPoint(
            x: clamped.x * bounds.width - hotspot.x,
            y: clamped.y * bounds.height - hotspot.y
        )
    }

    func applyLockedCursorDelta(_ translation: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let proposedPosition = CGPoint(
            x: lockedCursorPosition.x + translation.x / bounds.width,
            y: lockedCursorPosition.y + translation.y / bounds.height
        )
        lockedCursorPosition = LockedCursorPositionResolver.resolve(
            proposedPosition,
            allowsExtendedBounds: allowsExtendedCursorBounds,
            confirmedHostPosition: lockedCursorConfirmedHostPosition
        )
        noteLockedCursorLocalInput()
        setLockedCursorVisible(true)
        lastCursorPosition = lockedCursorPosition
    }

    func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = resolvedLockedCursorEventPosition(position)
        lockedCursorConfirmedHostPosition = lockedCursorTargetPosition
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
        lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
        lastCursorPosition = lockedCursorPosition
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
        configureInteractionDisplayLink(displayLink)
        displayLink.add(to: .main, forMode: .common)
        lockedCursorDisplayLink = displayLink
    }

    func configureInteractionDisplayLink(_ displayLink: CADisplayLink) {
        let targetFPS = MirageInteractionCadence.targetFPS120
        if #available(iOS 15.0, visionOS 1.0, *) {
            let preferred = Float(targetFPS)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: preferred,
                maximum: preferred,
                preferred: preferred
            )
        } else {
            displayLink.preferredFramesPerSecond = targetFPS
        }
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
        if cursorLockEnabled, pointerLockActive,
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
        refreshModifiersForInput()
        let translation = CGPoint(x: CGFloat(deltaX), y: CGFloat(-deltaY))
        noteLockedPointerDragIfNeeded(for: translation)
        applyLockedCursorDelta(translation)
        sendLockedPointerMovementEvent(location: lockedCursorPosition, modifiers: keyboardModifiers)
    }

    func noteLockedPointerDragIfNeeded(for translation: CGPoint) {
        guard translation != .zero else { return }

        if lockedPointerButtonDown, !lockedPointerDraggedSinceDown {
            lockedPointerDraggedSinceDown = true
            resetPrimaryClickTracking()
        }
    }

    func sendLockedPointerMovementEvent(
        location: CGPoint,
        modifiers: MirageModifierFlags,
        pressure: CGFloat = 1.0,
        stylus: MirageStylusEvent? = nil
    ) {
        let eventLocation = if lockedPointerButtonDown {
            lockedCursorActionPosition()
        } else {
            location
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: eventLocation,
            modifiers: modifiers,
            pressure: pressure,
            stylus: stylus
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
        didResignActiveSinceLastActivation = true
        // Clear all modifier and key repeat state when app loses focus
        stopAllKeyRepeats()
        resetAllModifiers()
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        resetPencilGestureState()
        isDragging = false
        clearSoftwareKeyboardState()
        stopDictation()
        stopTouchScrollDeceleration()
    }

    @objc
    private func appDidEnterBackground() {
        didEnterBackgroundSinceLastActive = true
        // Ordinary app backgrounding should suspend the display layer so we
        // restart presentation cleanly when the scene becomes active again.
        metalView.suspendRendering()
    }

    @objc
    private func appDidBecomeActive() {
        let resignedActive = didResignActiveSinceLastActivation
        let backgrounded = didEnterBackgroundSinceLastActive
        let displayLayerFailed = metalView.hasDisplayLayerFailure
        let shouldRequestRecovery = displayLayerFailed || backgrounded

        if window != nil {
            metalView.resumeRenderingAfterApplicationActivation(resetPresentationState: shouldRequestRecovery)
        }

        sendModifierStateIfNeeded(force: true)
        #if canImport(GameController)
        installHardwareKeyboardHandler()
        updateHardwareKeyboardPresence(GCKeyboard.coalesced != nil)
        updateMouseInputHandler()
        #endif

        didResignActiveSinceLastActivation = false
        didEnterBackgroundSinceLastActive = false
        guard shouldRequestRecovery else { return }

        let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
        MirageLogger.client(
            "Activation recovery requested for stream \(streamIDText) " +
                "(resignedActive=\(resignedActive), backgrounded=\(backgrounded), displayLayerFailed=\(displayLayerFailed))"
        )
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
        reportContainerSizeIfChanged(force: true)
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
        reportContainerSizeIfChanged()
        updateVirtualCursorViewPosition()
        updateLockedCursorViewPosition()
    }

    func reportContainerSizeIfChanged(_ overrideSize: CGSize? = nil, force: Bool = false) {
        let size = overrideSize ?? bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard force || size != lastReportedContainerSize else { return }
        lastReportedContainerSize = size
        onContainerSizeChanged?(size)
    }

    override public func resignFirstResponder() -> Bool {
        // Clear all modifier and key repeat state when losing focus
        stopAllKeyRepeats()
        resetAllModifiers()
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        resetPencilGestureState()
        isDragging = false
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
            beginPencilInteraction(for: touch)
        }
    }

    private func handlePencilTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard !touches.isEmpty else { return }
        guard let activePencilTouchID else { return }
        if let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            updatePencilInteraction(for: touch, event: event)
        }
    }

    private func handlePencilTouchesEnded(_ touches: Set<UITouch>, event _: UIEvent?) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            endPencilInteraction(for: touch)
        }
    }

    private func handlePencilTouchesCancelled(_ touches: Set<UITouch>, event _: UIEvent?) {
        guard !touches.isEmpty else { return }
        if let activePencilTouchID,
           let touch = touches.first(where: { ObjectIdentifier($0) == activePencilTouchID }) {
            cancelPencilInteraction(for: touch)
        }
    }

    func beginPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        pencilTouchStartLocation = location
        pencilCurrentLocation = location
        pencilCurrentStylus = stylusEvent(from: touch)
        lastPencilPressure = normalizedPencilPressure(for: touch)
        pencilTapEligible = true
        pencilButtonDown = false
        updatePointerLocationForLocalContact(location)
        schedulePencilLongPressActivation()
    }

    func updatePencilInteraction(for touch: UITouch, event: UIEvent?) {
        let samples = event?.coalescedTouches(for: touch) ?? [touch]

        for sample in samples {
            let rawLocation = sample.preciseLocation(in: self)
            let location = normalizedLocation(rawLocation)
            let pressure = normalizedPencilPressure(for: sample)
            let stylus = stylusEvent(from: sample)
            pencilCurrentLocation = location
            pencilCurrentStylus = stylus
            updatePointerLocationForLocalContact(location)

            if !pencilButtonDown {
                let drift = clickDistanceInPoints(from: location, to: pencilTouchStartLocation)
                if drift > Self.dragActivationMovementThresholdPoints {
                    pencilTapEligible = false
                    cancelPendingPencilLongPress()
                }
                continue
            }

            let mouseEvent = pointerEventForPencil(
                location: location,
                modifiers: currentPencilModifiers(),
                pressure: pressure,
                stylus: stylus
            )
            onInputEvent?(.mouseDragged(mouseEvent))
        }
    }

    func endPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let stylus = stylusEvent(from: touch)
        pencilCurrentLocation = location
        pencilCurrentStylus = stylus
        updatePointerLocationForLocalContact(location)
        cancelPendingPencilLongPress()

        let modifiers = currentPencilModifiers()
        if pencilButtonDown {
            let mouseEvent = pointerEventForPencil(
                location: location,
                modifiers: modifiers,
                pressure: 0,
                stylus: stylus,
                clickCount: 1
            )
            onInputEvent?(.mouseUp(mouseEvent))
        } else if pencilTapEligible {
            let now = CACurrentMediaTime()
            let clickCount = nextPrimaryClickCount(at: location, timestamp: now)
            currentClickCount = clickCount

            let downEvent = pointerEventForPencil(
                location: location,
                modifiers: modifiers,
                pressure: max(lastPencilPressure, 0.01),
                stylus: stylus,
                clickCount: clickCount
            )
            let upEvent = pointerEventForPencil(
                location: location,
                modifiers: modifiers,
                pressure: 0,
                stylus: stylus,
                clickCount: clickCount
            )
            onInputEvent?(.mouseDown(downEvent))
            onInputEvent?(.mouseUp(upEvent))
            commitPrimaryClick(at: location, timestamp: now, clickCount: clickCount)
        }

        isDragging = false
        resetPencilGestureState()
    }

    func cancelPencilInteraction(for touch: UITouch) {
        let rawLocation = touch.preciseLocation(in: self)
        let location = normalizedLocation(rawLocation)
        let stylus = stylusEvent(from: touch)
        pencilCurrentLocation = location
        pencilCurrentStylus = stylus
        updatePointerLocationForLocalContact(location)
        cancelPendingPencilLongPress()

        if pencilButtonDown {
            let mouseEvent = pointerEventForPencil(
                location: location,
                modifiers: currentPencilModifiers(),
                pressure: 0,
                stylus: stylus,
                clickCount: 1
            )
            onInputEvent?(.mouseUp(mouseEvent))
        }

        isDragging = false
        resetPencilGestureState()
    }

    func schedulePencilLongPressActivation() {
        cancelPendingPencilLongPress()
        guard activePencilTouchID != nil else { return }

        pencilLongPressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: Self.dragActivationDuration)
            } catch {
                return
            }

            guard activePencilTouchID != nil, pencilTapEligible, !pencilButtonDown else { return }

            let mouseEvent = pointerEventForPencil(
                location: pencilCurrentLocation,
                modifiers: currentPencilModifiers(),
                pressure: max(lastPencilPressure, 0.01),
                stylus: pencilCurrentStylus,
                clickCount: 1
            )
            onInputEvent?(.mouseDown(mouseEvent))
            pencilButtonDown = true
            isDragging = true
            resetPrimaryClickTracking()
            lastPanLocation = pencilCurrentLocation
            pencilLongPressTask = nil
        }
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
            if usesVisibleVirtualCursor {
                setVirtualCursorVisible(false)
                updateVirtualCursorPosition(location, updateVisibility: false)
            }
            lastCursorPosition = location
            return location
        }

        if cursorLockEnabled { return lockedCursorActionPosition() }
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

    func performPencilGesture(
        _ kind: MiragePencilGestureKind,
        hoverLocation: CGPoint?
    ) {
        let action = pencilGestureConfiguration.action(for: kind)
        performPencilGestureAction(action, hoverLocation: hoverLocation)
    }

    func performPencilGestureAction(
        _ action: MiragePencilGestureAction,
        hoverLocation: CGPoint?
    ) {
        switch action {
        case .none:
            return
        case .secondaryClick:
            let location = resolvedPencilSecondaryClickLocation(hoverLocation: hoverLocation)
            sendPencilSecondaryClick(at: location)
        case .toggleDictation,
             .remoteShortcut:
            onPencilGestureAction?(action)
        }
    }

    func currentPencilModifiers() -> MirageModifierFlags {
        refreshModifiersForInput()
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
        cancelPendingPencilLongPress()
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
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        performPencilGesture(.doubleTap, hoverLocation: tap.hoverPose?.location)
    }

    @available(iOS 17.5, *)
    public func pencilInteraction(
        _: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .ended else { return }
        performPencilGesture(.squeeze, hoverLocation: squeeze.hoverPose?.location)
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

        keyboardInput.keyChangedHandler = { [weak self] keyboardInput, _, keyCode, isPressed in
            let isModifier = InputCapturingView.hardwareModifierKeyCodes.contains(keyCode)
            if !isModifier, isPressed {
                // Fast path: skip non-modifier key-down when no modifiers are held.
                // handleGCKeyEvent would return early anyway, and creating Tasks for
                // every key press interferes with UIKit's pressesBegan delivery.
                let anyModifierHeld =
                    keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true
                guard anyModifierHeld else { return }
            }
            Task { @MainActor [weak self] in
                if isModifier {
                    self?.handleModifierKeyChange()
                } else {
                    self?.handleNonModifierKeyChange(keyCode: keyCode, isPressed: isPressed)
                }
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

    private func handleNonModifierKeyChange(keyCode: GCKeyCode, isPressed: Bool) {
        for view in views.allObjects {
            guard view.window?.isKeyWindow == true, view.isFirstResponder else { continue }
            view.handleGCKeyEvent(keyCode: keyCode, isPressed: isPressed)
        }
    }
}
#endif
#endif
