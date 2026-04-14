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
    public let onDictationInputLevelChanged: ((Float) -> Void)?
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

    /// Resize holdoff task used during foreground transitions (iOS).
    @State private var resizeHoldoffTask: Task<Void, Never>?

    /// Foreground/background gating for local resize dispatch.
    @State private var resizeLifecycleState: DesktopResizeLifecycleState = .active

    /// Whether the client is currently waiting for host to complete resize.
    @State private var isResizing: Bool = false
    @State private var displayResolutionTask: Task<Void, Never>?
    @State private var pendingDisplayResolutionDispatchTarget: CGSize = .zero
    /// Tracks the last requested client display resolution, not the host's encoded output size.
    @State private var lastSentDisplayResolution: CGSize = .zero
    @State private var streamScaleTask: Task<Void, Never>?
    @State private var lastSentEncodedPixelSize: CGSize = .zero
    @State private var awaitingAppResizeAck: Bool = false
    @State private var appResizeBaselineAcknowledgement: MirageClientService.StreamStartAcknowledgement?
    @State private var appResizeAckTimeoutTask: Task<Void, Never>?
    @State private var latestContainerDisplaySize: CGSize = .zero
    @State private var latestDrawableViewSize: CGSize = .zero

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
    ///   - onDictationInputLevelChanged: Optional callback for normalized microphone input levels.
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
        onDictationInputLevelChanged: ((Float) -> Void)? = nil,
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
        self.onDictationInputLevelChanged = onDictationInputLevelChanged
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
        softwareKeyboardVisible && keyboardAvoidanceEnabled
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
                    onDictationInputLevelChanged: onDictationInputLevelChanged,
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
            guard !isDesktopStream else { return }
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
            guard !isDesktopStream else { return }
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
            clientService.handleDesktopPresentationReady(streamID: session.streamID)
        }
        .onChange(of: session.hasPresentedFrame) { _, hasPresentedFrame in
            guard isDesktopStream, hasPresentedFrame else { return }
            clientService.handleDesktopPresentationReady(streamID: session.streamID)
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
            streamScaleTask?.cancel()
            streamScaleTask = nil
            appResizeAckTimeoutTask?.cancel()
            appResizeAckTimeoutTask = nil
            awaitingAppResizeAck = false
            appResizeBaselineAcknowledgement = nil
            latestContainerDisplaySize = .zero
            latestDrawableViewSize = .zero
            resizeLifecycleState = .active
            if isResizing { isResizing = false }
            clientService.clearDesktopResizeState(streamID: session.streamID)
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

    private var desktopResizeCoordinator: DesktopResizeCoordinator {
        clientService.desktopResizeCoordinator
    }

    private var resizeBlurRadius: CGFloat {
        if isDesktopStream, awaitingPostResizeFirstFrame { return 24 }
        if isDesktopStream, desktopResizeCoordinator.isResizing || desktopResizeCoordinator.maskActive { return 20 }
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
        let currentLifecycleState = isDesktopStream
            ? desktopResizeCoordinator.resizeLifecycleState
            : resizeLifecycleState
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: currentLifecycleState,
            event: .drawableMetricsChanged
        )
        if isDesktopStream {
            desktopResizeCoordinator.resizeLifecycleState = lifecycleDecision.nextState
        } else {
            resizeLifecycleState = lifecycleDecision.nextState
        }
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
            let lifecycleState = isDesktopStream
                ? desktopResizeCoordinator.resizeLifecycleState
                : resizeLifecycleState
            guard lifecycleState == .active else { return }

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
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }
                if streamPresentationTier == .passiveSnapshot {
                    displayResolutionTask?.cancel()
                    displayResolutionTask = nil
                    pendingDisplayResolutionDispatchTarget = .zero
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
                    if isResizing, !awaitingAppResizeAck { isResizing = false }
                    return
                }
                enqueueImmediateAppDisplayResolutionChange(baseDisplaySize)
                return
            }

            guard isDesktopStream else { return }

            #if os(visionOS)
            let preferredDisplaySize = visionOSDisplaySize
            #else
            let preferredDisplaySize = desktopDisplaySize
            #endif
            let target = clientService.desktopResizeTarget(
                for: preferredDisplaySize,
                maxDrawableSize: maxDrawableSize
            )
            clientService.queueDesktopResize(
                streamID: session.streamID,
                target: target,
                hasPresentedFrame: session.hasPresentedFrame,
                useHostResolution: useHostResolution
            )
        }
    }

    private func enqueueImmediateAppDisplayResolutionChange(_ targetDisplaySize: CGSize) {
        guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return }
        guard pendingDisplayResolutionDispatchTarget != targetDisplaySize || displayResolutionTask == nil else { return }

        pendingDisplayResolutionDispatchTarget = targetDisplaySize
        guard displayResolutionTask == nil else { return }

        displayResolutionTask = Task { @MainActor [clientService] in
            defer {
                displayResolutionTask = nil
                if pendingDisplayResolutionDispatchTarget == .zero, isResizing, !awaitingAppResizeAck {
                    isResizing = false
                }
            }

            while !Task.isCancelled {
                let dispatchedTarget = pendingDisplayResolutionDispatchTarget
                pendingDisplayResolutionDispatchTarget = .zero
                guard dispatchedTarget.width > 0, dispatchedTarget.height > 0 else { break }

                guard lastSentDisplayResolution != dispatchedTarget else {
                    if pendingDisplayResolutionDispatchTarget == .zero { break }
                    continue
                }

                lastSentDisplayResolution = dispatchedTarget
                beginAppResizeAwaitingAck()
                do {
                    try await clientService.sendDisplayResolutionChange(
                        streamID: session.streamID,
                        newResolution: dispatchedTarget
                    )
                } catch {
                    finishAppResizeAwaitingAck()
                }

                if pendingDisplayResolutionDispatchTarget == .zero { break }
                await Task.yield()
            }
        }
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
        guard !isDesktopStream else { return }
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
    }

    #if os(iOS) || os(visionOS)
    private func handleResizeLifecycleSuspension(event: DesktopResizeLifecycleEvent) {
        let currentLifecycleState = isDesktopStream
            ? desktopResizeCoordinator.resizeLifecycleState
            : resizeLifecycleState
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: currentLifecycleState,
            event: event
        )
        if isDesktopStream {
            desktopResizeCoordinator.resizeLifecycleState = lifecycleDecision.nextState
        } else {
            resizeLifecycleState = lifecycleDecision.nextState
        }
        cancelPendingResizeWorkForLifecycleSuspension()
    }

    private func cancelPendingResizeWorkForLifecycleSuspension() {
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        pendingDisplayResolutionDispatchTarget = .zero
        streamScaleTask?.cancel()
        streamScaleTask = nil
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        if isResizing { isResizing = false }
        clientService.clearDesktopResizeState(streamID: session.streamID)
    }

    private func scheduleResizeHoldoff() {
        let updateLifecycleState: (DesktopResizeLifecycleState) -> Void = { nextState in
            if isDesktopStream {
                desktopResizeCoordinator.resizeLifecycleState = nextState
            } else {
                resizeLifecycleState = nextState
            }
        }
        let currentLifecycleState: () -> DesktopResizeLifecycleState = {
            if isDesktopStream {
                return desktopResizeCoordinator.resizeLifecycleState
            }
            return resizeLifecycleState
        }

        if isDesktopStream {
            desktopResizeCoordinator.resizeHoldoffTask?.cancel()
        } else {
            resizeHoldoffTask?.cancel()
        }
        updateLifecycleState(.suspended)
        let holdoffTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            let lifecycleDecision = desktopResizeLifecycleDecision(
                state: currentLifecycleState(),
                event: .foregroundHoldoffElapsed
            )
            updateLifecycleState(lifecycleDecision.nextState)
        }
        if isDesktopStream {
            desktopResizeCoordinator.resizeHoldoffTask = holdoffTask
        } else {
            resizeHoldoffTask = holdoffTask
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
