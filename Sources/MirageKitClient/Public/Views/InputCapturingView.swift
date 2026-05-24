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

/// UIKit container that renders stream frames and captures touch, keyboard, pointer, and Pencil input.
public class InputCapturingView: UIView {
    /// Embedded sample-buffer renderer that presents decoded stream frames.
    public let sampleBufferView: MirageSampleBufferView

    // MARK: - Safe Area Override

    /// Whether the renderer and input surface should extend through safe areas.
    public var ignoresSafeArea: Bool = true {
        didSet {
            guard ignoresSafeArea != oldValue else { return }
            sampleBufferView.ignoresSafeArea = ignoresSafeArea
            scrollPhysicsView?.ignoresSafeArea = ignoresSafeArea
            setNeedsLayout()
        }
    }

    override public var safeAreaInsets: UIEdgeInsets {
        ignoresSafeArea ? .zero : super.safeAreaInsets
    }

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
            sampleBufferView.onDrawableMetricsChanged = onDrawableMetricsChanged
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
            sampleBufferView.maxDrawableSize = maxDrawableSize
        }
    }

    /// Whether the stream should present locally using aspect fit.
    public var prefersLocalAspectFitPresentation: Bool = false {
        didSet {
            sampleBufferView.prefersLocalAspectFitPresentation = prefersLocalAspectFitPresentation
        }
    }

    /// Pixel-space crop override for logical app windows packed into a shared media stream.
    public var contentRectOverride: CGRect? {
        didSet {
            sampleBufferView.contentRectOverride = contentRectOverride
        }
    }

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)? {
        didSet {
            sampleBufferView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        }
    }

    /// Host-authoritative maximum render frame rate for the active stream.
    public var preferredMaximumRenderFPS: Int? {
        didSet {
            sampleBufferView.preferredMaximumRenderFPS = preferredMaximumRenderFPS
        }
    }

    /// Active vs passive presentation tier for local rendering cadence.
    public var presentationTier: StreamPresentationTier = .activeLive {
        didSet {
            sampleBufferView.streamPresentationTier = presentationTier
        }
    }

    /// Physical media stream used for direct frame-store access.
    public var mediaStreamID: StreamID? {
        didSet {
            sampleBufferView.streamID = mediaStreamID ?? streamID
        }
    }

    /// Logical stream ID used for input, cursor routing, and recovery bookkeeping.
    public var streamID: StreamID? {
        didSet {
            if oldValue != streamID {
                stopAllKeyRepeats()
                resetPointerSuppressionState(reason: "stream_rebound")
            }
            sampleBufferView.streamID = mediaStreamID ?? streamID
            let previousID = registeredCursorStreamID
            if let previousID, previousID != streamID { MirageCursorUpdateRouter.shared.unregister(streamID: previousID) }
            registeredCursorStreamID = streamID
            if let streamID { MirageCursorUpdateRouter.shared.register(view: self, for: streamID) }
            cursorSequence = 0
            lockedCursorConfirmedHostPosition = nil
            refreshCursorIfNeeded(force: true)
        }
    }

    func activateStreamPresentation() {
        sampleBufferView.streamID = mediaStreamID ?? streamID
        sampleBufferView.resumeRendering()
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
            _ = refreshLockedCursorIfNeeded(force: true)
        }
    }

    /// Whether the system cursor should be hidden even when pointer lock is off.
    public var hideSystemCursor: Bool = false {
        didSet {
            guard hideSystemCursor != oldValue else { return }
            if syntheticCursorEnabled, hideSystemCursor {
                cursorIsVisible = true
            }
            pointerInteraction?.invalidate()
            updateLockedCursorViewVisibility()
            updateLockedCursorViewPosition()
            updateMouseInputHandler()
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
            if syntheticCursorEnabled, hideSystemCursor || cursorLockEnabled {
                cursorIsVisible = true
                if cursorLockEnabled { lockedCursorVisible = true }
            }
            updateVirtualTrackpadMode()
            updateLockedCursorViewVisibility()
            pointerInteraction?.invalidate()
            refreshCursorUpdates(force: true)
            updateMouseInputHandler()
        }
    }

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Session identifier for the active desktop stream represented by this view.
    public var desktopSessionID: UUID? {
        didSet {
            guard desktopSessionID != oldValue else { return }
            clearPendingApplicationActivationHandling(reason: "desktop_session_changed")
        }
    }

    /// Whether the represented desktop session has already presented its first frame.
    public var hasPresentedFrameForActivationRecovery: Bool = false

    /// Callback when hardware keyboard presence changes.
    public var onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? {
        didSet {
            onHardwareKeyboardPresenceChanged?(hardwareKeyboardPresent)
        }
    }

    /// Callback when software keyboard visibility changes.
    public var onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?

    /// Direct-touch behavior mode for touch clients.
    public var directTouchInputMode: MirageDirectTouchInputMode = .defaultForCurrentDevice {
        didSet {
            guard directTouchInputMode != oldValue else { return }
            updateVirtualTrackpadMode()
            updateMouseInputHandler()
        }
    }

    var usesVirtualTrackpad: Bool { directTouchInputMode == .dragCursor }
    var usesVisibleVirtualCursor: Bool { usesVirtualTrackpad && !cursorLockEnabled }
    var usesLockedTrackpadCursor: Bool { usesVirtualTrackpad && cursorLockEnabled }
    var usesNativeScrollEventMetadata: Bool {
        UserDefaults.standard.bool(forKey: MirageNativeScrollEventMetadataPreference.defaultsKey)
    }

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

    /// Callback when dictation microphone input level changes.
    public var onDictationInputLevelChanged: ((Float) -> Void)?

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
    var dictationReservedLocale: Locale?
    var dictationResultBuffer = MirageDictationResultBuffer()
    var dictationInputLevelMeter = MirageDictationInputLevelMeter()
    var dictationInputLevelGeneration: UInt64 = 0

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
    var hardwareKeyboardPresent: Bool = false
    var didResignActiveSinceLastActivation = false
    var didEnterBackgroundSinceLastActive = false
    var pendingApplicationActivationDecision: InputCapturingActivationRecoveryDecision?
    var pendingActivationResignedActive = false
    var pendingActivationBackgrounded = false
    var pendingActivationDisplayLayerFailed = false
    var pendingActivationDesktopSessionID: UUID?
    lazy var responderRecoveryController = InputCapturingResponderRecoveryController(
        contextProvider: { [weak self] in
            self?.responderRecoverySnapshot() ?? (
                target: .captureView,
                context: InputCapturingResponderRecoveryContext(
                    hasWindow: false,
                    isKeyWindow: false,
                    sceneActivationState: nil,
                    targetIsFirstResponder: false
                )
            )
        },
        attemptHandler: { [weak self] target in
            self?.attemptResponderRecovery(for: target) ?? false
        },
        logHandler: { [weak self] trigger, target, context, decision, attempt, didBecomeFirstResponder in
            self?.logResponderRecovery(
                trigger: trigger,
                target: target,
                context: context,
                decision: decision,
                attempt: attempt,
                didBecomeFirstResponder: didBecomeFirstResponder
            )
        }
    )

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

    /// Scroll physics capturing view for native trackpad momentum/bounce.
    var scrollPhysicsView: ScrollPhysicsCapturingView?

    // Direct touch multi-finger gestures
    var directPinchGesture: UIPinchGestureRecognizer!
    var directRotationGesture: UIRotationGestureRecognizer!
    var lastDirectPinchScale: CGFloat = 1.0
    var lastDirectRotationAngle: CGFloat = 0.0

    /// Active key repeat timers keyed by HID usage code.
    var keyRepeatTimers: [UIKeyboardHIDUsage: Timer] = [:]
    /// Held key press references for generating repeat events.
    var heldKeyPresses: [UIKeyboardHIDUsage: UIPress] = [:]
    /// Active repeat session for a modified key claimed through GameController.
    var modifiedKeyRepeatState: ModifiedKeyRepeatState?
    /// Timer that polls physical key state for modified-key repeat sessions.
    var modifiedKeyRepeatTimer: Timer?
    /// Most recent client-reserved shortcut dispatched through a UIKit command/action path.
    var lastClientShortcutDispatch: ClientShortcutDispatch?
    /// Most recent intercepted shortcut forwarded through a UIKit command/action path.
    var lastPassthroughShortcutDispatch: PassthroughShortcutDispatch?

    // Virtual cursor state (direct touch trackpad mode)
    let virtualCursorView = UIImageView()
    let lockedCursorView = UIImageView()
    var virtualCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var virtualCursorVelocity: CGPoint = .zero
    var virtualCursorDecelerationLink: CADisplayLink?
    var virtualDragActive: Bool = false
    var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorConfirmedHostPosition: CGPoint?
    var lockedCursorVisible: Bool = false
    var lockedCursorTargetVisible: Bool = false
    var lockedPointerButtonDown: Bool = false
    var lockedPointerDraggedSinceDown: Bool = false
    var lockedCursorLocalInputTime: CFTimeInterval = 0
    let lockedCursorLocalHoldInterval: CFTimeInterval = 0.12
    let lockedCursorLerpAlpha: CGFloat = 0.25
    let lockedCursorSnapThreshold: CGFloat = 0.08
    let lockedCursorStopThreshold: CGFloat = 0.002
    var lockedCursorDisplayLink: CADisplayLink?
    var lockedPointerLastHoverLocation: CGPoint?
    var suppressEscapeKeyUpForCursorUnlock = false
    var swallowingLongPressForCursorRecapture = false
    var swallowingVirtualCursorLongPressForCursorRecapture = false
    var usesMouseInputDeltas: Bool = false
    #if canImport(GameController)
    var lastLoggedMouseInputDeltaStatus: String?
    #endif
    var pointerLockActive: Bool = false {
        didSet {
            guard pointerLockActive != oldValue else { return }
            handlePointerLockStateChange()
        }
    }

    #if canImport(GameController)
    var mouseInput: GCMouseInput?
    #endif
    var touchScrollDecelerationVelocity: CGPoint = .zero
    var touchScrollDecelerationLink: CADisplayLink?
    var touchScrollDecelerationLocation: CGPoint = .zero
    var activePencilTouchID: ObjectIdentifier?
    var pencilButtonDown = false
    var pencilCurrentLocation: CGPoint = .zero
    var pencilCurrentStylus: MirageStylusEvent?
    var lastPencilPressure: CGFloat = 0
    var lastPencilMoveSampleTimestamp: TimeInterval = 0
    var lastPencilMoveSampleLocation: CGPoint?
    var lastPencilHoverForwardTime: CFTimeInterval = 0
    var lastPencilHoverForwardLocation: CGPoint?
    var lastPencilHoverLocation: CGPoint?
    var lastPencilHoverStylus: MirageStylusEvent?
    #if os(iOS)
    var pencilInteraction: UIPencilInteraction?
    #endif

    /// Whether this view may own local input focus and forward input to the host.
    public var inputEnabled: Bool = true {
        didSet {
            guard inputEnabled != oldValue else { return }
            if inputEnabled {
                requestResponderRecovery(.focusChanged)
            } else {
                clearSoftwareKeyboardState()
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
            }
        }
    }

    /// Software keyboard state
    public var softwareKeyboardVisible: Bool = false {
        didSet {
            guard softwareKeyboardVisible != oldValue else { return }
            if !softwareKeyboardVisible {
                softwareKeyboardDismissalPending = false
            }
            updateSoftwareKeyboardVisibility()
        }
    }

    var lastReportedContainerSize: CGSize = .zero

    var softwareKeyboardField: SoftwareKeyboardInputView?
    var softwareKeyboardAccessoryView: SoftwareKeyboardAccessoryView?
    var isSoftwareKeyboardShown: Bool = false
    var isSoftwareKeyboardResponderActive: Bool = false
    var softwareKeyboardDismissalPending = false
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
    var directDoubleTapDragGesture: UIPanGestureRecognizer!
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
    var pencilContactGesture: PencilContactGestureRecognizer!

    // Track drag state
    var isDragging = false
    var lastPanLocation: CGPoint = .zero
    var longPressButtonDown = false
    var longPressCancelledForMultiTouch = false
    var directLongPressButtonDown = false
    var directDoubleTapDragButtonDown = false
    var directLongPressStartPoint: CGPoint = .zero
    var directTwoFingerDragButtonDown = false
    var swallowingDirectLongPressForCursorRecapture = false
    var swallowingDirectDoubleTapDragForCursorRecapture = false
    var swallowingDirectTwoFingerDragForCursorRecapture = false

    /// Track last cursor position for scroll events in stream space.
    /// Secondary desktop cursor-lock travel may temporarily exceed `0...1`.
    var lastCursorPosition: CGPoint?
    /// Normalized contact anchor used while native direct-touch scrolling is active.
    var directTouchScrollAnchorLocation: CGPoint?

    // Track keyboard modifier state - single source of truth
    // Gesture events read modifiers directly from gesture.modifierFlags at event time
    var heldModifierKeys: Set<UIKeyboardHIDUsage> = []
    var capsLockEnabled: Bool = false
    var lastSentModifiers: MirageModifierFlags = []
    var modifierRefreshTask: Task<Void, Never>?
    var hardwareRefreshFailureCount: Int = 0
    #if canImport(GameController)
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

    override public init(frame: CGRect) {
        sampleBufferView = MirageSampleBufferView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        sampleBufferView = MirageSampleBufferView(frame: .zero)
        super.init(coder: coder)
        setup()
    }

    deinit {
        cancelPendingResponderRecovery()
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

#endif
