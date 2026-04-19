//
//  MirageStreamViewRepresentable+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import Foundation
import SwiftUI

// MARK: - SwiftUI Representable (iOS)

public struct MirageStreamViewRepresentable: UIViewControllerRepresentable {
    public let streamID: StreamID

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable metrics change - reports actual pixel dimensions and scale
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the platform container/window bounds change.
    public var onContainerSizeChanged: ((CGSize) -> Void)?

    /// Callback when the view decides on a refresh rate override.
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Cursor store for pointer updates (decoupled from SwiftUI observation).
    public var cursorStore: MirageClientCursorStore?

    /// Cursor position store for desktop cursor sync.
    public var cursorPositionStore: MirageClientCursorPositionStore?

    /// Session identifier for the active desktop stream rendered by this view.
    public var desktopSessionID: UUID?

    /// Whether the active desktop stream has presented its first frame.
    public var hasPresentedFrameForActivationRecovery: Bool

    /// Callback when the active scene requires stream recovery after activation.
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

    /// Apple Pencil hardware gesture mapping.
    public var pencilGestureConfiguration: MiragePencilGestureConfiguration

    /// Client-reserved shortcuts that should be handled locally instead of forwarded.
    public var clientShortcuts: [MirageClientShortcut]

    /// Callback when a client-reserved shortcut is triggered.
    public var onClientShortcut: ((MirageClientShortcut) -> Void)?

    /// Unified actions triggered by shortcuts, gestures, or the control bar.
    public var actions: [MirageAction]

    /// Callback when a unified action is triggered.
    public var onActionTriggered: ((MirageAction) -> Void)?

    /// Callback when a Pencil gesture maps to a client-side action.
    public var onPencilGestureAction: ((MiragePencilGestureAction) -> Void)?

    /// Monotonic toggle token for dictation requests.
    public var dictationToggleRequestID: UInt64

    /// Callback when dictation active state changes.
    public var onDictationStateChanged: ((Bool) -> Void)?

    /// Callback when dictation fails with a user-facing message.
    public var onDictationError: ((String) -> Void)?

    /// Callback when dictation microphone input level changes.
    public var onDictationInputLevelChanged: ((Float) -> Void)?

    /// Callback when UIKit resolves pointer-lock availability for the current scene.
    public var onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode

    /// Dictation locale selection. System default follows the current device locale.
    public var dictationLocalePreference: MirageDictationLocalePreference

    /// Whether the local system cursor should be hidden while streaming.
    public var hideSystemCursor: Bool

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

    /// Whether locked desktop cursor input may move beyond the streamed view bounds.
    public var allowsExtendedDesktopCursorBounds: Bool

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

    /// Whether the stream should present locally using aspect fit.
    public var prefersLocalAspectFitPresentation: Bool

    /// Whether the UIKit stream view should extend through platform safe areas.
    public var ignoresSafeArea: Bool

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? = nil,
        onContainerSizeChanged: ((CGSize) -> Void)? = nil,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        cursorPositionStore: MirageClientCursorPositionStore? = nil,
        desktopSessionID: UUID? = nil,
        hasPresentedFrameForActivationRecovery: Bool = false,
        onBecomeActive: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        directTouchInputMode: MirageDirectTouchInputMode = .defaultForCurrentDevice,
        softwareKeyboardVisible: Bool = false,
        pencilGestureConfiguration: MiragePencilGestureConfiguration = .default,
        clientShortcuts: [MirageClientShortcut] = [],
        onClientShortcut: ((MirageClientShortcut) -> Void)? = nil,
        actions: [MirageAction] = [],
        onActionTriggered: ((MirageAction) -> Void)? = nil,
        onPencilGestureAction: ((MiragePencilGestureAction) -> Void)? = nil,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        onDictationInputLevelChanged: ((Float) -> Void)? = nil,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        dictationLocalePreference: MirageDictationLocalePreference = .system,
        hideSystemCursor: Bool = false,
        cursorLockEnabled: Bool = false,
        allowsExtendedDesktopCursorBounds: Bool = false,
        cursorLockCanRecapture: Bool = false,
        onCursorLockEscapeRequested: (() -> Void)? = nil,
        onCursorLockRecaptureRequested: (() -> Void)? = nil,
        syntheticCursorEnabled: Bool = true,
        presentationTier: StreamPresentationTier = .activeLive,
        maxDrawableSize: CGSize? = nil,
        prefersLocalAspectFitPresentation: Bool = false,
        ignoresSafeArea: Bool = true
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onContainerSizeChanged = onContainerSizeChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        self.cursorStore = cursorStore
        self.cursorPositionStore = cursorPositionStore
        self.desktopSessionID = desktopSessionID
        self.hasPresentedFrameForActivationRecovery = hasPresentedFrameForActivationRecovery
        self.onBecomeActive = onBecomeActive
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.onDirectTouchActivity = onDirectTouchActivity
        self.directTouchInputMode = directTouchInputMode
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.pencilGestureConfiguration = pencilGestureConfiguration
        self.clientShortcuts = clientShortcuts
        self.onClientShortcut = onClientShortcut
        self.actions = actions
        self.onActionTriggered = onActionTriggered
        self.onPencilGestureAction = onPencilGestureAction
        self.dictationToggleRequestID = dictationToggleRequestID
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.onDictationInputLevelChanged = onDictationInputLevelChanged
        self.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
        self.dictationMode = dictationMode
        self.dictationLocalePreference = dictationLocalePreference
        self.hideSystemCursor = hideSystemCursor
        self.cursorLockEnabled = cursorLockEnabled
        self.allowsExtendedDesktopCursorBounds = allowsExtendedDesktopCursorBounds
        self.cursorLockCanRecapture = cursorLockCanRecapture
        self.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        self.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        self.syntheticCursorEnabled = syntheticCursorEnabled
        self.presentationTier = presentationTier
        self.maxDrawableSize = maxDrawableSize
        self.prefersLocalAspectFitPresentation = prefersLocalAspectFitPresentation
        self.ignoresSafeArea = ignoresSafeArea
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onContainerSizeChanged: onContainerSizeChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange,
            onBecomeActive: onBecomeActive,
            onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: onDirectTouchActivity,
            onDictationStateChanged: onDictationStateChanged,
            onDictationError: onDictationError,
            onDictationInputLevelChanged: onDictationInputLevelChanged,
            onResolvedPointerLockStateChanged: onResolvedPointerLockStateChanged
        )
    }

    public func makeUIViewController(context: Context) -> MirageStreamViewController {
        let controller = MirageStreamViewControllerCache.shared.controller(for: streamID)
        controller.configureCallbacks(
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onContainerSizeChanged: context.coordinator.handleContainerSizeChanged,
            onRefreshRateOverrideChange: context.coordinator.handleRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: context.coordinator.handleHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: context.coordinator.handleSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: context.coordinator.handleDirectTouchActivity,
            onClientShortcut: onClientShortcut,
            onActionTriggered: onActionTriggered,
            onPencilGestureAction: onPencilGestureAction,
            onDictationStateChanged: context.coordinator.handleDictationStateChanged,
            onDictationError: context.coordinator.handleDictationError,
            onDictationInputLevelChanged: context.coordinator.handleDictationInputLevelChanged,
            onResolvedPointerLockStateChanged: context.coordinator.handleResolvedPointerLockStateChanged
        )
        controller.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,

            pencilGestureConfiguration: pencilGestureConfiguration,
            clientShortcuts: clientShortcuts,
            actions: actions,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            dictationLocalePreference: dictationLocalePreference,
            hideSystemCursor: hideSystemCursor,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            desktopSessionID: desktopSessionID,
            hasPresentedFrameForActivationRecovery: hasPresentedFrameForActivationRecovery,
            cursorLockEnabled: cursorLockEnabled,
            allowsExtendedDesktopCursorBounds: allowsExtendedDesktopCursorBounds,
            cursorLockCanRecapture: cursorLockCanRecapture,
            onCursorLockEscapeRequested: onCursorLockEscapeRequested,
            onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
            syntheticCursorEnabled: syntheticCursorEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
            ignoresSafeArea: ignoresSafeArea
        )
        return controller
    }

    public func updateUIViewController(_ uiViewController: MirageStreamViewController, context: Context) {
        // Update coordinator's callbacks in case they changed
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onContainerSizeChanged = onContainerSizeChanged
        context.coordinator.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        context.coordinator.onBecomeActive = onBecomeActive
        context.coordinator.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        context.coordinator.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        context.coordinator.onDirectTouchActivity = onDirectTouchActivity
        context.coordinator.onDictationStateChanged = onDictationStateChanged
        context.coordinator.onDictationError = onDictationError
        context.coordinator.onDictationInputLevelChanged = onDictationInputLevelChanged
        context.coordinator.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
        context.coordinator.noteRepresentableUpdate(for: streamID)

        uiViewController.configureCallbacks(
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onContainerSizeChanged: context.coordinator.handleContainerSizeChanged,
            onRefreshRateOverrideChange: context.coordinator.handleRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: context.coordinator.handleHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: context.coordinator.handleSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: context.coordinator.handleDirectTouchActivity,
            onClientShortcut: onClientShortcut,
            onActionTriggered: onActionTriggered,
            onPencilGestureAction: onPencilGestureAction,
            onDictationStateChanged: context.coordinator.handleDictationStateChanged,
            onDictationError: context.coordinator.handleDictationError,
            onDictationInputLevelChanged: context.coordinator.handleDictationInputLevelChanged,
            onResolvedPointerLockStateChanged: context.coordinator.handleResolvedPointerLockStateChanged
        )

        uiViewController.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,

            pencilGestureConfiguration: pencilGestureConfiguration,
            clientShortcuts: clientShortcuts,
            actions: actions,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            dictationLocalePreference: dictationLocalePreference,
            hideSystemCursor: hideSystemCursor,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            desktopSessionID: desktopSessionID,
            hasPresentedFrameForActivationRecovery: hasPresentedFrameForActivationRecovery,
            cursorLockEnabled: cursorLockEnabled,
            allowsExtendedDesktopCursorBounds: allowsExtendedDesktopCursorBounds,
            cursorLockCanRecapture: cursorLockCanRecapture,
            onCursorLockEscapeRequested: onCursorLockEscapeRequested,
            onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
            syntheticCursorEnabled: syntheticCursorEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
            ignoresSafeArea: ignoresSafeArea
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

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        captureView.reportContainerSizeIfChanged(view.bounds.size)
    }

    override public func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if captureView.shouldHandleResponderAction(action) {
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
        onContainerSizeChanged: ((CGSize) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)?,
        onBecomeActive: (() -> Void)?,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?,
        onDirectTouchActivity: (() -> Void)?,
        onClientShortcut: ((MirageClientShortcut) -> Void)?,
        onActionTriggered: ((MirageAction) -> Void)?,
        onPencilGestureAction: ((MiragePencilGestureAction) -> Void)?,
        onDictationStateChanged: ((Bool) -> Void)?,
        onDictationError: ((String) -> Void)?,
        onDictationInputLevelChanged: ((Float) -> Void)?,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?
    ) {
        captureView.onInputEvent = onInputEvent
        captureView.onDrawableMetricsChanged = onDrawableMetricsChanged
        captureView.onContainerSizeChanged = onContainerSizeChanged
        captureView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        captureView.onBecomeActive = onBecomeActive
        captureView.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        captureView.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        captureView.onDirectTouchActivity = onDirectTouchActivity
        captureView.onClientShortcut = onClientShortcut
        captureView.onActionTriggered = onActionTriggered
        captureView.onPencilGestureAction = onPencilGestureAction
        captureView.onDictationStateChanged = onDictationStateChanged
        captureView.onDictationError = onDictationError
        captureView.onDictationInputLevelChanged = onDictationInputLevelChanged
        captureView.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
    }

    func updateState(
        streamID: StreamID,
        directTouchInputMode: MirageDirectTouchInputMode,
        softwareKeyboardVisible: Bool,
        pencilGestureConfiguration: MiragePencilGestureConfiguration,
        clientShortcuts: [MirageClientShortcut],
        actions: [MirageAction],
        dictationToggleRequestID: UInt64,
        dictationMode: MirageDictationMode,
        dictationLocalePreference: MirageDictationLocalePreference,
        hideSystemCursor: Bool,
        cursorStore: MirageClientCursorStore?,
        cursorPositionStore: MirageClientCursorPositionStore?,
        desktopSessionID: UUID?,
        hasPresentedFrameForActivationRecovery: Bool,
        cursorLockEnabled: Bool,
        allowsExtendedDesktopCursorBounds: Bool,
        cursorLockCanRecapture: Bool,
        onCursorLockEscapeRequested: (() -> Void)?,
        onCursorLockRecaptureRequested: (() -> Void)?,
        syntheticCursorEnabled: Bool,
        presentationTier: StreamPresentationTier,
        maxDrawableSize: CGSize?,
        prefersLocalAspectFitPresentation: Bool,
        ignoresSafeArea: Bool
    ) {
        // Set stream ID first so cursor router registration is ready
        // before cursorStore/cursorPositionStore didSet triggers refreshCursorIfNeeded.
        currentStreamID = streamID
        captureView.streamID = streamID
        captureView.directTouchInputMode = directTouchInputMode
        captureView.softwareKeyboardVisible = softwareKeyboardVisible
        captureView.pencilGestureConfiguration = pencilGestureConfiguration
        captureView.clientShortcuts = clientShortcuts
        captureView.actions = actions
        captureView.dictationToggleRequestID = dictationToggleRequestID
        captureView.dictationMode = dictationMode
        captureView.dictationLocalePreference = dictationLocalePreference
        captureView.hideSystemCursor = hideSystemCursor
        captureView.cursorStore = cursorStore
        captureView.cursorPositionStore = cursorPositionStore
        captureView.desktopSessionID = desktopSessionID
        captureView.hasPresentedFrameForActivationRecovery = hasPresentedFrameForActivationRecovery
        captureView.allowsExtendedCursorBounds = allowsExtendedDesktopCursorBounds
        captureView.cursorLockEnabled = cursorLockEnabled
        captureView.canRecaptureCursorLock = cursorLockCanRecapture
        captureView.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        captureView.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        captureView.syntheticCursorEnabled = syntheticCursorEnabled
        captureView.presentationTier = presentationTier
        captureView.maxDrawableSize = maxDrawableSize
        captureView.prefersLocalAspectFitPresentation = prefersLocalAspectFitPresentation
        captureView.ignoresSafeArea = ignoresSafeArea

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
