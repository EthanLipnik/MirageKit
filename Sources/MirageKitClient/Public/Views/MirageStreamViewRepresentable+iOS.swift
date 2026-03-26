//
//  MirageStreamViewRepresentable+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import AVFoundation
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

    /// Dictation behavior selection for latency vs finalization quality.
    public var dictationMode: MirageDictationMode

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

    /// Active vs passive presentation tier.
    public var presentationTier: StreamPresentationTier

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize?

    /// Called once when the underlying view controller is created, providing
    /// the `AVSampleBufferDisplayLayer` for external use (e.g. PiP).
    public var onDisplayLayerReady: ((AVSampleBufferDisplayLayer) -> Void)?

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
        pencilInputMode: MiragePencilInputMode = .drawingTablet,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        cursorLockEnabled: Bool = false,
        presentationTier: StreamPresentationTier = .activeLive,
        maxDrawableSize: CGSize? = nil,
        onDisplayLayerReady: ((AVSampleBufferDisplayLayer) -> Void)? = nil
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
        self.dictationMode = dictationMode
        self.cursorLockEnabled = cursorLockEnabled
        self.presentationTier = presentationTier
        self.maxDrawableSize = maxDrawableSize
        self.onDisplayLayerReady = onDisplayLayerReady
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
            onDictationError: onDictationError
        )
    }

    public func makeUIViewController(context: Context) -> MirageStreamViewController {
        let controller = MirageStreamViewController()
        controller.configureCallbacks(
            onInputEvent: context.coordinator.handleInputEvent,
            onDrawableMetricsChanged: context.coordinator.handleDrawableMetricsChanged,
            onRefreshRateOverrideChange: context.coordinator.handleRefreshRateOverrideChange,
            onBecomeActive: context.coordinator.handleBecomeActive,
            onHardwareKeyboardPresenceChanged: context.coordinator.handleHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: context.coordinator.handleSoftwareKeyboardVisibilityChanged,
            onDirectTouchActivity: context.coordinator.handleDirectTouchActivity,
            onDictationStateChanged: context.coordinator.handleDictationStateChanged,
            onDictationError: context.coordinator.handleDictationError
        )
        controller.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize
        )
        onDisplayLayerReady?(controller.sampleBufferDisplayLayer)
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
        context.coordinator.noteRepresentableUpdate(for: streamID)

        uiViewController.updateState(
            streamID: streamID,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            pencilInputMode: pencilInputMode,
            dictationToggleRequestID: dictationToggleRequestID,
            dictationMode: dictationMode,
            cursorStore: cursorStore,
            cursorPositionStore: cursorPositionStore,
            cursorLockEnabled: cursorLockEnabled,
            presentationTier: presentationTier,
            maxDrawableSize: maxDrawableSize
        )
    }
}

public final class MirageStreamViewController: UIViewController {
    /// The backing sample buffer display layer used for video presentation.
    /// Exposed for Picture-in-Picture controller integration.
    public var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        captureView.metalView.displayLayer
    }

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

    func configureCallbacks(
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)?,
        onBecomeActive: (() -> Void)?,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?,
        onDirectTouchActivity: (() -> Void)?,
        onDictationStateChanged: ((Bool) -> Void)?,
        onDictationError: ((String) -> Void)?
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
    }

    func updateState(
        streamID: StreamID,
        directTouchInputMode: MirageDirectTouchInputMode,
        softwareKeyboardVisible: Bool,
        pencilInputMode: MiragePencilInputMode,
        dictationToggleRequestID: UInt64,
        dictationMode: MirageDictationMode,
        cursorStore: MirageClientCursorStore?,
        cursorPositionStore: MirageClientCursorPositionStore?,
        cursorLockEnabled: Bool,
        presentationTier: StreamPresentationTier,
        maxDrawableSize: CGSize?
    ) {
        // Set stream ID first so cursor router registration is ready
        // before cursorStore/cursorPositionStore didSet triggers refreshCursorIfNeeded.
        captureView.streamID = streamID
        captureView.directTouchInputMode = directTouchInputMode
        captureView.softwareKeyboardVisible = softwareKeyboardVisible
        captureView.pencilInputMode = pencilInputMode
        captureView.dictationToggleRequestID = dictationToggleRequestID
        captureView.dictationMode = dictationMode
        captureView.cursorStore = cursorStore
        captureView.cursorPositionStore = cursorPositionStore
        captureView.cursorLockEnabled = cursorLockEnabled
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
