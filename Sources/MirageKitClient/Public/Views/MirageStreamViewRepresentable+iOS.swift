//
//  MirageStreamViewRepresentable+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import SwiftUI

// MARK: - SwiftUI Representable (iOS)

public struct MirageStreamViewRepresentable: UIViewControllerRepresentable {
    public let streamID: StreamID

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable metrics change - reports actual pixel dimensions and scale
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Cursor store for pointer updates (decoupled from SwiftUI observation).
    public var cursorStore: MirageClientCursorStore?

    /// Cursor position store for desktop cursor sync.
    public var cursorPositionStore: MirageClientCursorPositionStore?

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Callback when hardware keyboard presence changes.
    public var onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?

    /// Callback when software keyboard visibility changes.
    public var onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?

    /// Callback when non-stylus direct touch activity occurs.
    public var onDirectTouchActivity: (() -> Void)?

    /// Direct-touch behavior mode.
    public var directTouchInputMode: MirageDirectTouchInputMode

    /// Whether the software keyboard should be visible.
    public var softwareKeyboardVisible: Bool

    /// Apple Pencil behavior mode.
    public var pencilInputMode: MiragePencilInputMode

    /// Monotonic toggle token for dictation requests.
    public var dictationToggleRequestID: UInt64

    /// Callback when dictation active state changes.
    public var onDictationStateChanged: ((Bool) -> Void)?

    /// Callback when dictation fails with a user-facing message.
    public var onDictationError: ((String) -> Void)?

    /// Callback when UIKit resolves pointer-lock availability for the current scene.
    public var onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode

    /// Dictation locale selection. System default follows the current device locale.
    public var dictationLocalePreference: MirageDictationLocalePreference

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

    /// Whether the stream can recapture cursor lock after a temporary local unlock.
    public var cursorLockCanRecapture: Bool

    /// Callback when the client should temporarily unlock cursor capture.
    public var onCursorLockEscapeRequested: (() -> Void)?

    /// Callback when the client should recapture cursor lock after a temporary unlock.
    public var onCursorLockRecaptureRequested: (() -> Void)?

    /// Whether Mirage should render its synthetic local cursor presentation.
    public var syntheticCursorEnabled: Bool

    /// Active vs passive presentation tier.
    public var presentationTier: StreamPresentationTier

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize?

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? = nil,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        cursorPositionStore: MirageClientCursorPositionStore? = nil,
        onBecomeActive: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        directTouchInputMode: MirageDirectTouchInputMode = .normal,
        softwareKeyboardVisible: Bool = false,
        pencilInputMode: MiragePencilInputMode = .mouse,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        dictationLocalePreference: MirageDictationLocalePreference = .system,
        cursorLockEnabled: Bool = false,
        cursorLockCanRecapture: Bool = false,
        onCursorLockEscapeRequested: (() -> Void)? = nil,
        onCursorLockRecaptureRequested: (() -> Void)? = nil,
        syntheticCursorEnabled: Bool = true,
        presentationTier: StreamPresentationTier = .activeLive,
        maxDrawableSize: CGSize? = nil
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        self.cursorStore = cursorStore
        self.cursorPositionStore = cursorPositionStore
        self.onBecomeActive = onBecomeActive
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.onDirectTouchActivity = onDirectTouchActivity
        self.directTouchInputMode = directTouchInputMode
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.pencilInputMode = pencilInputMode
        self.dictationToggleRequestID = dictationToggleRequestID
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
        self.dictationMode = dictationMode
        self.dictationLocalePreference = dictationLocalePreference
        self.cursorLockEnabled = cursorLockEnabled
        self.cursorLockCanRecapture = cursorLockCanRecapture
        self.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        self.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        self.syntheticCursorEnabled = syntheticCursorEnabled
        self.presentationTier = presentationTier
        self.maxDrawableSize = maxDrawableSize
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange,
            onBecomeActive: onBecomeActive,
            onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: onDirectTouchActivity,
            onDictationStateChanged: onDictationStateChanged,
            onDictationError: onDictationError,
            onResolvedPointerLockStateChanged: onResolvedPointerLockStateChanged
        )
    }

    public func makeUIViewController(context: Context) -> MirageStreamViewController {
        let controller = MirageStreamViewControllerCache.shared.controller(for: streamID)
        controller.configureCallbacks(
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onRefreshRateOverrideChange: context.coordinator.handleRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: context.coordinator.handleHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: context.coordinator.handleSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: context.coordinator.handleDirectTouchActivity,
            onDictationStateChanged: context.coordinator.handleDictationStateChanged,
            onDictationError: context.coordinator.handleDictationError,
            onResolvedPointerLockStateChanged: context.coordinator.handleResolvedPointerLockStateChanged
        )
        controller.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            dictationLocalePreference: dictationLocalePreference,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            cursorLockCanRecapture: cursorLockCanRecapture,
            onCursorLockEscapeRequested: onCursorLockEscapeRequested,
            onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
            syntheticCursorEnabled: syntheticCursorEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize
        )
        return controller
    }

    public func updateUIViewController(_ uiViewController: MirageStreamViewController, context: Context) {
        // Update coordinator's callbacks in case they changed
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        context.coordinator.onBecomeActive = onBecomeActive
        context.coordinator.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        context.coordinator.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        context.coordinator.onDirectTouchActivity = onDirectTouchActivity
        context.coordinator.onDictationStateChanged = onDictationStateChanged
        context.coordinator.onDictationError = onDictationError
        context.coordinator.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
        context.coordinator.noteRepresentableUpdate(for: streamID)

        uiViewController.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            dictationLocalePreference: dictationLocalePreference,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            cursorLockCanRecapture: cursorLockCanRecapture,
            onCursorLockEscapeRequested: onCursorLockEscapeRequested,
            onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
            syntheticCursorEnabled: syntheticCursorEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize
        )
    }

    static func releaseCachedControllerIfPossible(
        streamID: StreamID,
        sessionStore: MirageClientSessionStore
    ) {
        guard sessionStore.sessionByStreamID(streamID) == nil else { return }
        MirageStreamViewControllerCache.shared.releaseController(for: streamID)
    }
}

@MainActor
private final class MirageStreamViewControllerCache {
    static let shared = MirageStreamViewControllerCache()

    private var controllersByStreamID: [StreamID: MirageStreamViewController] = [:]

    private init() {}

    func controller(for streamID: StreamID) -> MirageStreamViewController {
        if let controller = controllersByStreamID[streamID] {
            return controller
        }

        let controller = MirageStreamViewController()
        controllersByStreamID[streamID] = controller
        return controller
    }

    func releaseController(for streamID: StreamID) {
        controllersByStreamID.removeValue(forKey: streamID)
    }
}

public final class MirageStreamViewController: UIViewController {
    var currentStreamID: StreamID?
    private let captureView = InputCapturingView(frame: .zero)
    private var pointerLockRequested: Bool = false
    private var pointerLockObserver: NSObjectProtocol?
    private var lastResolvedPointerLockState: MirageResolvedPointerLockState?

    override public func loadView() {
        view = captureView
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPointerLockObserverIfNeeded()
    }

    override public func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if captureView.onInputEvent != nil,
           MirageInterceptedShortcutPolicy.shortcut(
               actionName: NSStringFromSelector(action)
           ) != nil {
            return captureView
        }
        return super.target(forAction: action, withSender: sender)
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPointerLockObserver()
        lastResolvedPointerLockState = nil
        captureView.onResolvedPointerLockStateChanged?(.unavailable)
        captureView.pointerLockActive = false
    }

    func configureCallbacks(
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)?,
        onBecomeActive: (() -> Void)?,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?,
        onDirectTouchActivity: (() -> Void)?,
        onDictationStateChanged: ((Bool) -> Void)?,
        onDictationError: ((String) -> Void)?,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?
    ) {
        captureView.onInputEvent = onInputEvent
        captureView.onDrawableMetricsChanged = onDrawableMetricsChanged
        captureView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        captureView.onBecomeActive = onBecomeActive
        captureView.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        captureView.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        captureView.onDirectTouchActivity = onDirectTouchActivity
        captureView.onDictationStateChanged = onDictationStateChanged
        captureView.onDictationError = onDictationError
        captureView.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
    }

    func updateState(
        streamID: StreamID,
        directTouchInputMode: MirageDirectTouchInputMode,
        softwareKeyboardVisible: Bool,
        pencilInputMode: MiragePencilInputMode,
        dictationToggleRequestID: UInt64,
        dictationMode: MirageDictationMode,
        dictationLocalePreference: MirageDictationLocalePreference,
        cursorStore: MirageClientCursorStore?,
        cursorPositionStore: MirageClientCursorPositionStore?,
        cursorLockEnabled: Bool,
        cursorLockCanRecapture: Bool,
        onCursorLockEscapeRequested: (() -> Void)?,
        onCursorLockRecaptureRequested: (() -> Void)?,
        syntheticCursorEnabled: Bool,
        presentationTier: StreamPresentationTier,
        maxDrawableSize: CGSize?
    ) {
        // Set stream ID first so cursor router registration is ready
        // before cursorStore/cursorPositionStore didSet triggers refreshCursorIfNeeded.
        currentStreamID = streamID
        captureView.streamID = streamID
        captureView.directTouchInputMode = directTouchInputMode
        captureView.softwareKeyboardVisible = softwareKeyboardVisible
        captureView.pencilInputMode = pencilInputMode
        captureView.dictationToggleRequestID = dictationToggleRequestID
        captureView.dictationMode = dictationMode
        captureView.dictationLocalePreference = dictationLocalePreference
        captureView.cursorStore = cursorStore
        captureView.cursorPositionStore = cursorPositionStore
        captureView.cursorLockEnabled = cursorLockEnabled
        captureView.canRecaptureCursorLock = cursorLockCanRecapture
        captureView.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        captureView.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        captureView.syntheticCursorEnabled = syntheticCursorEnabled
        captureView.presentationTier = presentationTier
        captureView.maxDrawableSize = maxDrawableSize

        pointerLockRequested = cursorLockEnabled
        updatePointerLockState()
    }

    deinit {
        stopPointerLockObserver()
    }

    private func startPointerLockObserverIfNeeded() {
        guard pointerLockObserver == nil else { return }
        pointerLockObserver = NotificationCenter.default.addObserver(
            forName: UIPointerLockState.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let scene = notification.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene else { return }
            guard scene === view.window?.windowScene else { return }
            updatePointerLockState()
        }
        updatePointerLockState()
    }

    private func stopPointerLockObserver() {
        if let pointerLockObserver {
            NotificationCenter.default.removeObserver(pointerLockObserver)
            self.pointerLockObserver = nil
        }
    }

    private func updatePointerLockState() {
        let resolvedState = MirageResolvedPointerLockState(
            isSupported: view.window?.windowScene?.pointerLockState != nil,
            isLocked: pointerLockRequested &&
                (view.window?.windowScene?.pointerLockState?.isLocked ?? false)
        )
        captureView.pointerLockActive = resolvedState.isLocked
        if lastResolvedPointerLockState != resolvedState {
            lastResolvedPointerLockState = resolvedState
            captureView.onResolvedPointerLockStateChanged?(resolvedState)
            if pointerLockRequested, !resolvedState.isLocked {
                MirageLogger.client("Pointer lock not active for scene.")
            } else if resolvedState.isLocked {
                MirageLogger.client("Pointer lock active for scene.")
            }
        }
    }
}
#endif
