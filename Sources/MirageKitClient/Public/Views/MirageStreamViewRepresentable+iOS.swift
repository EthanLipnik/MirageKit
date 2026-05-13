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

/// SwiftUI bridge that embeds the UIKit stream renderer and input capture controller.
public struct MirageStreamViewRepresentable: UIViewControllerRepresentable {
    /// Logical stream session identifier.
    public let streamID: StreamID
    /// Media stream identifier used for decoded frames and cursor/input routing.
    public let mediaStreamID: StreamID
    /// Optional host content rect override used when presenting a cropped app/window stream.
    public let contentRectOverride: CGRect?

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

    /// Host-authoritative maximum render frame rate for this stream.
    public var preferredMaximumRenderFPS: Int?

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize?

    /// Whether the stream should present locally using aspect fit.
    public var prefersLocalAspectFitPresentation: Bool

    /// Whether the UIKit stream view should extend through platform safe areas.
    public var ignoresSafeArea: Bool

    /// Creates a UIKit-backed stream view with rendering, cursor, input, and action bindings.
    public init(
        streamID: StreamID,
        mediaStreamID: StreamID,
        contentRectOverride: CGRect? = nil,
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
        preferredMaximumRenderFPS: Int? = nil,
        maxDrawableSize: CGSize? = nil,
        prefersLocalAspectFitPresentation: Bool = false,
        ignoresSafeArea: Bool = true
    ) {
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
        self.contentRectOverride = contentRectOverride
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
        self.preferredMaximumRenderFPS = preferredMaximumRenderFPS
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
            onInputEvent: { context.coordinator.onInputEvent?($0) },
            onDrawableMetricsChanged: { context.coordinator.onDrawableMetricsChanged?($0) },
            onContainerSizeChanged: { context.coordinator.onContainerSizeChanged?($0) },
            onRefreshRateOverrideChange: { context.coordinator.onRefreshRateOverrideChange?($0) },
            onBecomeActive: { context.coordinator.onBecomeActive?() },
            onHardwareKeyboardPresenceChanged: { context.coordinator.onHardwareKeyboardPresenceChanged?($0) },
            onSoftwareKeyboardVisibilityChanged: { context.coordinator.onSoftwareKeyboardVisibilityChanged?($0) },
            onDirectTouchActivity: { context.coordinator.onDirectTouchActivity?() },
            onClientShortcut: onClientShortcut,
            onActionTriggered: onActionTriggered,
            onPencilGestureAction: onPencilGestureAction,
            onDictationStateChanged: { context.coordinator.onDictationStateChanged?($0) },
            onDictationError: { context.coordinator.onDictationError?($0) },
            onDictationInputLevelChanged: { context.coordinator.onDictationInputLevelChanged?($0) },
            onResolvedPointerLockStateChanged: { context.coordinator.onResolvedPointerLockStateChanged?($0) }
        )
        controller.updateState(MirageStreamViewControllerState(representable: self))
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
            onInputEvent: { context.coordinator.onInputEvent?($0) },
            onDrawableMetricsChanged: { context.coordinator.onDrawableMetricsChanged?($0) },
            onContainerSizeChanged: { context.coordinator.onContainerSizeChanged?($0) },
            onRefreshRateOverrideChange: { context.coordinator.onRefreshRateOverrideChange?($0) },
            onBecomeActive: { context.coordinator.onBecomeActive?() },
            onHardwareKeyboardPresenceChanged: { context.coordinator.onHardwareKeyboardPresenceChanged?($0) },
            onSoftwareKeyboardVisibilityChanged: { context.coordinator.onSoftwareKeyboardVisibilityChanged?($0) },
            onDirectTouchActivity: { context.coordinator.onDirectTouchActivity?() },
            onClientShortcut: onClientShortcut,
            onActionTriggered: onActionTriggered,
            onPencilGestureAction: onPencilGestureAction,
            onDictationStateChanged: { context.coordinator.onDictationStateChanged?($0) },
            onDictationError: { context.coordinator.onDictationError?($0) },
            onDictationInputLevelChanged: { context.coordinator.onDictationInputLevelChanged?($0) },
            onResolvedPointerLockStateChanged: { context.coordinator.onResolvedPointerLockStateChanged?($0) }
        )

        uiViewController.updateState(MirageStreamViewControllerState(representable: self))
    }

    static func releaseCachedControllerIfPossible(
        streamID: StreamID,
        sessionStore: MirageClientSessionStore
    ) {
        guard sessionStore.sessionByStreamID(streamID) == nil else { return }
        MirageStreamViewControllerCache.shared.releaseController(for: streamID)
    }
}

/// Immutable state transferred from SwiftUI into the cached UIKit stream controller.
package struct MirageStreamViewControllerState {
    let streamID: StreamID
    let mediaStreamID: StreamID
    let contentRectOverride: CGRect?
    let directTouchInputMode: MirageDirectTouchInputMode
    let softwareKeyboardVisible: Bool
    let pencilGestureConfiguration: MiragePencilGestureConfiguration
    let clientShortcuts: [MirageClientShortcut]
    let actions: [MirageAction]
    let dictationToggleRequestID: UInt64
    let dictationMode: MirageDictationMode
    let dictationLocalePreference: MirageDictationLocalePreference
    let hideSystemCursor: Bool
    let cursorStore: MirageClientCursorStore?
    let cursorPositionStore: MirageClientCursorPositionStore?
    let desktopSessionID: UUID?
    let hasPresentedFrameForActivationRecovery: Bool
    let cursorLockEnabled: Bool
    let allowsExtendedDesktopCursorBounds: Bool
    let cursorLockCanRecapture: Bool
    let onCursorLockEscapeRequested: (() -> Void)?
    let onCursorLockRecaptureRequested: (() -> Void)?
    let syntheticCursorEnabled: Bool
    let presentationTier: StreamPresentationTier
    let preferredMaximumRenderFPS: Int?
    let maxDrawableSize: CGSize?
    let prefersLocalAspectFitPresentation: Bool
    let ignoresSafeArea: Bool

    init(representable: MirageStreamViewRepresentable) {
        streamID = representable.streamID
        mediaStreamID = representable.mediaStreamID
        contentRectOverride = representable.contentRectOverride
        directTouchInputMode = representable.directTouchInputMode
        softwareKeyboardVisible = representable.softwareKeyboardVisible
        pencilGestureConfiguration = representable.pencilGestureConfiguration
        clientShortcuts = representable.clientShortcuts
        actions = representable.actions
        dictationToggleRequestID = representable.dictationToggleRequestID
        dictationMode = representable.dictationMode
        dictationLocalePreference = representable.dictationLocalePreference
        hideSystemCursor = representable.hideSystemCursor
        cursorStore = representable.cursorStore
        cursorPositionStore = representable.cursorPositionStore
        desktopSessionID = representable.desktopSessionID
        hasPresentedFrameForActivationRecovery = representable.hasPresentedFrameForActivationRecovery
        cursorLockEnabled = representable.cursorLockEnabled
        allowsExtendedDesktopCursorBounds = representable.allowsExtendedDesktopCursorBounds
        cursorLockCanRecapture = representable.cursorLockCanRecapture
        onCursorLockEscapeRequested = representable.onCursorLockEscapeRequested
        onCursorLockRecaptureRequested = representable.onCursorLockRecaptureRequested
        syntheticCursorEnabled = representable.syntheticCursorEnabled
        presentationTier = representable.presentationTier
        preferredMaximumRenderFPS = representable.preferredMaximumRenderFPS
        maxDrawableSize = representable.maxDrawableSize
        prefersLocalAspectFitPresentation = representable.prefersLocalAspectFitPresentation
        ignoresSafeArea = representable.ignoresSafeArea
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
#endif
