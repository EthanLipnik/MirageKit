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

    /// Cursor position store for secondary display sync.
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

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool

    /// Whether direct touch uses a draggable virtual cursor.
    public var usesVirtualTrackpad: Bool

    /// Direct-touch behavior mode override.
    public var directTouchInputMode: MirageDirectTouchInputMode?

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

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

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
        dockSnapEnabled: Bool = false,
        usesVirtualTrackpad: Bool = false,
        directTouchInputMode: MirageDirectTouchInputMode? = nil,
        softwareKeyboardVisible: Bool = false,
        pencilInputMode: MiragePencilInputMode = .drawingTablet,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        cursorLockEnabled: Bool = false,
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
        self.dockSnapEnabled = dockSnapEnabled
        self.usesVirtualTrackpad = usesVirtualTrackpad
        self.directTouchInputMode = directTouchInputMode
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.pencilInputMode = pencilInputMode
        self.dictationToggleRequestID = dictationToggleRequestID
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.dictationMode = dictationMode
        self.cursorLockEnabled = cursorLockEnabled
        self.maxDrawableSize = maxDrawableSize
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onBecomeActive: onBecomeActive
        )
    }

    public func makeUIViewController(context: Context) -> MirageStreamViewController {
        let controller = MirageStreamViewController()
        controller.update(
            streamID: streamID,
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: onDirectTouchActivity,
            dockSnapEnabled: dockSnapEnabled,
            usesVirtualTrackpad: usesVirtualTrackpad,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            onDictationStateChanged: onDictationStateChanged,
            onDictationError: onDictationError,
            dictationMode: dictationMode,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            maxDrawableSize: maxDrawableSize
        )
        return controller
    }

    public func updateUIViewController(_ uiViewController: MirageStreamViewController, context: Context) {
        // Update coordinator's callbacks in case they changed
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onBecomeActive = onBecomeActive

        uiViewController.update(
            streamID: streamID,
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: onDirectTouchActivity,
            dockSnapEnabled: dockSnapEnabled,
            usesVirtualTrackpad: usesVirtualTrackpad,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            onDictationStateChanged: onDictationStateChanged,
            onDictationError: onDictationError,
            dictationMode: dictationMode,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            maxDrawableSize: maxDrawableSize
        )
    }
}

public final class MirageStreamViewController: UIViewController {
    private let captureView = InputCapturingView(frame: .zero)
    private var pointerLockRequested: Bool = false {
        didSet {
            guard pointerLockRequested != oldValue else { return }
            setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    private var pointerLockObserver: NSObjectProtocol?
    private var lastPointerLockActive: Bool?

    override public func loadView() {
        view = captureView
    }

    override public var prefersPointerLocked: Bool {
        pointerLockRequested
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersPointerLocked()
        startPointerLockObserverIfNeeded()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPointerLockObserver()
    }

    func update(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)?,
        onBecomeActive: (() -> Void)?,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?,
        onDirectTouchActivity: (() -> Void)?,
        dockSnapEnabled: Bool,
        usesVirtualTrackpad: Bool,
        directTouchInputMode: MirageDirectTouchInputMode?,
        softwareKeyboardVisible: Bool,
        pencilInputMode: MiragePencilInputMode,
        dictationToggleRequestID: UInt64,
        onDictationStateChanged: ((Bool) -> Void)?,
        onDictationError: ((String) -> Void)?,
        dictationMode: MirageDictationMode,
        cursorStore: MirageClientCursorStore?,
        cursorPositionStore: MirageClientCursorPositionStore?,
        cursorLockEnabled: Bool,
        maxDrawableSize: CGSize?
    ) {
        captureView.onInputEvent = onInputEvent
        captureView.onDrawableMetricsChanged = onDrawableMetricsChanged
        captureView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        captureView.onBecomeActive = onBecomeActive
        captureView.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        captureView.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        captureView.onDirectTouchActivity = onDirectTouchActivity
        captureView.dockSnapEnabled = dockSnapEnabled
        captureView.directTouchInputMode = directTouchInputMode ??
            (usesVirtualTrackpad ? .dragCursor : .normal)
        captureView.softwareKeyboardVisible = softwareKeyboardVisible
        captureView.pencilInputMode = pencilInputMode
        captureView.dictationToggleRequestID = dictationToggleRequestID
        captureView.onDictationStateChanged = onDictationStateChanged
        captureView.onDictationError = onDictationError
        captureView.dictationMode = dictationMode
        captureView.cursorStore = cursorStore
        captureView.cursorPositionStore = cursorPositionStore
        captureView.cursorLockEnabled = cursorLockEnabled
        captureView.maxDrawableSize = maxDrawableSize
        // Set stream ID for direct frame cache access (bypasses all actor machinery)
        captureView.streamID = streamID

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
        let isLocked = view.window?.windowScene?.pointerLockState?.isLocked ?? false
        captureView.pointerLockActive = isLocked
        if lastPointerLockActive != isLocked {
            lastPointerLockActive = isLocked
            if pointerLockRequested, !isLocked {
                MirageLogger.client("Pointer lock not active for scene.")
            }
        }
    }
}
#endif
