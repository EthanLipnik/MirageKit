//
//  MirageStreamContentView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// Streaming content view that handles input, resizing, and focus.
///
/// This view bridges `MirageStreamViewRepresentable` with a `MirageClientSessionStore`
/// to coordinate focus, resize events, and input forwarding.
@MainActor
public struct MirageStreamContentView: View {
    /// UserDefaults key for enabling stream navigation gestures.
    public static let navigationGesturesDefaultsKey = "navigationGesturesEnabled"

    /// UserDefaults key for whether local keyboard appearance resizes stream content.
    public static let keyboardAvoidanceDefaultsKey = "keyboardAvoidanceEnabled"

    /// Maximum wait for host acknowledgement after app-window resize dispatch.
    static let appResizeAckTimeout: Duration = .seconds(3)

    #if os(iOS) || os(visionOS)
    /// Foreground transition debounce before dispatching local resize updates.
    static let foregroundResizeDebounce: Duration = .milliseconds(1250)
    #endif

    /// Stream session rendered by this content view.
    public let session: MirageStreamSessionState
    /// Store that owns decoded frames, cursor state, focus, and resize state for active streams.
    public let sessionStore: MirageClientSessionStore
    /// Client service used to send input, resize, dictation, and action messages.
    public let clientService: MirageClientService
    /// Whether the session represents desktop streaming rather than app/window streaming.
    public let isDesktopStream: Bool
    /// Desktop stream mode when `isDesktopStream` is true.
    public let desktopStreamMode: MirageDesktopStreamMode
    /// Cursor presentation policy for desktop streams.
    public let desktopCursorPresentation: MirageDesktopCursorPresentation
    /// Handler invoked when the user requests desktop-stream exit.
    public let onExitDesktopStream: (() -> Void)?
    /// Handler invoked when the dictation shortcut is triggered.
    public let onToggleDictationShortcut: (() -> Void)?
    /// Shortcut that exits a desktop stream.
    public let desktopExitShortcut: MirageClientShortcut
    /// Shortcut that remaps Escape for the active stream.
    public let escapeRemapShortcut: MirageClientShortcut
    /// Shortcut that toggles dictation.
    public let dictationShortcut: MirageClientShortcut
    /// Unified actions exposed through shortcuts, gestures, or stream controls.
    public let actions: [MirageAction]
    /// Handler invoked when a unified action is triggered.
    public let onActionTriggered: ((MirageAction) -> Void)?
    /// Handler invoked when hardware keyboard availability changes.
    public let onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    /// Handler invoked when software keyboard visibility changes.
    public let onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    /// Direct-touch translation mode for touch-capable clients.
    public let directTouchInputMode: MirageDirectTouchInputMode
    /// Whether the software keyboard should currently be visible.
    public let softwareKeyboardVisible: Bool
    /// Apple Pencil hardware gesture mapping.
    public let pencilGestureConfiguration: MiragePencilGestureConfiguration
    /// Monotonic request identifier used to trigger dictation toggles.
    public let dictationToggleRequestID: UInt64
    /// Handler invoked when dictation starts or stops.
    public let onDictationStateChanged: ((Bool) -> Void)?
    /// Handler invoked with user-facing dictation errors.
    public let onDictationError: ((String) -> Void)?
    /// Handler invoked when the platform resolves pointer-lock state.
    public let onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?
    /// Dictation behavior for live versus finalized output.
    public let dictationMode: MirageDictationMode
    /// Dictation locale selection.
    public let dictationLocalePreference: MirageDictationLocalePreference
    /// Optional override for desktop cursor lock enablement.
    public let desktopCursorLockEnabledOverride: Bool?
    /// Whether a temporary cursor unlock can be recaptured.
    public let desktopCursorLockCanRecapture: Bool
    /// Handler invoked when cursor lock should escape temporarily.
    public let onCursorLockEscapeRequested: (() -> Void)?
    /// Handler invoked when cursor lock should be recaptured.
    public let onCursorLockRecaptureRequested: (() -> Void)?
    /// Whether app streams should use the host window resolution directly.
    public let useHostResolution: Bool
    /// Whether macOS system shortcuts should be forwarded through Input Monitoring.
    public let macSystemShortcutForwardingEnabled: Bool
    /// Whether keyboard occlusion should shrink local stream content on touch platforms.
    public let keyboardAvoidanceEnabled: Bool
    /// Optional cap for drawable pixel dimensions.
    public let maxDrawableSize: CGSize?
    /// Handler invoked before the native stream window closes.
    public let onWindowWillClose: (() -> Void)?
    /// Whether the embedded platform renderer should extend through safe areas.
    public let ignoresSafeArea: Bool

    /// Resize holdoff task used during foreground transitions (iOS).
    @State var resizeHoldoffTask: Task<Void, Never>?

    /// Foreground/background gating for local resize dispatch.
    @State var resizeLifecycleState: DesktopResizeLifecycleState = .active

    /// Whether the client is currently waiting for host to complete resize.
    @State var isResizing: Bool = false
    #if os(iOS) || os(visionOS)
    @Environment(\.scenePhase) var scenePhase
    #endif
    @State var displayResolutionTask: Task<Void, Never>?
    @State var pendingDisplayResolutionDispatchTarget: CGSize = .zero
    /// Tracks the last requested client display resolution, not the host's encoded output size.
    @State var lastSentDisplayResolution: CGSize = .zero
    @State var streamScaleTask: Task<Void, Never>?
    @State var lastSentEncodedPixelSize: CGSize = .zero
    @State var awaitingAppResizeAck: Bool = false
    @State var appResizeBaselineAcknowledgement: MirageClientService.StreamStartAcknowledgement?
    @State var appResizeAckTimeoutTask: Task<Void, Never>?
    @State var latestContainerDisplaySize: CGSize = .zero
    @State var latestDrawableViewSize: CGSize = .zero
    @State var localKeyboardOcclusionActive = false
    #if canImport(UIKit)
    @State var suppressNextOrderedPasteKeyUp = false
    #endif

    /// Creates a streaming content view backed by a session store and client service.
    /// - Parameters:
    ///   - session: Session metadata describing the stream.
    ///   - sessionStore: Session store that tracks frames, focus, and resize updates.
    ///   - clientService: The client service used to send input and resize events.
    ///   - isDesktopStream: Whether the stream represents a desktop session.
    ///   - desktopStreamMode: Desktop stream mode (mirrored vs secondary display).
    ///   - onExitDesktopStream: Optional handler invoked after holding Escape for 5 seconds.
    ///   - onToggleDictationShortcut: Optional handler for the dictation toggle shortcut.
    ///   - dictationShortcut: Client shortcut used for dictation toggle.
    ///   - onHardwareKeyboardPresenceChanged: Optional handler for hardware keyboard availability.
    ///   - onSoftwareKeyboardVisibilityChanged: Optional handler for software keyboard visibility.
    ///   - directTouchInputMode: Direct-touch behavior mode for touch clients.
    ///   - softwareKeyboardVisible: Whether the software keyboard should be visible.
    ///   - pencilGestureConfiguration: Apple Pencil hardware gesture mapping.
    ///   - dictationToggleRequestID: Increments to request a dictation toggle on iOS/visionOS.
    ///   - onDictationStateChanged: Optional callback for dictation start/stop state.
    ///   - onDictationError: Optional callback for user-facing dictation errors.
    ///   - onResolvedPointerLockStateChanged: Optional callback when UIKit resolves pointer lock.
    ///   - dictationMode: Dictation behavior for realtime versus finalized output.
    ///   - dictationLocalePreference: Dictation language selection.
    ///   - macSystemShortcutForwardingEnabled: Whether macOS should use Input Monitoring backed shortcut forwarding.
    ///   - onWindowWillClose: Optional macOS callback when the host window is closing.
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        desktopStreamMode: MirageDesktopStreamMode = .unified,
        desktopCursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor,
        onExitDesktopStream: (() -> Void)? = nil,
        onToggleDictationShortcut: (() -> Void)? = nil,
        desktopExitShortcut: MirageClientShortcut = .defaultDesktopExit,
        escapeRemapShortcut: MirageClientShortcut = .defaultEscapeRemap,
        dictationShortcut: MirageClientShortcut = .defaultDictationToggle,
        actions: [MirageAction] = [],
        onActionTriggered: ((MirageAction) -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        directTouchInputMode: MirageDirectTouchInputMode = .defaultForCurrentDevice,
        softwareKeyboardVisible: Bool = false,
        pencilGestureConfiguration: MiragePencilGestureConfiguration = .default,
        dictationToggleRequestID: UInt64 = 0,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)? = nil,
        dictationMode: MirageDictationMode = .best,
        dictationLocalePreference: MirageDictationLocalePreference = .system,
        desktopCursorLockEnabledOverride: Bool? = nil,
        desktopCursorLockCanRecapture: Bool = false,
        onCursorLockEscapeRequested: (() -> Void)? = nil,
        onCursorLockRecaptureRequested: (() -> Void)? = nil,
        useHostResolution: Bool = false,
        macSystemShortcutForwardingEnabled: Bool = true,
        keyboardAvoidanceEnabled: Bool = true,
        maxDrawableSize: CGSize? = nil,
        onWindowWillClose: (() -> Void)? = nil,
        ignoresSafeArea: Bool = true
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.clientService = clientService
        self.isDesktopStream = isDesktopStream
        self.desktopStreamMode = desktopStreamMode
        self.desktopCursorPresentation = desktopCursorPresentation
        self.onExitDesktopStream = onExitDesktopStream
        self.onToggleDictationShortcut = onToggleDictationShortcut
        self.desktopExitShortcut = desktopExitShortcut
        self.escapeRemapShortcut = escapeRemapShortcut
        self.dictationShortcut = dictationShortcut
        self.actions = actions
        self.onActionTriggered = onActionTriggered
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.directTouchInputMode = directTouchInputMode
        self.softwareKeyboardVisible = softwareKeyboardVisible
        self.pencilGestureConfiguration = pencilGestureConfiguration
        self.dictationToggleRequestID = dictationToggleRequestID
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
        self.dictationMode = dictationMode
        self.dictationLocalePreference = dictationLocalePreference
        self.desktopCursorLockEnabledOverride = desktopCursorLockEnabledOverride
        self.desktopCursorLockCanRecapture = desktopCursorLockCanRecapture
        self.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        self.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        self.useHostResolution = useHostResolution
        self.macSystemShortcutForwardingEnabled = macSystemShortcutForwardingEnabled
        self.keyboardAvoidanceEnabled = keyboardAvoidanceEnabled
        self.maxDrawableSize = maxDrawableSize
        self.onWindowWillClose = onWindowWillClose
        self.ignoresSafeArea = ignoresSafeArea
    }
}

// MARK: - Presentation State

extension MirageStreamContentView {
    /// Whether the client should lock the local cursor while forwarding desktop input.
    var desktopCursorLockEnabled: Bool {
        desktopCursorLockEnabledOverride ??
            (isDesktopStream && desktopCursorPresentation.locksClientCursor(for: desktopStreamMode))
    }

    /// Whether Mirage should draw its own cursor instead of relying solely on the system cursor.
    var syntheticCursorEnabled: Bool {
        !isDesktopStream ||
            desktopCursorPresentation.rendersSyntheticClientCursor ||
            (desktopCursorLockEnabled && !desktopCursorPresentation.capturesHostCursor)
    }

    /// Whether the platform cursor should be hidden while the host cursor or synthetic cursor is authoritative.
    var desktopLocalCursorHidden: Bool {
        isDesktopStream && desktopCursorPresentation.hidesLocalCursor
    }

    /// Whether cursor math can extend outside the visible content rect for secondary desktop streams.
    var allowsExtendedDesktopCursorBounds: Bool {
        isDesktopStream && desktopStreamMode == .secondary
    }

    /// Host virtual display dimensions in points for 1:1 cursor delta normalization.
    /// Derived from the stream pixel resolution divided by the client's backing scale
    /// (which matches the host's virtual display backing scale since the client
    /// requested the display at that scale).
    var hostDisplayPointSize: CGSize? {
        #if os(macOS)
        guard let resolution = clientService.desktopStreamResolution,
              resolution.width > 0, resolution.height > 0 else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return CGSize(
            width: resolution.width / scale,
            height: resolution.height / scale
        )
        #else
        return nil
        #endif
    }

    /// Whether local presentation state should temporarily prevent window-size driven resize requests.
    var suppressesWindowDrivenResizeForLocalPresentation: Bool {
        (isDesktopStream && (useHostResolution || clientService.desktopCaptureSource == .mainDisplayFallback)) ||
            (keyboardAvoidanceEnabled && (softwareKeyboardVisible || localKeyboardOcclusionActive))
    }

    /// Whether the stream should preserve source aspect instead of resizing the host/window to fill.
    var prefersLocalAspectFitPresentation: Bool {
        suppressesWindowDrivenResizeForLocalPresentation || appStreamPrefersAspectFitPresentation
    }

    #if os(macOS)
    /// macOS container sizing mode chosen from the current resize policy.
    var macOSContainerSizingMode: MirageStreamContainerSizingMode {
        isDesktopStream && !prefersLocalAspectFitPresentation ? .viewBounds : .contentLayout
    }
    #endif

    /// Whether an app-window stream should be aspect-fit because its content ratio differs from the container.
    var appStreamPrefersAspectFitPresentation: Bool {
        guard !isDesktopStream else { return false }
        let containerSize = latestContainerDisplaySize.width > 0 && latestContainerDisplaySize.height > 0
            ? latestContainerDisplaySize
            : latestDrawableViewSize
        guard containerSize.width > 0,
              containerSize.height > 0,
              let streamContentSize = appStreamContentReferenceSize,
              streamContentSize.width > 0,
              streamContentSize.height > 0 else {
            return false
        }
        let containerAspectRatio = containerSize.width / containerSize.height
        let streamAspectRatio = streamContentSize.width / streamContentSize.height
        let relativeAspectDelta = abs(streamAspectRatio - containerAspectRatio) / max(0.001, containerAspectRatio)
        return relativeAspectDelta > 0.03
    }

    /// Best known app-window content size used to decide between fill and aspect-fit presentation.
    var appStreamContentReferenceSize: CGSize? {
        if let atlasRegion = session.atlasRegion?.pixelRect,
           atlasRegion.width > 0,
           atlasRegion.height > 0 {
            return atlasRegion.size
        }

        if let acknowledgement = clientService.appStreamStartAcknowledgementByStreamID[session.streamID] ??
            clientService.appStreamStartAcknowledgementByStreamID[session.mediaStreamID],
            acknowledgement.width > 0,
            acknowledgement.height > 0 {
            return CGSize(width: acknowledgement.width, height: acknowledgement.height)
        }

        let windowSize = session.window.frame.size
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }
        return windowSize
    }

    /// Render FPS ceiling chosen from observed cadence, explicit overrides, and display capability.
    var preferredMaximumRenderFPS: Int {
        clientService.observedFrameRateByStream[session.streamID] ??
            clientService.refreshRateOverridesByStream[session.streamID] ??
            clientService.screenMaxRefreshRate
    }

    #if os(iOS) || os(visionOS)
    /// Active desktop session identity forwarded into the UIKit stream controller for recovery checks.
    var activeDesktopSessionID: UUID? {
        guard isDesktopStream, clientService.desktopStreamID == session.streamID else { return nil }
        return clientService.desktopSessionID
    }
    #endif
}

// MARK: - Stream State

extension MirageStreamContentView {
    /// Whether this rendered session still belongs to the client's active stream set.
    var isCurrentStreamActive: Bool {
        if clientService.desktopStreamID == session.streamID || clientService.desktopStreamID == session.mediaStreamID {
            return true
        }
        if clientService.activeStreams.contains(where: { stream in
            stream.id == session.streamID || stream.mediaStreamID == session.mediaStreamID
        }) {
            return true
        }
        return clientService.activeStreamIDsForFiltering.contains(session.streamID) ||
            clientService.activeStreamIDsForFiltering.contains(session.mediaStreamID)
    }

    /// Whether input from this view can be sent over the active host connection.
    var canSendInputToHost: Bool {
        guard case .connected = clientService.connectionState else { return false }
        return isCurrentStreamActive
    }

    /// macOS input gate that also requires this stream to own focus in the session store.
    var macOSInputEnabled: Bool {
        canSendInputToHost && sessionStore.focusedSessionID == session.id
    }

    /// Current presentation tier for frame scheduling and first-frame readiness.
    var streamPresentationTier: StreamPresentationTier {
        sessionStore.presentationTier(for: session)
    }

    /// Shortcuts reserved locally by the stream before forwarding other key events to the host.
    var clientReservedShortcuts: [MirageClientShortcut] {
        [desktopExitShortcut, escapeRemapShortcut, dictationShortcut]
    }

    func focusCurrentStreamForInputIfNeeded(force: Bool = false) {
        guard force || sessionStore.focusedSessionID != session.id else { return }
        sessionStore.setFocusedSession(session.id)
        clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
    }

    /// Whether the stream has produced enough frame state to hide the initial black loading cover.
    var isReadyForInitialPresentation: Bool {
        switch streamPresentationTier {
        case .activeLive:
            session.hasDecodedFrame || session.hasPresentedFrame
        case .passiveSnapshot:
            session.hasDecodedFrame || session.hasPresentedFrame
        }
    }

    /// Whether the stream is waiting for the first decoded frame after a desktop resize.
    var awaitingPostResizeFirstFrame: Bool {
        sessionStore.postResizeAwaitingFirstFrameStreamIDs.contains(session.streamID)
    }

    /// Shared desktop resize coordinator owned by the client service.
    var desktopResizeCoordinator: DesktopResizeCoordinator {
        clientService.desktopResizeCoordinator
    }

    /// Blur applied while desktop resize recovery masks unstable frame presentation.
    var resizeBlurRadius: CGFloat {
        if isDesktopStream, awaitingPostResizeFirstFrame { return 24 }
        if isDesktopStream, desktopResizeCoordinator.isResizing || desktopResizeCoordinator.maskActive { return 20 }
        return 0
    }
}

// MARK: - Resize Acknowledgements

extension MirageStreamContentView {
    func handleAppStreamStartAcknowledgement(
        _ acknowledgement: MirageClientService.StreamStartAcknowledgement?
    ) {
        guard !isDesktopStream else { return }
        guard awaitingAppResizeAck,
              isMeaningfulAppResizeAcknowledgement(
                  acknowledgement,
                  comparedTo: appResizeBaselineAcknowledgement
              ) else { return }
        if let minimumSize = sessionStore.sessionMinSizes[session.id] {
            handleResizeAcknowledgement(minimumSize)
        }
    }

    func handleResizeAcknowledgement(_ minSize: CGSize?) {
        guard !isDesktopStream else { return }
        guard awaitingAppResizeAck else { return }
        guard let minSize, minSize.width > 0, minSize.height > 0 else { return }
        let acknowledgement = clientService.appStreamStartAcknowledgementByStreamID[session.streamID]
        guard isMeaningfulAppResizeAcknowledgement(
            acknowledgement,
            comparedTo: appResizeBaselineAcknowledgement
        ) else { return }
        finishAppResizeAwaitingAck()
    }
}
