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
    public let session: MirageStreamSessionState
    public let sessionStore: MirageClientSessionStore
    public let clientService: MirageClientService
    public let isDesktopStream: Bool
    public let desktopStreamMode: MirageDesktopStreamMode
    public let desktopCursorPresentation: MirageDesktopCursorPresentation
    public let onExitDesktopStream: (() -> Void)?
    public let onToggleDictationShortcut: (() -> Void)?
    public let desktopExitShortcut: MirageClientShortcut
    public let escapeRemapShortcut: MirageClientShortcut
    public let dictationShortcut: MirageClientShortcut
    public let actions: [MirageAction]
    public let onActionTriggered: ((MirageAction) -> Void)?
    public let onInputActivity: ((MirageInputEvent) -> Void)?
    public let onDirectTouchActivity: (() -> Void)?
    public let onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    public let onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    public let directTouchInputMode: MirageDirectTouchInputMode
    public let softwareKeyboardVisible: Bool
    public let pencilGestureConfiguration: MiragePencilGestureConfiguration
    public let dictationToggleRequestID: UInt64
    public let onDictationStateChanged: ((Bool) -> Void)?
    public let onDictationError: ((String) -> Void)?
    public let onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?
    public let dictationMode: MirageDictationMode
    public let dictationLocalePreference: MirageDictationLocalePreference
    public let desktopCursorLockEnabledOverride: Bool?
    public let desktopCursorLockCanRecapture: Bool
    public let onCursorLockEscapeRequested: (() -> Void)?
    public let onCursorLockRecaptureRequested: (() -> Void)?
    public let useHostResolution: Bool
    public let keyboardAvoidanceEnabled: Bool
    public let maxDrawableSize: CGSize?
    public let onWindowWillClose: (() -> Void)?
    private let appResizeAckTimeout: Duration = .seconds(3)
    private let desktopResizeAckHardTimeout: Duration = .seconds(8)
    private let desktopResizeConvergenceTolerance: CGFloat = 4
    private let desktopResizeSendDebounce: Duration = .milliseconds(120)

    /// Resize holdoff task used during foreground transitions (iOS).
    @State private var resizeHoldoffTask: Task<Void, Never>?

    /// Foreground/background gating for local resize dispatch.
    @State private var resizeLifecycleState: DesktopResizeLifecycleState = .active

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false
    @State private var desktopResizeMaskActive: Bool = false
    @State private var displayResolutionTask: Task<Void, Never>?
    @State private var pendingDisplayResolutionDispatchTarget: CGSize = .zero
    /// Tracks the last requested client display resolution, not the host's encoded output size.
    @State private var lastSentDisplayResolution: CGSize = .zero
    @State private var pendingAppDisplayResolutionCandidate: CGSize = .zero
    @State private var pendingAppDisplayResolutionCandidateSince: Date = .distantPast
    @State private var streamScaleTask: Task<Void, Never>?
    @State private var lastSentEncodedPixelSize: CGSize = .zero
    @State private var awaitingAppResizeAck: Bool = false
    @State private var appResizeBaselineAcknowledgement: MirageClientService.StreamStartAcknowledgement?
    @State private var appResizeAckTimeoutTask: Task<Void, Never>?
    @State private var awaitingDesktopResizeAck: Bool = false
    @State private var latestContainerDisplaySize: CGSize = .zero
    @State private var latestRequestedDisplaySize: CGSize = .zero
    @State private var latestDrawableViewSize: CGSize = .zero
    @State private var desktopResizeBaselineAcknowledgement: MirageClientService.StreamStartAcknowledgement?
    @State private var desktopResizeAcknowledgementStarted: Bool = false
    @State private var sentDesktopPostAckCorrection: Bool = false
    @State private var desktopResizeAckTimeoutTask: Task<Void, Never>?
    @State private var pendingDesktopDisplayResolutionAfterAck: CGSize = .zero

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
    ///   - onInputActivity: Optional callback invoked for each locally captured input event.
    ///   - onDirectTouchActivity: Optional callback invoked when direct finger touch input occurs.
    ///   - onHardwareKeyboardPresenceChanged: Optional handler for hardware keyboard availability.
    ///   - onSoftwareKeyboardVisibilityChanged: Optional handler for software keyboard visibility.
    ///   - directTouchInputMode: Direct-touch behavior mode for iPad and visionOS clients.
    ///   - softwareKeyboardVisible: Whether the software keyboard should be visible.
    ///   - pencilGestureConfiguration: Apple Pencil hardware gesture mapping.
    ///   - dictationToggleRequestID: Increments to request a dictation toggle on iOS/visionOS.
    ///   - onDictationStateChanged: Optional callback for dictation start/stop state.
    ///   - onDictationError: Optional callback for user-facing dictation errors.
    ///   - onResolvedPointerLockStateChanged: Optional callback when UIKit resolves pointer lock.
    ///   - dictationMode: Dictation behavior for realtime versus finalized output.
    ///   - dictationLocalePreference: Dictation language selection.
    ///   - onWindowWillClose: Optional macOS callback when the host window is closing.
    public init(
        session: MirageStreamSessionState,
        sessionStore: MirageClientSessionStore,
        clientService: MirageClientService,
        isDesktopStream: Bool = false,
        desktopStreamMode: MirageDesktopStreamMode = .unified,
        desktopCursorPresentation: MirageDesktopCursorPresentation = .emulatedCursor,
        onExitDesktopStream: (() -> Void)? = nil,
        onToggleDictationShortcut: (() -> Void)? = nil,
        desktopExitShortcut: MirageClientShortcut = .defaultDesktopExit,
        escapeRemapShortcut: MirageClientShortcut = .defaultEscapeRemap,
        dictationShortcut: MirageClientShortcut = .defaultDictationToggle,
        actions: [MirageAction] = [],
        onActionTriggered: ((MirageAction) -> Void)? = nil,
        onInputActivity: ((MirageInputEvent) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        directTouchInputMode: MirageDirectTouchInputMode = .normal,
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
        keyboardAvoidanceEnabled: Bool = true,
        maxDrawableSize: CGSize? = nil,
        onWindowWillClose: (() -> Void)? = nil
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
        self.onInputActivity = onInputActivity
        self.onDirectTouchActivity = onDirectTouchActivity
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
        self.keyboardAvoidanceEnabled = keyboardAvoidanceEnabled
        self.maxDrawableSize = maxDrawableSize
        self.onWindowWillClose = onWindowWillClose
    }

    private var desktopCursorLockEnabled: Bool {
        desktopCursorLockEnabledOverride ??
            (isDesktopStream && desktopCursorPresentation.locksClientCursor(for: desktopStreamMode))
    }

    private var syntheticCursorEnabled: Bool {
        !isDesktopStream || desktopCursorPresentation.rendersSyntheticClientCursor
    }

    private var desktopLocalCursorHidden: Bool {
        isDesktopStream && desktopCursorPresentation.hidesLocalCursor
    }

    private var allowsExtendedDesktopCursorBounds: Bool {
        isDesktopStream && desktopStreamMode == .secondary
    }

    /// Host virtual display dimensions in points for 1:1 cursor delta normalization.
    /// Derived from the stream pixel resolution divided by the client's backing scale
    /// (which matches the host's virtual display backing scale since the client
    /// requested the display at that scale).
    private var hostDisplayPointSize: CGSize? {
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

    private var prefersLocalAspectFitPresentation: Bool {
        !isDesktopStream && softwareKeyboardVisible && keyboardAvoidanceEnabled
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)
                .ignoresSafeArea()

            Group {
#if os(iOS) || os(visionOS)
                MirageStreamViewRepresentable(
                    streamID: session.streamID,
                    onInputEvent: { event in
                        sendInputEvent(event)
                    },
                    onDrawableMetricsChanged: { metrics in
                        scheduleDrawableMetricsChanged(metrics)
                    },
                    onContainerSizeChanged: { size in
                        scheduleContainerSizeChanged(size)
                    },
                    onRefreshRateOverrideChange: { override in
                        Task { @MainActor [clientService] in
                            await Task.yield()
                            do {
                                try await Task.sleep(for: .milliseconds(1))
                            } catch {
                                return
                            }
                            clientService.updateStreamRefreshRateOverride(
                                streamID: session.streamID,
                                maxRefreshRate: override
                            )
                        }
                    },
                    cursorStore: clientService.cursorStore,
                    cursorPositionStore: clientService.cursorPositionStore,
                    onBecomeActive: {
                        handleForegroundRecovery()
                    },
                    onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
                    onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
                    onDirectTouchActivity: onDirectTouchActivity,
                    directTouchInputMode: directTouchInputMode,
                    softwareKeyboardVisible: softwareKeyboardVisible,
                    pencilGestureConfiguration: pencilGestureConfiguration,
                    clientShortcuts: clientReservedShortcuts,
                    onClientShortcut: handleReservedShortcut,
                    actions: actions,
                    onActionTriggered: onActionTriggered,
                    onPencilGestureAction: handlePencilGestureAction,
                    dictationToggleRequestID: dictationToggleRequestID,
                    onDictationStateChanged: onDictationStateChanged,
                    onDictationError: onDictationError,
                    onResolvedPointerLockStateChanged: onResolvedPointerLockStateChanged,
                    dictationMode: dictationMode,
                    dictationLocalePreference: dictationLocalePreference,
                    hideSystemCursor: desktopLocalCursorHidden,
                    cursorLockEnabled: desktopCursorLockEnabled,
                    allowsExtendedDesktopCursorBounds: allowsExtendedDesktopCursorBounds,
                    cursorLockCanRecapture: desktopCursorLockCanRecapture,
                    onCursorLockEscapeRequested: onCursorLockEscapeRequested,
                    onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
                    syntheticCursorEnabled: syntheticCursorEnabled,
                    presentationTier: streamPresentationTier,
                    maxDrawableSize: maxDrawableSize,
                    prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation
                )
                .blur(radius: resizeBlurRadius)
#else
                MirageStreamViewRepresentable(
                    streamID: session.streamID,
                    onInputEvent: { event in
                        sendInputEvent(event)
                    },
                    onDrawableMetricsChanged: { metrics in
                        scheduleDrawableMetricsChanged(metrics)
                    },
                    onContainerSizeChanged: { size in
                        scheduleContainerSizeChanged(size)
                    },
                    onRefreshRateOverrideChange: { override in
                        Task { @MainActor [clientService] in
                            await Task.yield()
                            do {
                                try await Task.sleep(for: .milliseconds(1))
                            } catch {
                                return
                            }
                            clientService.updateStreamRefreshRateOverride(
                                streamID: session.streamID,
                                maxRefreshRate: override
                            )
                        }
                    },
                    cursorStore: clientService.cursorStore,
                    cursorPositionStore: clientService.cursorPositionStore,
                    hostDisplayPointSize: hostDisplayPointSize,
                    hideSystemCursor: desktopLocalCursorHidden,
                    cursorLockEnabled: desktopCursorLockEnabled,
                    allowsExtendedDesktopCursorBounds: allowsExtendedDesktopCursorBounds,
                    cursorLockCanRecapture: desktopCursorLockCanRecapture,
                    onCursorLockEscapeRequested: onCursorLockEscapeRequested,
                    onCursorLockRecaptureRequested: onCursorLockRecaptureRequested,
                    syntheticCursorEnabled: syntheticCursorEnabled,
                    inputEnabled: macOSInputEnabled,
                    presentationTier: streamPresentationTier,
                    maxDrawableSize: maxDrawableSize,
                    clientShortcuts: clientReservedShortcuts,
                    onClientShortcut: handleReservedShortcut,
                    actions: actions,
                    onActionTriggered: onActionTriggered
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: resizeBlurRadius)
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if !isReadyForInitialPresentation {
                Rectangle()
                    .fill(.black)
                    .overlay {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)

                            Text("Connecting to stream...")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .allowsHitTesting(false)
            } else if awaitingPostResizeFirstFrame {
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .overlay {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: sessionStore.sessionMinSizes[session.id]) { _, minSize in
            Task { @MainActor in
                await Task.yield()
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return
                }
                handleResizeAcknowledgement(minSize)
            }
        }
        .onChange(of: sessionStore.sessionMinSizeUpdateGenerations[session.id]) { _, _ in
            Task { @MainActor in
                await Task.yield()
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return
                }
                handleResizeAcknowledgement(sessionStore.sessionMinSizes[session.id])
            }
        }
        .onChange(of: clientService.appStreamStartAcknowledgementByStreamID[session.streamID]) { _, acknowledgement in
            Task { @MainActor in
                await Task.yield()
                handleAppStreamStartAcknowledgement(acknowledgement)
            }
        }
        .onChange(of: awaitingPostResizeFirstFrame) { _, awaiting in
            guard isDesktopStream, !awaiting else { return }
            if flushPendingDesktopResizeIfReady() { return }
            guard latestDrawableViewSize.width > 0, latestDrawableViewSize.height > 0 else { return }
            scheduleStreamScaleUpdate(for: latestDrawableViewSize)
        }
        .onAppear {
            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
        .onDisappear {
            resizeHoldoffTask?.cancel()
            resizeHoldoffTask = nil
            displayResolutionTask?.cancel()
            displayResolutionTask = nil
            pendingDisplayResolutionDispatchTarget = .zero
            pendingAppDisplayResolutionCandidate = .zero
            pendingAppDisplayResolutionCandidateSince = .distantPast
            streamScaleTask?.cancel()
            streamScaleTask = nil
            appResizeAckTimeoutTask?.cancel()
            appResizeAckTimeoutTask = nil
            awaitingAppResizeAck = false
            appResizeBaselineAcknowledgement = nil
            pendingDesktopDisplayResolutionAfterAck = .zero
            desktopResizeAckTimeoutTask?.cancel()
            desktopResizeAckTimeoutTask = nil
            awaitingDesktopResizeAck = false
            desktopResizeBaselineAcknowledgement = nil
            desktopResizeAcknowledgementStarted = false
            sentDesktopPostAckCorrection = false
            latestContainerDisplaySize = .zero
            latestRequestedDisplaySize = .zero
            latestDrawableViewSize = .zero
            resizeLifecycleState = .active
            setLocalResizeDecodePause(false, requestRecoveryKeyframeOnResume: false)
            if isResizing { isResizing = false }
            desktopResizeMaskActive = false
            #if os(iOS) || os(visionOS)
            MirageStreamViewRepresentable.releaseCachedControllerIfPossible(
                streamID: session.streamID,
                sessionStore: sessionStore
            )
            #endif
        }
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            handleResizeLifecycleSuspension(event: .didResignActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleResizeLifecycleSuspension(event: .didEnterBackground)
        }
        #endif
        #if os(macOS)
        .background(
            MirageWindowFocusObserver(
                sessionID: session.id,
                streamID: session.streamID,
                sessionStore: sessionStore,
                clientService: clientService,
                onWindowWillClose: onWindowWillClose
            )
        )
        #endif
    }

    private var isCurrentStreamActive: Bool {
        if clientService.desktopStreamID == session.streamID { return true }
        if clientService.activeStreams.contains(where: { $0.id == session.streamID }) { return true }
        return clientService.activeStreamIDsForFiltering.contains(session.streamID)
    }

    private var canSendInputToHost: Bool {
        guard case .connected = clientService.connectionState else { return false }
        return isCurrentStreamActive
    }

    private var macOSInputEnabled: Bool {
        canSendInputToHost && sessionStore.focusedSessionID == session.id
    }

    private var streamPresentationTier: StreamPresentationTier {
        sessionStore.presentationTier(for: session.streamID)
    }

    private var clientReservedShortcuts: [MirageClientShortcut] {
        [desktopExitShortcut, escapeRemapShortcut, dictationShortcut]
    }

    private var isReadyForInitialPresentation: Bool {
        switch streamPresentationTier {
        case .activeLive:
            session.hasDecodedFrame || session.hasPresentedFrame
        case .passiveSnapshot:
            session.hasDecodedFrame || session.hasPresentedFrame
        }
    }

    private var awaitingPostResizeFirstFrame: Bool {
        sessionStore.postResizeAwaitingFirstFrameStreamIDs.contains(session.streamID)
    }

    private var resizeBlurRadius: CGFloat {
        if isDesktopStream, awaitingPostResizeFirstFrame { return 24 }
        if isDesktopStream, isResizing || desktopResizeMaskActive { return 20 }
        return 0
    }

    private func sendInputEvent(_ event: MirageInputEvent) {
        if case let .keyDown(keyEvent) = event {
            if desktopExitShortcut.matches(keyEvent), let onExitDesktopStream {
                logDesktopExitShortcutTriggered()
                onExitDesktopStream()
                return
            }

            if dictationShortcut.matches(keyEvent) {
                onToggleDictationShortcut?()
                return
            }
            if escapeRemapShortcut.matches(keyEvent) {
                if desktopCursorLockEnabled {
                    onCursorLockEscapeRequested?()
                    return
                }
                forwardInputEventToHost(.keyDown(remappedEscapeKeyEvent(isRepeat: keyEvent.isRepeat)))
                return
            }

            // Intercept Cmd+V on iOS to sync clipboard to host before the paste keypress arrives.
            #if canImport(UIKit)
            if keyEvent.keyCode == 0x09, keyEvent.modifiers.contains(.command) {
                Task { await clientService.syncLocalClipboardToHost() }
            }
            #endif
        } else if case let .keyUp(keyEvent) = event {
            if escapeRemapShortcut.matches(keyEvent) {
                guard !desktopCursorLockEnabled else { return }
                forwardInputEventToHost(.keyUp(remappedEscapeKeyEvent()))
                return
            }
        }

        forwardInputEventToHost(event)
    }

    private func forwardInputEventToHost(_ event: MirageInputEvent) {
        guard canSendInputToHost else { return }
        onInputActivity?(event)

        #if os(macOS)
        guard sessionStore.focusedSessionID == session.id else { return }
        #else
        if sessionStore.focusedSessionID != session.id {
            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
        #endif

        clientService.sendInputFireAndForget(event, forStream: session.streamID)
    }

    private func remappedEscapeKeyEvent(isRepeat: Bool = false) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: 0x35,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            modifiers: [],
            isRepeat: isRepeat
        )
    }

    private func handleReservedShortcut(_ shortcut: MirageClientShortcut) {
        if shortcut == desktopExitShortcut {
            logDesktopExitShortcutTriggered()
            onExitDesktopStream?()
        } else if shortcut == escapeRemapShortcut {
            if desktopCursorLockEnabled {
                onCursorLockEscapeRequested?()
            } else {
                let escapeEvent = remappedEscapeKeyEvent()
                forwardInputEventToHost(.keyDown(escapeEvent))
                forwardInputEventToHost(.keyUp(escapeEvent))
            }
        } else if shortcut == dictationShortcut {
            onToggleDictationShortcut?()
        }
    }

    private func handlePencilGestureAction(_ action: MiragePencilGestureAction) {
        if action == .toggleDictation {
            onToggleDictationShortcut?()
        } else if case let .remoteShortcut(shortcut) = action {
            forwardInputEventToHost(.keyDown(shortcut.keyDownEvent()))
            forwardInputEventToHost(.keyUp(shortcut.keyUpEvent()))
        }
    }

    private func logDesktopExitShortcutTriggered() {
        guard isDesktopStream else { return }
        MirageLogger.client("Desktop exit shortcut triggered for stream \(session.streamID)")
    }

    private func scheduleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        Task { @MainActor in
            await Task.yield()
            handleDrawableMetricsChanged(metrics)
        }
    }

    private func scheduleContainerSizeChanged(_ containerSize: CGSize) {
        Task { @MainActor in
            await Task.yield()
            handleContainerSizeChanged(containerSize)
        }
    }

    private func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        guard metrics.pixelSize.width > 0, metrics.pixelSize.height > 0 else { return }

        let viewSize = metrics.viewSize
        let resolvedRawPixelSize = metrics.pixelSize
        latestDrawableViewSize = viewSize

        #if os(iOS) || os(visionOS)
        if resolvedRawPixelSize.width > 0, resolvedRawPixelSize.height > 0 {
            MirageClientService.lastKnownDrawablePixelSize = resolvedRawPixelSize
        }
        if let screenPointSize = metrics.screenPointSize,
           screenPointSize.width > 0,
           screenPointSize.height > 0 {
            MirageClientService.lastKnownScreenPointSize = screenPointSize
        }
        if let screenScale = metrics.screenScale, screenScale > 0 {
            MirageClientService.lastKnownScreenScale = screenScale
        }
        if let nativePixelSize = metrics.screenNativePixelSize,
           nativePixelSize.width > 0,
           nativePixelSize.height > 0 {
            MirageClientService.lastKnownScreenNativePixelSize = nativePixelSize
        }
        if let nativeScale = metrics.screenNativeScale, nativeScale > 0 {
            MirageClientService.lastKnownScreenNativeScale = nativeScale
        }
        #endif

        if latestContainerDisplaySize.width <= 0 || latestContainerDisplaySize.height <= 0 {
            handleContainerSizeChanged(viewSize)
        }
    }

    private func handleContainerSizeChanged(_ containerSize: CGSize) {
        #if os(iOS) || os(visionOS)
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: resizeLifecycleState,
            event: .drawableMetricsChanged
        )
        resizeLifecycleState = lifecycleDecision.nextState
        guard lifecycleDecision.shouldProcessDrawableMetrics else { return }
        #endif

        if containerSize.width > 0, containerSize.height > 0 {
            latestContainerDisplaySize = containerSize
            #if os(iOS) || os(visionOS)
            MirageClientService.lastKnownViewSize = containerSize
            #endif
        }

        let decision = windowDrivenResizeTargetDecision(
            containerSize: containerSize,
            fallbackDrawableSize: latestDrawableViewSize,
            suppressForLocalPresentation: prefersLocalAspectFitPresentation
        )
        switch decision {
        case .suppressForLocalPresentation:
            return
        case .ignoreInvalidMetrics:
            if !isDesktopStream {
                pendingAppDisplayResolutionCandidate = .zero
                pendingAppDisplayResolutionCandidateSince = .distantPast
                if !awaitingAppResizeAck, isResizing { isResizing = false }
            }
            return
        case .useContainerSize:
            break
        }

        guard case let .useContainerSize(targetViewSize) = decision else { return }

        Task { @MainActor [clientService] in
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return
            }
            guard resizeLifecycleState == .active else { return }

            #if os(visionOS)
            let visionOSDisplaySize = clientService.visionOSFixedPixelCountResolution(for: targetViewSize)
            #endif
            let desktopDisplaySize = isDesktopStream
                ? clientService.preferredDesktopDisplayResolution(for: targetViewSize)
                : .zero
            if !isDesktopStream {
                #if os(visionOS)
                let baseDisplaySize = visionOSDisplaySize
                #else
                let baseDisplaySize = clientService.scaledDisplayResolution(targetViewSize)
                #endif
                guard baseDisplaySize.width > 0, baseDisplaySize.height > 0 else {
                    latestRequestedDisplaySize = .zero
                    pendingAppDisplayResolutionCandidate = .zero
                    pendingAppDisplayResolutionCandidateSince = .distantPast
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }
                latestRequestedDisplaySize = baseDisplaySize
                if streamPresentationTier == .passiveSnapshot {
                    displayResolutionTask?.cancel()
                    displayResolutionTask = nil
                    pendingDisplayResolutionDispatchTarget = .zero
                    pendingAppDisplayResolutionCandidate = .zero
                    pendingAppDisplayResolutionCandidateSince = .distantPast
                    if awaitingAppResizeAck {
                        finishAppResizeAwaitingAck()
                    } else if isResizing {
                        isResizing = false
                    }
                    return
                }

                // Dedicated app/window virtual-display streams now resize via display-resolution
                // updates only. Suppress dynamic stream-scale pushes that can fight placement.
                streamScaleTask?.cancel()
                streamScaleTask = nil
                lastSentEncodedPixelSize = .zero
                guard lastSentDisplayResolution != baseDisplaySize else {
                    pendingAppDisplayResolutionCandidate = .zero
                    pendingAppDisplayResolutionCandidateSince = .distantPast
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }

                let now = Date()
                let stabilizationDuration = appDisplayResolutionStabilizationDuration(
                    from: lastSentDisplayResolution,
                    to: baseDisplaySize
                )
                if stabilizationDuration > 0 {
                    if pendingAppDisplayResolutionCandidate != baseDisplaySize {
                        pendingAppDisplayResolutionCandidate = baseDisplaySize
                        pendingAppDisplayResolutionCandidateSince = now
                        return
                    }
                    if now.timeIntervalSince(pendingAppDisplayResolutionCandidateSince) < stabilizationDuration {
                        return
                    }
                }

                pendingAppDisplayResolutionCandidate = .zero
                pendingAppDisplayResolutionCandidateSince = .distantPast
                guard pendingDisplayResolutionDispatchTarget != baseDisplaySize else { return }
                displayResolutionTask?.cancel()
                pendingDisplayResolutionDispatchTarget = baseDisplaySize
                let scheduledTarget = baseDisplaySize
                displayResolutionTask = Task { @MainActor in
                    defer {
                        if pendingDisplayResolutionDispatchTarget == scheduledTarget {
                            pendingDisplayResolutionDispatchTarget = .zero
                        }
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }

                    guard lastSentDisplayResolution != baseDisplaySize else {
                        pendingAppDisplayResolutionCandidate = .zero
                        pendingAppDisplayResolutionCandidateSince = .distantPast
                        if isResizing, !awaitingAppResizeAck { isResizing = false }
                        return
                    }
                    lastSentDisplayResolution = baseDisplaySize
                    beginAppResizeAwaitingAck()
                    do {
                        try await clientService.sendDisplayResolutionChange(
                            streamID: session.streamID,
                            newResolution: baseDisplaySize
                        )
                    } catch {
                        finishAppResizeAwaitingAck()
                    }
                }
                return
            }

            guard isDesktopStream else { return }

            #if os(visionOS)
            let preferredDisplaySize = visionOSDisplaySize
            #else
            let preferredDisplaySize = desktopDisplaySize
            #endif
            guard preferredDisplaySize.width > 0, preferredDisplaySize.height > 0 else {
                latestRequestedDisplaySize = .zero
                return
            }
            let requestedSizeChanged = !approximatelyEqualPixelSizes(
                preferredDisplaySize,
                latestRequestedDisplaySize,
                tolerance: 1
            )
            if requestedSizeChanged, session.hasPresentedFrame {
                desktopResizeMaskActive = true
            }
            latestRequestedDisplaySize = preferredDisplaySize

            if useHostResolution {
                displayResolutionTask?.cancel()
                displayResolutionTask = nil
                pendingDisplayResolutionDispatchTarget = .zero
                pendingDesktopDisplayResolutionAfterAck = .zero
                streamScaleTask?.cancel()
                streamScaleTask = nil
                setLocalResizeDecodePause(false, requestRecoveryKeyframeOnResume: false)
                if awaitingDesktopResizeAck {
                    finishDesktopResizeAwaitingAck()
                } else {
                    if isResizing { isResizing = false }
                    desktopResizeMaskActive = false
                }
                return
            }

            if desktopResizeStartupDecision(hasPresentedFrame: session.hasPresentedFrame) == .deferUntilFirstPresentation {
                if !awaitingDesktopResizeAck, isResizing { isResizing = false }
                desktopResizeMaskActive = false
                return
            }

            let acknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
            let pointScale = desktopPointScale(for: preferredDisplaySize)
            switch desktopResizeRequestDecision(
                targetDisplaySize: preferredDisplaySize,
                acknowledgedPixelSize: acknowledgedPixelSize,
                pointScale: pointScale,
                mismatchThresholdPoints: desktopResizeConvergenceTolerance
            ) {
            case .skipNoOp:
                displayResolutionTask?.cancel()
                displayResolutionTask = nil
                pendingDisplayResolutionDispatchTarget = .zero
                pendingDesktopDisplayResolutionAfterAck = .zero
                lastSentDisplayResolution = preferredDisplaySize
                setLocalResizeDecodePause(false, requestRecoveryKeyframeOnResume: false)
                if awaitingDesktopResizeAck {
                    finishDesktopResizeAwaitingAck()
                } else {
                    if latestDrawableViewSize.width > 0, latestDrawableViewSize.height > 0 {
                        scheduleStreamScaleUpdate(for: latestDrawableViewSize)
                    }
                    if isResizing { isResizing = false }
                }
                desktopResizeMaskActive = false
                return
            case .send:
                if !isResizing { isResizing = true }
                desktopResizeMaskActive = true
                setLocalResizeDecodePause(true)
                guard lastSentDisplayResolution != preferredDisplaySize else { return }
                if awaitingDesktopResizeAck {
                    pendingDesktopDisplayResolutionAfterAck = preferredDisplaySize
                    return
                }
                break
            }

            guard pendingDisplayResolutionDispatchTarget != preferredDisplaySize else { return }
            displayResolutionTask?.cancel()
            pendingDisplayResolutionDispatchTarget = preferredDisplaySize
            let scheduledTarget = preferredDisplaySize
            displayResolutionTask = Task { @MainActor in
                defer {
                    if pendingDisplayResolutionDispatchTarget == scheduledTarget {
                        pendingDisplayResolutionDispatchTarget = .zero
                    }
                }
                do {
                    try await Task.sleep(for: desktopResizeSendDebounce)
                } catch {
                    return
                }

                let latestAcknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
                let latestPointScale = desktopPointScale(for: preferredDisplaySize)
                let latestDecision = desktopResizeRequestDecision(
                    targetDisplaySize: preferredDisplaySize,
                    acknowledgedPixelSize: latestAcknowledgedPixelSize,
                    pointScale: latestPointScale,
                    mismatchThresholdPoints: desktopResizeConvergenceTolerance
                )
                if latestDecision == .skipNoOp {
                    lastSentDisplayResolution = preferredDisplaySize
                    setLocalResizeDecodePause(false, requestRecoveryKeyframeOnResume: false)
                    if awaitingDesktopResizeAck { finishDesktopResizeAwaitingAck() }
                    else if isResizing { isResizing = false }
                    desktopResizeMaskActive = false
                    return
                }

                guard lastSentDisplayResolution != preferredDisplaySize else {
                    if !awaitingDesktopResizeAck, isResizing { isResizing = false }
                    if !awaitingDesktopResizeAck { desktopResizeMaskActive = false }
                    return
                }
                if awaitingDesktopResizeAck {
                    pendingDesktopDisplayResolutionAfterAck = preferredDisplaySize
                    return
                }
                sentDesktopPostAckCorrection = false
                beginDesktopResizeAwaitingAck()
                lastSentDisplayResolution = preferredDisplaySize
                try? await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: preferredDisplaySize
                )
            }
        }
    }

    private func beginDesktopResizeAwaitingAck(resetAcknowledgementProgress: Bool = true) {
        awaitingDesktopResizeAck = true
        isResizing = true
        desktopResizeMaskActive = true
        setLocalResizeDecodePause(true)
        if resetAcknowledgementProgress {
            desktopResizeBaselineAcknowledgement = currentDesktopStartAcknowledgement()
            desktopResizeAcknowledgementStarted = false
        } else if desktopResizeBaselineAcknowledgement == nil {
            desktopResizeBaselineAcknowledgement = currentDesktopStartAcknowledgement()
        }
        desktopResizeAckTimeoutTask?.cancel()
        desktopResizeAckTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: desktopResizeAckHardTimeout)
            } catch {
                return
            }
            guard awaitingDesktopResizeAck else { return }
            MirageLogger.client("Desktop resize hard timeout for stream \(session.streamID)")
            finishDesktopResizeAwaitingAck()
        }
    }

    private func finishDesktopResizeAwaitingAck() {
        desktopResizeAckTimeoutTask?.cancel()
        desktopResizeAckTimeoutTask = nil
        awaitingDesktopResizeAck = false
        desktopResizeBaselineAcknowledgement = nil
        desktopResizeAcknowledgementStarted = false
        sentDesktopPostAckCorrection = false
        let followUpDecision = desktopPostResizeFollowUpDecision(
            pendingTargetDisplaySize: pendingDesktopDisplayResolutionAfterAck,
            awaitingPostResizeFirstFrame: awaitingPostResizeFirstFrame
        )

        if followUpDecision == .flushPendingResize,
           flushPendingDesktopResizeIfReady() {
            return
        }

        let shouldRequestRecoveryKeyframeOnResume = awaitingPostResizeFirstFrame
        setLocalResizeDecodePause(
            false,
            requestRecoveryKeyframeOnResume: shouldRequestRecoveryKeyframeOnResume
        )
        if isResizing { isResizing = false }
        desktopResizeMaskActive = false
        guard followUpDecision != .awaitFirstPresentedFrame else { return }
        if latestDrawableViewSize.width > 0, latestDrawableViewSize.height > 0 {
            scheduleStreamScaleUpdate(for: latestDrawableViewSize)
        }
    }

    private func flushPendingDesktopResizeIfReady() -> Bool {
        let decision = desktopPostResizeFollowUpDecision(
            pendingTargetDisplaySize: pendingDesktopDisplayResolutionAfterAck,
            awaitingPostResizeFirstFrame: awaitingPostResizeFirstFrame
        )
        guard decision == .flushPendingResize else { return false }

        let targetDisplaySize = pendingDesktopDisplayResolutionAfterAck
        pendingDesktopDisplayResolutionAfterAck = .zero
        return flushCoalescedDesktopResizeIfNeeded(targetDisplaySize: targetDisplaySize)
    }

    private func flushCoalescedDesktopResizeIfNeeded(targetDisplaySize: CGSize) -> Bool {
        guard !useHostResolution else { return false }
        guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return false }
        guard !awaitingDesktopResizeAck else { return false }

        let acknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
        let pointScale = desktopPointScale(for: targetDisplaySize)
        let decision = desktopResizeRequestDecision(
            targetDisplaySize: targetDisplaySize,
            acknowledgedPixelSize: acknowledgedPixelSize,
            pointScale: pointScale,
            mismatchThresholdPoints: desktopResizeConvergenceTolerance
        )
        guard decision == .send else {
            lastSentDisplayResolution = targetDisplaySize
            return false
        }

        guard lastSentDisplayResolution != targetDisplaySize else { return false }

        MirageLogger
            .client(
                "Flushing coalesced desktop resize for stream \(session.streamID) to " +
                    "\(Int(targetDisplaySize.width))x\(Int(targetDisplaySize.height)) pts"
            )
        sentDesktopPostAckCorrection = false
        setLocalResizeDecodePause(true)
        beginDesktopResizeAwaitingAck()
        lastSentDisplayResolution = targetDisplaySize
        Task { @MainActor [clientService] in
            try? await clientService.sendDisplayResolutionChange(
                streamID: session.streamID,
                newResolution: targetDisplaySize
            )
        }
        return true
    }

    private func beginAppResizeAwaitingAck() {
        appResizeBaselineAcknowledgement = clientService.appStreamStartAcknowledgementByStreamID[session.streamID]
        awaitingAppResizeAck = true
        isResizing = true
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: appResizeAckTimeout)
            } catch {
                return
            }
            guard awaitingAppResizeAck else { return }
            finishAppResizeAwaitingAck()
        }
    }

    private func finishAppResizeAwaitingAck() {
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        if isResizing { isResizing = false }
    }

    private func handleAppStreamStartAcknowledgement(
        _ acknowledgement: MirageClientService.StreamStartAcknowledgement?
    ) {
        guard !isDesktopStream else { return }
        let decision = appStreamStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: awaitingAppResizeAck,
            latest: acknowledgement,
            baseline: appResizeBaselineAcknowledgement
        )
        guard decision == .recheckMinimumSize else { return }
        if let minimumSize = sessionStore.sessionMinSizes[session.id] {
            handleResizeAcknowledgement(minimumSize)
        }
    }

    private func handleResizeAcknowledgement(_ minSize: CGSize?) {
        guard isDesktopStream else {
            guard awaitingAppResizeAck else { return }
            guard let minSize, minSize.width > 0, minSize.height > 0 else { return }
            let acknowledgement = clientService.appStreamStartAcknowledgementByStreamID[session.streamID]
            let decision = appStreamStartAcknowledgementHandlingDecision(
                awaitingResizeAcknowledgement: awaitingAppResizeAck,
                latest: acknowledgement,
                baseline: appResizeBaselineAcknowledgement
            )
            guard decision == .recheckMinimumSize else { return }
            finishAppResizeAwaitingAck()
            return
        }
        guard awaitingDesktopResizeAck else { return }
        guard let minSize, minSize.width > 0, minSize.height > 0 else { return }
        let latestAcknowledgement = currentDesktopStartAcknowledgement()
        switch desktopResizeStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: awaitingDesktopResizeAck,
            acknowledgementProgressStarted: desktopResizeAcknowledgementStarted,
            latest: latestAcknowledgement,
            baseline: desktopResizeBaselineAcknowledgement
        ) {
        case .ignore:
            return
        case .waitForResizeAdvance:
            return
        case .beginConvergenceCheck:
            desktopResizeAcknowledgementStarted = true
            if let latestAcknowledgement {
                let tokenText = latestAcknowledgement.dimensionToken.map(String.init) ?? "nil"
                MirageLogger.client(
                    "Desktop resize ack advanced for stream \(session.streamID): token=\(tokenText), size=\(latestAcknowledgement.width)x\(latestAcknowledgement.height)"
                )
            }
        case .continueConvergenceCheck:
            break
        }

        // Converge against the last requested resize target; live drawable size can continue changing
        // while an ack is in flight and should be handled by coalescing after this ack settles.
        let targetDisplaySize: CGSize = if lastSentDisplayResolution.width > 0, lastSentDisplayResolution.height > 0 {
            lastSentDisplayResolution
        } else if latestRequestedDisplaySize.width > 0, latestRequestedDisplaySize.height > 0 {
            latestRequestedDisplaySize
        } else {
            .zero
        }
        guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return }
        let pointScale = desktopPointScale(for: targetDisplaySize)
        let acknowledgedDisplaySize = CGSize(
            width: minSize.width / pointScale,
            height: minSize.height / pointScale
        )

        switch desktopResizeAckDecision(
            acknowledgedDisplaySize: acknowledgedDisplaySize,
            targetDisplaySize: targetDisplaySize,
            correctionAlreadySent: sentDesktopPostAckCorrection,
            mismatchThresholdPoints: desktopResizeConvergenceTolerance
        ) {
        case .converged:
            finishDesktopResizeAwaitingAck()
        case .requestCorrection:
            sentDesktopPostAckCorrection = true
            beginDesktopResizeAwaitingAck(resetAcknowledgementProgress: false)
            lastSentDisplayResolution = targetDisplaySize
            MirageLogger
                .client(
                    "Desktop resize ack mismatch for stream \(session.streamID); sending one-shot correction to " +
                        "\(Int(targetDisplaySize.width))x\(Int(targetDisplaySize.height)) pts"
                )
            Task { @MainActor [clientService] in
                try? await clientService.sendDisplayResolutionChange(
                    streamID: session.streamID,
                    newResolution: targetDisplaySize
                )
            }
        case .waitForTimeout:
            MirageLogger.client("Desktop resize ack mismatch persisted after correction for stream \(session.streamID)")
        }
    }

    private func setLocalResizeDecodePause(
        _ paused: Bool,
        requestRecoveryKeyframeOnResume: Bool = false
    ) {
        guard isDesktopStream else { return }
        guard let controller = clientService.controller(for: session.streamID) else { return }
        Task {
            if paused {
                await controller.suspendDecodeForLocalResize()
            } else {
                await controller.resumeDecodeAfterLocalResize(
                    requestRecoveryKeyframe: requestRecoveryKeyframeOnResume
                )
            }
        }
    }

    private func currentDesktopAcknowledgedPixelSize() -> CGSize {
        if let desktopResolution = clientService.desktopStreamResolution,
           desktopResolution.width > 0,
           desktopResolution.height > 0 {
            return desktopResolution
        }

        if let minimumSize = sessionStore.sessionMinSizes[session.id],
           minimumSize.width > 0,
           minimumSize.height > 0 {
            return minimumSize
        }

        return .zero
    }

    private func currentDesktopStartAcknowledgement() -> MirageClientService.StreamStartAcknowledgement? {
        guard let resolution = clientService.desktopStreamResolution,
              resolution.width > 0,
              resolution.height > 0 else { return nil }
        return MirageClientService.StreamStartAcknowledgement(
            width: Int(resolution.width.rounded()),
            height: Int(resolution.height.rounded()),
            dimensionToken: clientService.desktopDimensionTokenByStream[session.streamID]
        )
    }

    private func resolvedDesktopStreamScale(for displaySize: CGSize) -> CGFloat {
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return 1.0
        }

        let basePoints = clientService.scaledDisplayResolution(displaySize)
        guard basePoints.width > 0, basePoints.height > 0 else { return 1.0 }
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: basePoints,
            displayScaleFactor: desktopPointScale(for: basePoints),
            requestedStreamScale: 1.0,
            encoderMaxWidth: Int(maxDrawableSize.width),
            encoderMaxHeight: Int(maxDrawableSize.height)
        )
        return geometry.resolvedStreamScale
    }

    private func inferredDesktopPointScaleFromAcknowledged(
        displaySize: CGSize,
        acknowledgedPixelSize: CGSize
    ) -> CGFloat? {
        guard displaySize.width > 0,
              displaySize.height > 0,
              acknowledgedPixelSize.width > 0,
              acknowledgedPixelSize.height > 0 else {
            return nil
        }

        let inferredWidthScale = acknowledgedPixelSize.width / displaySize.width
        let inferredHeightScale = acknowledgedPixelSize.height / displaySize.height
        guard inferredWidthScale > 0, inferredHeightScale > 0 else { return nil }

        // Accept host-driven scale only when both axes imply the same effective scale.
        let mismatch = abs(inferredWidthScale - inferredHeightScale)
        let tolerance = max(0.05, max(inferredWidthScale, inferredHeightScale) * 0.03)
        guard mismatch <= tolerance else { return nil }

        return max(1.0, (inferredWidthScale + inferredHeightScale) * 0.5)
    }

    private func desktopPointScale(for displaySize: CGSize) -> CGFloat {
        if let inferredScale = inferredDesktopPointScaleFromAcknowledged(
            displaySize: displaySize,
            acknowledgedPixelSize: currentDesktopAcknowledgedPixelSize()
        ) {
            return inferredScale
        }

        let basePixels = clientService.virtualDisplayPixelResolution(for: displaySize)
        let widthScale = displaySize.width > 0 ? basePixels.width / displaySize.width : 1.0
        let heightScale = displaySize.height > 0 ? basePixels.height / displaySize.height : 1.0
        let virtualDisplayScaleFactor = max(1.0, widthScale, heightScale)
        return virtualDisplayScaleFactor
    }

    private func scheduleStreamScaleUpdate(for displaySize: CGSize) {
        guard !useHostResolution else {
            streamScaleTask?.cancel()
            streamScaleTask = nil
            return
        }
        guard let maxDrawableSize,
              maxDrawableSize.width > 0,
              maxDrawableSize.height > 0,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return
        }

        let basePoints = clientService.scaledDisplayResolution(displaySize)
        guard basePoints.width > 0, basePoints.height > 0 else { return }
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: basePoints,
            displayScaleFactor: desktopPointScale(for: basePoints),
            requestedStreamScale: 1.0,
            encoderMaxWidth: Int(maxDrawableSize.width),
            encoderMaxHeight: Int(maxDrawableSize.height)
        )
        let clampedScale = geometry.resolvedStreamScale

        if isDesktopStream,
           clampedScale >= 0.999,
           let inferredScale = inferredDesktopPointScaleFromAcknowledged(
               displaySize: basePoints,
               acknowledgedPixelSize: currentDesktopAcknowledgedPixelSize()
           ) {
            let inferredTargetSize = MirageStreamGeometry.alignedEncodedSize(
                CGSize(
                    width: basePoints.width * inferredScale,
                    height: basePoints.height * inferredScale
                )
            )
            lastSentEncodedPixelSize = inferredTargetSize
            streamScaleTask?.cancel()
            streamScaleTask = nil
            return
        }
        let alignedTargetSize = CGSize(
            width: min(maxDrawableSize.width, geometry.encodedPixelSize.width),
            height: min(maxDrawableSize.height, geometry.encodedPixelSize.height)
        )

        if isDesktopStream {
            let acknowledgedPixelSize = currentDesktopAcknowledgedPixelSize()
            if approximatelyEqualPixelSizes(acknowledgedPixelSize, alignedTargetSize) {
                lastSentEncodedPixelSize = alignedTargetSize
                streamScaleTask?.cancel()
                streamScaleTask = nil
                return
            }
        }

        guard alignedTargetSize != lastSentEncodedPixelSize else { return }

        streamScaleTask?.cancel()
        let targetScale = clampedScale
        let targetSize = alignedTargetSize
        streamScaleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard targetSize != lastSentEncodedPixelSize else { return }
            lastSentEncodedPixelSize = targetSize
            try? await clientService.sendStreamScaleChange(
                streamID: session.streamID,
                scale: targetScale
            )
        }
    }

    private func appDisplayResolutionStabilizationDuration(
        from previous: CGSize,
        to proposed: CGSize
    )
    -> TimeInterval {
        guard previous.width > 0, previous.height > 0 else { return 0 }
        guard proposed.width > 0, proposed.height > 0 else { return 0 }

        let previousArea = previous.width * previous.height
        let proposedArea = proposed.width * proposed.height
        guard previousArea > 0, proposedArea > 0 else { return 0 }

        let areaDelta = abs(proposedArea - previousArea) / previousArea
        let widthDelta = abs(proposed.width - previous.width) / previous.width
        let heightDelta = abs(proposed.height - previous.height) / previous.height
        let widthRatio = proposed.width / previous.width
        let heightRatio = proposed.height / previous.height

        if widthRatio < 0.75 || heightRatio < 0.75 {
            // Guard against transient drawable/layout drops that can collapse app streams
            // to quarter-size if propagated immediately to host display resolution.
            return 1.2
        }

        if areaDelta > 0.28 || widthDelta > 0.20 || heightDelta > 0.20 {
            return 0.6
        }

        return 0
    }

    private func approximatelyEqualPixelSizes(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 2
    )
    -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
        return abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    #if os(iOS) || os(visionOS)
    private func handleResizeLifecycleSuspension(event: DesktopResizeLifecycleEvent) {
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: resizeLifecycleState,
            event: event
        )
        resizeLifecycleState = lifecycleDecision.nextState
        cancelPendingResizeWorkForLifecycleSuspension()
    }

    private func cancelPendingResizeWorkForLifecycleSuspension() {
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        pendingDisplayResolutionDispatchTarget = .zero
        pendingAppDisplayResolutionCandidate = .zero
        pendingAppDisplayResolutionCandidateSince = .distantPast
        streamScaleTask?.cancel()
        streamScaleTask = nil
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        desktopResizeAckTimeoutTask?.cancel()
        desktopResizeAckTimeoutTask = nil
        awaitingDesktopResizeAck = false
        desktopResizeBaselineAcknowledgement = nil
        desktopResizeAcknowledgementStarted = false
        pendingDesktopDisplayResolutionAfterAck = .zero
        sentDesktopPostAckCorrection = false
        latestContainerDisplaySize = .zero
        latestRequestedDisplaySize = .zero
        latestDrawableViewSize = .zero
        if isResizing { isResizing = false }
        desktopResizeMaskActive = false
        setLocalResizeDecodePause(false, requestRecoveryKeyframeOnResume: false)
    }

    private func scheduleResizeHoldoff() {
        resizeHoldoffTask?.cancel()
        resizeLifecycleState = .suspended
        resizeHoldoffTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            let lifecycleDecision = desktopResizeLifecycleDecision(
                state: resizeLifecycleState,
                event: .foregroundHoldoffElapsed
            )
            resizeLifecycleState = lifecycleDecision.nextState
        }
    }

    private func handleForegroundRecovery() {
        guard clientService.controller(for: session.streamID) != nil else {
            MirageLogger.client(
                "Foreground recovery skipped for stale stream \(session.streamID)"
            )
            return
        }

        scheduleResizeHoldoff()
        MirageLogger.client("Foreground recovery dispatch for stream \(session.streamID)")
        clientService.requestApplicationActivationRecovery(for: session.streamID)
    }
    #endif
}
