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

    /// UserDefaults key for whether local keyboard appearance avoids covering stream content.
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
    /// Whether the platform stream view should own input focus and forward local input.
    public let inputEnabled: Bool
    /// Whether local UI currently owns presentation and should suppress stream resize negotiation.
    public let localPresentationPauseActive: Bool
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
    /// Whether keyboard occlusion should make local presentation avoid the keyboard on touch platforms.
    public let keyboardAvoidanceEnabled: Bool
    /// Optional cap for drawable pixel dimensions.
    public let maxDrawableSize: CGSize?
    /// Handler invoked before the native stream window closes.
    public let onWindowWillClose: (() -> Void)?
    /// Handler invoked when an app-stream resize acknowledgement wait starts or clears.
    public let onAppResizeWaitingChanged: ((Bool) -> Void)?
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
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @State var displayResolutionTask: Task<Void, Never>?
    @State var appResizeDispatchState = AppWindowResizeDispatchState()
    @State var streamScaleTask: Task<Void, Never>?
    @State var lastSentEncodedPixelSize: CGSize = .zero
    @State var awaitingAppResizeAck: Bool = false
    @State var appResizeBaselineAcknowledgement: MirageClientService.StreamStartAcknowledgement?
    @State var appResizeAckTimeoutTask: Task<Void, Never>?
    @State var presentationBlurProgressTask: Task<Void, Never>?
    @State var presentationBlurProgressTaskGeneration: UInt64 = 0
    @State var presentationBlurProgressSuppressed = false
    @State var hasPresentedFrameBeforeReadinessReset = false
    @State var recoveryBlurTrackedStatus: MirageStreamClientRecoveryStatus = .idle
    @State var recoveryBlurStatusBecameActiveAt: CFAbsoluteTime?
    @State var inputResumeBaselineSubmissionCursor: MirageRenderCursor?
    @State var inputResumeBaselineSubmissionSequence: UInt64 = 0
    @State var inputResumeGateTask: Task<Void, Never>?
    @State var inputResumeGateGeneration: UInt64 = 0
    @State var latestContainerDisplaySize: CGSize = .zero
    @State var latestDrawableViewSize: CGSize = .zero
    @State var latestDrawableScaleFactor: CGFloat?
    @State var localKeyboardOcclusionActive = false
    @State var localKeyboardOcclusionHeight: CGFloat = 0
    @State var localKeyboardOcclusionClearTask: Task<Void, Never>?
    @State var suppressNextOrderedPasteKeyUp = false

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
    ///   - onAppResizeWaitingChanged: Optional app resize wait state callback.
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
        inputEnabled: Bool = true,
        localPresentationPauseActive: Bool = false,
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
        macSystemShortcutForwardingEnabled: Bool = false,
        keyboardAvoidanceEnabled: Bool = true,
        maxDrawableSize: CGSize? = nil,
        onWindowWillClose: (() -> Void)? = nil,
        onAppResizeWaitingChanged: ((Bool) -> Void)? = nil,
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
        self.inputEnabled = inputEnabled
        self.localPresentationPauseActive = localPresentationPauseActive
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
        self.onAppResizeWaitingChanged = onAppResizeWaitingChanged
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
        #if os(iOS) || os(visionOS)
        let directTouchVirtualCursorEnabled = directTouchInputMode == .dragCursor &&
            desktopCursorPresentation.source == .client
        #else
        let directTouchVirtualCursorEnabled = false
        #endif
        return !isDesktopStream ||
            directTouchVirtualCursorEnabled ||
            desktopCursorPresentation.rendersSyntheticClientCursor ||
            (desktopCursorLockEnabled && !desktopCursorPresentation.capturesHostCursor)
    }

    /// Render-store stream ID used by the platform presenter.
    ///
    /// App-atlas windows are decoded from a shared media stream, then fanned out
    /// into per-logical render-store streams before presentation.
    var presentationStreamID: StreamID {
        session.streamID == session.mediaStreamID ? session.mediaStreamID : session.streamID
    }

    /// App-atlas cropping is handled before enqueueing frames into each logical render stream.
    var presentationContentRectOverride: CGRect? {
        nil
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
    /// Prefer the host-confirmed presentation size so Retina-off 1x streams do
    /// not accidentally use the local Retina backing scale.
    var hostDisplayPointSize: CGSize? {
        #if os(macOS)
        if let presentationSize = clientService.desktopStreamPresentationResolution,
           presentationSize.width > 0,
           presentationSize.height > 0 {
            return presentationSize
        }
        guard let resolution = clientService.desktopStreamResolution,
              resolution.width > 0, resolution.height > 0 else { return nil }
        let scale = clientService.desktopStreamDisplayScaleFactor ?? latestDrawableScaleFactor ?? 1.0
        return CGSize(
            width: resolution.width / max(1.0, scale),
            height: resolution.height / max(1.0, scale)
        )
        #else
        return nil
        #endif
    }

    /// Whether local presentation state should temporarily prevent window-size driven resize requests.
    var suppressesWindowDrivenResizeForLocalPresentation: Bool {
        localPresentationPauseActive ||
            MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
                isDesktopStream: isDesktopStream,
                useHostResolution: useHostResolution,
                desktopCaptureSource: clientService.desktopCaptureSource,
                desktopStreamAllowsClientResize: clientService.desktopStreamAllowsClientResize,
                keyboardAvoidanceEnabled: keyboardAvoidanceEnabled,
                softwareKeyboardVisible: softwareKeyboardVisible,
                localKeyboardOcclusionActive: localKeyboardOcclusionActive
            )
    }

    /// Whether the stream should preserve source aspect instead of resizing the host/window to fill.
    var prefersLocalAspectFitPresentation: Bool {
        MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation()
    }

    var localPresentationKeyboardBottomInset: CGFloat {
        #if os(iOS)
        keyboardAvoidanceEnabled ? localKeyboardOcclusionHeight : 0
        #else
        0
        #endif
    }

    #if os(macOS)
    /// macOS container sizing mode chosen from the current resize policy.
    var macOSContainerSizingMode: MirageStreamContainerSizingMode {
        isDesktopStream && !suppressesWindowDrivenResizeForLocalPresentation ? .viewBounds : .contentLayout
    }
    #endif

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
    /// Effective input gate after local modal ownership and post-resume frame fencing.
    var streamInputForwardingEnabled: Bool {
        inputEnabled && inputResumeBaselineSubmissionCursor == nil
    }

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
        guard streamInputForwardingEnabled else { return false }
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
        guard streamInputForwardingEnabled else { return }
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

    /// Whether a previous presented frame can stand in while the stream waits for a fresh chain.
    var canRetainPresentedFrameDuringReadinessWait: Bool {
        !isReadyForInitialPresentation && hasPresentedFrameBeforeReadinessReset
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

    /// Blur applied while recovery preserves the last presented image.
    var recoveryBlurRadius: CGFloat {
        guard session.hasPresentedFrame else { return 0 }
        let baseRadius: CGFloat
        switch session.clientRecoveryStatus {
        case .keyframeRecovery:
            baseRadius = 16
        case .hardRecovery:
            baseRadius = 20
        case .postResizeAwaitingFirstFrame:
            baseRadius = awaitingPostResizeFirstFrame ? 24 : 0
        case .idle,
             .startup,
             .tierPromotionProbe:
            return 0
        }
        guard baseRadius > 0 else { return 0 }
        guard let debounce = Self.recoveryBlurDebounceInterval(for: session.clientRecoveryStatus) else {
            return baseRadius
        }
        guard recoveryBlurTrackedStatus == session.clientRecoveryStatus,
              let recoveryBlurStatusBecameActiveAt else {
            return 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - recoveryBlurStatusBecameActiveAt
        return elapsed >= debounce ? baseRadius : 0
    }

    /// Combined presentation blur from resize masking, stream recovery, and retained-frame readiness waits.
    var rawPresentationBlurRadius: CGFloat {
        max(resizeBlurRadius, max(recoveryBlurRadius, retainedFrameReadinessBlurRadius))
    }

    /// Blur applied while a retained frame stands in for a reset stream chain.
    var retainedFrameReadinessBlurRadius: CGFloat {
        canRetainPresentedFrameDuringReadinessWait ? 16 : 0
    }

    /// Whether recent accepted frames should keep the stream visually live.
    var suppressesPresentationBlurForRecentProgress: Bool {
        presentationBlurProgressSuppressed
    }

    /// Whether frame-progress sampling should run while a blur candidate is active.
    var monitorsPresentationProgressForBlurSuppression: Bool {
        session.hasPresentedFrame && rawPresentationBlurRadius > 0
    }

    /// Latest accepted frame submission state for the presented media stream.
    var latestPresentationSubmissionSnapshot: SubmissionSnapshot {
        MirageRenderStreamStore.shared.submissionSnapshot(for: presentationStreamID)
    }

    /// Hold window that covers normal frame cadence without masking a real stall indefinitely.
    var presentationBlurProgressHoldDuration: CFAbsoluteTime {
        let snapshot = clientService.metricsStore.snapshot(for: presentationStreamID) ??
            clientService.metricsStore.snapshot(for: session.streamID)
        let observedFPS = max(snapshot?.clientPresentedFPS ?? 0, snapshot?.uniqueSubmittedFPS ?? 0)
        if observedFPS > 0 {
            return min(1.5, max(0.5, 2.5 / observedFPS))
        }
        return 1.25
    }

    /// Combined presentation blur after recovery-only live frame-progress suppression.
    var presentationBlurRadius: CGFloat {
        max(
            retainedFrameReadinessBlurRadius,
            Self.resolvedPresentationBlurRadius(
                resizeRadius: resizeBlurRadius,
                recoveryRadius: recoveryBlurRadius,
                suppressesRecoveryBlurForRecentProgress: suppressesPresentationBlurForRecentProgress
            )
        )
    }

    static func resolvedPresentationBlurRadius(
        resizeRadius: CGFloat,
        recoveryRadius: CGFloat,
        suppressesRecoveryBlurForRecentProgress: Bool
    ) -> CGFloat {
        if resizeRadius > 0 { return resizeRadius }

        guard recoveryRadius > 0 else { return 0 }
        return suppressesRecoveryBlurForRecentProgress ? 0 : recoveryRadius
    }

    /// Short blur transition used only when the recovery mask enters or exits.
    var presentationBlurAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    func updatePresentationBlurProgressMonitoring() {
        guard monitorsPresentationProgressForBlurSuppression else {
            stopPresentationBlurProgressMonitoring()
            return
        }
        guard presentationBlurProgressTask == nil else { return }

        presentationBlurProgressTaskGeneration &+= 1
        let taskGeneration = presentationBlurProgressTaskGeneration
        let initialSnapshot = latestPresentationSubmissionSnapshot
        let initialSuppressedUntil = Self.presentationBlurProgressSuppressionDeadline(
            latestSubmittedTime: initialSnapshot.submittedTime,
            now: CFAbsoluteTimeGetCurrent(),
            holdDuration: presentationBlurProgressHoldDuration
        )
        if initialSuppressedUntil != nil, !presentationBlurProgressSuppressed {
            presentationBlurProgressSuppressed = true
        }

        presentationBlurProgressTask = Task { @MainActor in
            var baselineSubmissionSequence = initialSnapshot.sequence
            var suppressedUntil = initialSuppressedUntil ?? 0

            while !Task.isCancelled {
                let now = CFAbsoluteTimeGetCurrent()
                let update = Self.nextPresentationBlurProgressSuppression(
                    baselineSubmissionSequence: baselineSubmissionSequence,
                    latestSubmissionSequence: latestPresentationSubmissionSnapshot.sequence,
                    now: now,
                    holdDuration: presentationBlurProgressHoldDuration
                )
                baselineSubmissionSequence = update.baselineSubmissionSequence
                if let nextSuppressedUntil = update.suppressedUntil {
                    suppressedUntil = nextSuppressedUntil
                    if !presentationBlurProgressSuppressed {
                        presentationBlurProgressSuppressed = true
                    }
                } else if presentationBlurProgressSuppressed, suppressedUntil <= now {
                    suppressedUntil = 0
                    presentationBlurProgressSuppressed = false
                }

                guard monitorsPresentationProgressForBlurSuppression else { break }
                do {
                    try await Task.sleep(for: Self.presentationBlurProgressPollInterval)
                } catch {
                    break
                }
            }
            guard presentationBlurProgressTaskGeneration == taskGeneration else { return }
            presentationBlurProgressTask = nil
            if !monitorsPresentationProgressForBlurSuppression {
                resetPresentationBlurProgressSuppression()
            }
        }
    }

    func stopPresentationBlurProgressMonitoring() {
        guard presentationBlurProgressTask != nil || presentationBlurProgressSuppressed else { return }
        presentationBlurProgressTaskGeneration &+= 1
        presentationBlurProgressTask?.cancel()
        presentationBlurProgressTask = nil
        resetPresentationBlurProgressSuppression()
    }

    func resetPresentationBlurProgressSuppression() {
        if presentationBlurProgressSuppressed {
            presentationBlurProgressSuppressed = false
        }
    }

    func updateRecoveryBlurDebounceState(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard recoveryBlurTrackedStatus != session.clientRecoveryStatus else { return }
        recoveryBlurTrackedStatus = session.clientRecoveryStatus
        recoveryBlurStatusBecameActiveAt = Self.recoveryBlurDebounceInterval(for: session.clientRecoveryStatus) == nil
            ? nil
            : now
    }

    func resetRecoveryBlurDebounceState() {
        recoveryBlurTrackedStatus = .idle
        recoveryBlurStatusBecameActiveAt = nil
    }

    func handleInputEnabledChanged() {
        if inputEnabled {
            beginInputResumeGateIfNeeded(reason: "input_enabled", requiresInputEnabled: true)
        } else {
            cancelInputResumeGate(reason: "input_disabled")
        }
    }

    func beginInputResumeGateIfNeeded(reason: String, requiresInputEnabled: Bool = true) {
        if requiresInputEnabled {
            guard inputEnabled else { return }
        }
        guard inputResumeBaselineSubmissionCursor == nil else { return }

        let baseline = latestPresentationSubmissionSnapshot
        inputResumeBaselineSubmissionCursor = baseline.cursor
        inputResumeBaselineSubmissionSequence = baseline.sequence
        inputResumeGateGeneration &+= 1
        let gateGeneration = inputResumeGateGeneration
        let baselineCursor = baseline.cursor
        let baselineSequence = baseline.sequence

        MirageLogger.client(
            "Input resume for stream \(session.streamID) waiting for new presented frame " +
                "(\(reason), baseline=\(baselineSequence))"
        )

        inputResumeGateTask?.cancel()
        inputResumeGateTask = Task { @MainActor in
            let deadline = ContinuousClock.now + Self.inputResumeFrameWaitTimeout
            while !Task.isCancelled {
                let latestCursor = latestPresentationSubmissionSnapshot.cursor
                if latestCursor.hasSubmittedFrame && latestCursor.isAfter(baselineCursor) {
                    finishInputResumeGate(generation: gateGeneration, reason: "presented_frame")
                    return
                }

                if ContinuousClock.now >= deadline {
                    finishInputResumeGate(generation: gateGeneration, reason: "timeout")
                    return
                }

                do {
                    try await Task.sleep(for: Self.inputResumeFrameWaitPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func finishInputResumeGate(generation: UInt64, reason: String) {
        guard inputResumeGateGeneration == generation else { return }
        let baselineSequence = inputResumeBaselineSubmissionSequence
        inputResumeGateTask?.cancel()
        inputResumeGateTask = nil
        inputResumeBaselineSubmissionCursor = nil
        inputResumeBaselineSubmissionSequence = 0
        MirageLogger.client(
            "Input resume for stream \(session.streamID) released (\(reason), baseline=\(baselineSequence), " +
                "latest=\(latestPresentationSubmissionSnapshot.sequence))"
        )
        focusCurrentStreamForInputIfNeeded(force: true)
    }

    func cancelInputResumeGate(reason: String) {
        guard inputResumeGateTask != nil || inputResumeBaselineSubmissionCursor != nil else { return }
        inputResumeGateGeneration &+= 1
        inputResumeGateTask?.cancel()
        inputResumeGateTask = nil
        inputResumeBaselineSubmissionCursor = nil
        inputResumeBaselineSubmissionSequence = 0
        MirageLogger.client("Input resume gate cancelled for stream \(session.streamID) (\(reason))")
    }

    static func nextPresentationBlurProgressSuppression(
        baselineSubmissionSequence: UInt64,
        latestSubmissionSequence: UInt64,
        now: CFAbsoluteTime,
        holdDuration: CFAbsoluteTime
    ) -> (baselineSubmissionSequence: UInt64, suppressedUntil: CFAbsoluteTime?) {
        guard latestSubmissionSequence > 0 else {
            return (0, nil)
        }

        guard latestSubmissionSequence != baselineSubmissionSequence else {
            return (baselineSubmissionSequence, nil)
        }

        return (latestSubmissionSequence, now + holdDuration)
    }

    static func presentationBlurProgressSuppressionDeadline(
        latestSubmittedTime: CFAbsoluteTime,
        now: CFAbsoluteTime,
        holdDuration: CFAbsoluteTime
    ) -> CFAbsoluteTime? {
        guard latestSubmittedTime > 0 else { return nil }
        let suppressedUntil = latestSubmittedTime + holdDuration
        guard suppressedUntil > now else { return nil }
        return suppressedUntil
    }

    static func recoveryBlurDebounceInterval(
        for status: MirageStreamClientRecoveryStatus
    ) -> CFAbsoluteTime? {
        switch status {
        case .keyframeRecovery:
            0.30
        case .hardRecovery:
            0.15
        case .idle,
             .startup,
             .tierPromotionProbe,
             .postResizeAwaitingFirstFrame:
            nil
        }
    }
}

private extension MirageStreamContentView {
    static let presentationBlurProgressPollInterval: Duration = .milliseconds(100)
    static let inputResumeFrameWaitPollInterval: Duration = .milliseconds(16)
    static let inputResumeFrameWaitTimeout: Duration = .seconds(3)
}

// MARK: - Resize Acknowledgements

extension MirageStreamContentView {
    var appStreamStartAcknowledgement: MirageClientService.StreamStartAcknowledgement? {
        clientService.appStreamStartAcknowledgementByStreamID[session.streamID] ??
            clientService.appStreamStartAcknowledgementByStreamID[session.mediaStreamID]
    }

    var appWindowResizeResult: AppWindowResizeResultMessage? {
        clientService.appWindowResizeResultByStreamID[session.streamID]
    }

    func handleAppStreamStartAcknowledgement(
        _ acknowledgement: MirageClientService.StreamStartAcknowledgement?
    ) {
        guard !isDesktopStream else { return }
        finishAppResizeAcknowledgementIfMeaningful(acknowledgement)
    }

    func handleAppResizeAcknowledgementIfNeeded() {
        guard !isDesktopStream else { return }
        finishAppResizeAcknowledgementIfMeaningful(appStreamStartAcknowledgement)
    }

    func finishAppResizeAcknowledgementIfMeaningful(
        _ acknowledgement: MirageClientService.StreamStartAcknowledgement?
    ) {
        guard awaitingAppResizeAck else { return }
        guard isMeaningfulAppResizeAcknowledgement(
            acknowledgement,
            comparedTo: appResizeBaselineAcknowledgement
        ) else { return }
        appResizeDispatchState.completeCurrentAsAcknowledged(now: CFAbsoluteTimeGetCurrent())
        finishAppResizeAwaitingAck()
        scheduleAppDisplayResolutionDispatchIfNeeded()
    }

    func handleAppWindowResizeResult(_ result: AppWindowResizeResultMessage?) {
        guard !isDesktopStream else { return }
        guard awaitingAppResizeAck else { return }
        guard let result else { return }
        guard result.streamID == session.streamID else { return }
        let inFlightTarget = appResizeDispatchState.inFlightTarget
        let completedCurrentTarget = appResizeDispatchState.complete(
            result: result,
            now: CFAbsoluteTimeGetCurrent()
        )
        guard completedCurrentTarget || !appResizeDispatchState.hasInFlightResize else {
            MirageLogger.client(
                "Ignoring stale app resize result stream=\(session.streamID) requested=\(result.requestedWidth)x\(result.requestedHeight) " +
                    appResizeDispatchState.diagnosticSummary
            )
            return
        }
        if completedCurrentTarget {
            applyLearnedMinimumSizeIfNeeded(from: result, inFlightTarget: inFlightTarget)
        }
        finishAppResizeAwaitingAck()
        scheduleAppDisplayResolutionDispatchIfNeeded()
    }

    func applyLearnedMinimumSizeIfNeeded(
        from result: AppWindowResizeResultMessage,
        inFlightTarget: CGSize?
    ) {
        guard result.outcome == .failed || result.outcome == .notResizable else { return }
        guard let inFlightTarget,
              Int(inFlightTarget.width) == result.requestedWidth,
              Int(inFlightTarget.height) == result.requestedHeight else {
            return
        }
        guard let observedWidth = result.observedWidth,
              let observedHeight = result.observedHeight,
              observedWidth > 0,
              observedHeight > 0,
              result.requestedWidth < observedWidth || result.requestedHeight < observedHeight else {
            return
        }
        guard let minWidth = result.minWidth,
              let minHeight = result.minHeight,
              minWidth > 0,
              minHeight > 0 else {
            return
        }

        let minSize = CGSize(width: minWidth, height: minHeight)
        sessionStore.updateMinimumSize(for: result.streamID, minSize: minSize)
    }
}
