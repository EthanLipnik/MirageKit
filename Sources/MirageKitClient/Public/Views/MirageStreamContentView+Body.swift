//
//  MirageStreamContentView+Body.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Body

public extension MirageStreamContentView {
    var body: some View {
        streamContentWithPlatformObservers
    }
}

private extension MirageStreamContentView {
    var streamContentWithReadinessOverlay: some View {
        streamRootContent
            .overlay(streamReadinessOverlay, alignment: .center)
    }

    var streamContentWithSessionObservers: some View {
        streamContentWithReadinessOverlay
            .onChange(of: sessionStore.sessionMinSizes[session.id]) {
                scheduleResizeAcknowledgementHandlingIfNeeded()
            }
            .onChange(of: sessionStore.sessionMinSizeUpdateGenerations[session.id]) {
                scheduleResizeAcknowledgementHandlingIfNeeded()
            }
            .onChange(of: appStreamStartAcknowledgement) {
                scheduleAppStreamStartAcknowledgementHandling()
            }
            .onChange(of: appWindowResizeResult) {
                handleAppWindowResizeResult(appWindowResizeResult)
            }
            .onChange(of: awaitingPostResizeFirstFrame) {
                handleAwaitingPostResizeFirstFrameChanged()
            }
            .onChange(of: session.hasPresentedFrame) {
                handleSessionHasPresentedFrameChanged()
            }
            .onChange(of: session.clientRecoveryStatus) {
                handleClientRecoveryStatusChanged()
            }
            .onChange(of: rawPresentationBlurRadius) {
                handlePresentationBlurRadiusChanged()
            }
    }

    var streamContentWithInputAndPresentationObservers: some View {
        streamContentWithSessionObservers
            .onChange(of: inputEnabled) {
                handleInputEnabledChanged()
            }
            .onChange(of: localPresentationPauseActive) {
                handleLocalPresentationPauseChanged()
            }
            .onChange(of: maxDrawableSize) {
                scheduleDesktopResizeForCurrentMetricsChangeIfNeeded()
            }
            .onChange(of: useHostResolution) {
                scheduleDesktopResizeForCurrentMetricsChangeIfNeeded()
            }
            .onChange(of: localKeyboardOcclusionActive) {
                handleLocalKeyboardOcclusionChanged()
            }
            .onChange(of: isCurrentStreamActive) {
                scheduleFocusedInputCorrectionIfNeeded()
            }
    }

    var streamContentWithLifecycleObservers: some View {
        streamContentWithInputAndPresentationObservers
            .onAppear {
                handleStreamContentAppear()
            }
            .onDisappear {
                scheduleStreamContentDisappearCleanup()
            }
    }

    var streamContentWithKeyboardObservers: some View {
        #if os(iOS)
        streamContentWithLifecycleObservers
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                handleLocalKeyboardFrameChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                localKeyboardOcclusionActive = false
            }
        #else
        streamContentWithLifecycleObservers
        #endif
    }

    var streamContentWithApplicationLifecycleObservers: some View {
        #if os(iOS) || os(visionOS)
        streamContentWithKeyboardObservers
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                handleResizeLifecycleSuspension(event: .willResignActive)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                handleResizeLifecycleSuspension(event: .didEnterBackground)
            }
        #else
        streamContentWithKeyboardObservers
        #endif
    }

    var streamContentWithPlatformObservers: some View {
        #if os(macOS)
        streamContentWithApplicationLifecycleObservers
            .background(
                MirageWindowFocusObserver(
                    sessionID: session.id,
                    streamID: session.streamID,
                    sessionStore: sessionStore,
                    clientService: clientService,
                    onWindowWillClose: onWindowWillClose
                )
            )
        #else
        streamContentWithApplicationLifecycleObservers
        #endif
    }

    var streamRootContent: some View {
        ZStack {
            Rectangle()
                .fill(.black)
                .mirageStreamIgnoresSafeArea(ignoresSafeArea)

            streamPlatformSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    var streamPlatformSurface: some View {
        #if os(iOS) || os(visionOS)
        MirageStreamViewRepresentable(
            streamID: session.streamID,
            mediaStreamID: presentationStreamID,
            contentRectOverride: presentationContentRectOverride,
            onInputEvent: streamInputForwardingEnabled ? { event in
                sendInputEvent(event)
            } : nil,
            onDrawableMetricsChanged: { metrics in
                scheduleDrawableMetricsChanged(metrics)
            },
            onContainerSizeChanged: { size in
                scheduleContainerSizeChanged(size)
            },
            onRefreshRateOverrideChange: { override in
                scheduleRefreshRateOverrideChange(override)
            },
            cursorStore: clientService.cursorStore,
            cursorPositionStore: clientService.cursorPositionStore,
            desktopSessionID: activeDesktopSessionID,
            hasPresentedFrameForActivationRecovery: session.hasPresentedFrame,
            onBecomeActive: {
                handleForegroundRecovery()
            },
            onHardwareKeyboardPresenceChanged: onHardwareKeyboardPresenceChanged,
            onSoftwareKeyboardVisibilityChanged: onSoftwareKeyboardVisibilityChanged,
            directTouchInputMode: directTouchInputMode,
            softwareKeyboardVisible: softwareKeyboardVisible,
            inputEnabled: streamInputForwardingEnabled,
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
            preferredMaximumRenderFPS: preferredMaximumRenderFPS,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
            ignoresSafeArea: ignoresSafeArea
        )
        .blur(radius: presentationBlurRadius)
        .animation(presentationBlurAnimation, value: presentationBlurRadius)
        #else
        MirageStreamViewRepresentable(
            streamID: session.streamID,
            mediaStreamID: presentationStreamID,
            contentRectOverride: presentationContentRectOverride,
            onInputEvent: streamInputForwardingEnabled ? { event in
                sendInputEvent(event)
            } : nil,
            onDrawableMetricsChanged: { metrics in
                scheduleDrawableMetricsChanged(metrics)
            },
            onContainerSizeChanged: { size in
                scheduleContainerSizeChanged(size)
            },
            onRefreshRateOverrideChange: { override in
                scheduleRefreshRateOverrideChange(override)
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
            inputEnabled: streamInputForwardingEnabled && macOSInputEnabled,
            systemShortcutForwardingEnabled: macSystemShortcutForwardingEnabled,
            presentationTier: streamPresentationTier,
            preferredMaximumRenderFPS: preferredMaximumRenderFPS,
            maxDrawableSize: maxDrawableSize,
            prefersLocalAspectFitPresentation: prefersLocalAspectFitPresentation,
            containerSizingMode: macOSContainerSizingMode,
            clientShortcuts: clientReservedShortcuts,
            onClientShortcut: handleReservedShortcut,
            actions: actions,
            onActionTriggered: onActionTriggered
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: presentationBlurRadius)
        .animation(presentationBlurAnimation, value: presentationBlurRadius)
        #endif
    }

    @ViewBuilder
    var streamReadinessOverlay: some View {
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
        } else if awaitingPostResizeFirstFrame, session.hasPresentedFrame {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
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

    func scheduleResizeAcknowledgementHandlingIfNeeded() {
        guard !isDesktopStream else { return }
        Task { @MainActor in
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return
            }
            handleAppResizeAcknowledgementIfNeeded()
        }
    }

    func handleStreamContentAppear() {
        updateRecoveryBlurDebounceState()
        updatePresentationBlurProgressMonitoring()
        if !inputEnabled {
            cancelInputResumeGate(reason: "appeared_input_disabled")
        }
        scheduleInitialInputFocusRecovery()
    }

    func scheduleAppStreamStartAcknowledgementHandling() {
        Task { @MainActor in
            await Task.yield()
            handleAppStreamStartAcknowledgement(appStreamStartAcknowledgement)
        }
    }

    func scheduleDesktopPresentationReadyIfNeeded(requirePresentedFrame: Bool) {
        guard isDesktopStream else { return }
        if requirePresentedFrame {
            guard session.hasPresentedFrame else { return }
        } else {
            guard !awaitingPostResizeFirstFrame else { return }
        }

        Task { @MainActor in
            await Task.yield()
            clientService.handleDesktopPresentationReady(streamID: session.streamID)
        }
    }

    func handleAwaitingPostResizeFirstFrameChanged() {
        updatePresentationBlurProgressMonitoring()
        scheduleDesktopPresentationReadyIfNeeded(requirePresentedFrame: false)
    }

    func handleSessionHasPresentedFrameChanged() {
        updatePresentationBlurProgressMonitoring()
        scheduleDesktopPresentationReadyIfNeeded(requirePresentedFrame: true)
    }

    func handleLocalPresentationPauseChanged() {
        if localPresentationPauseActive {
            cancelPendingWindowDrivenResizeForLocalPresentation()
        } else {
            beginInputResumeGateIfNeeded(reason: "local_presentation_resumed", requiresInputEnabled: false)
            scheduleWindowDrivenResizeForCurrentMetricsIfNeeded()
        }
    }

    func handleLocalKeyboardOcclusionChanged() {
        if localKeyboardOcclusionActive {
            cancelPendingWindowDrivenResizeForLocalPresentation()
        } else {
            scheduleWindowDrivenResizeForCurrentMetricsIfNeeded()
        }
    }

    func handleClientRecoveryStatusChanged() {
        updateRecoveryBlurDebounceState()
        updatePresentationBlurProgressMonitoring()
    }

    func handlePresentationBlurRadiusChanged() {
        updatePresentationBlurProgressMonitoring()
    }

    func scheduleDesktopResizeForCurrentMetricsChangeIfNeeded() {
        guard isDesktopStream else { return }
        scheduleDesktopResizeForCurrentMetricsIfNeeded()
    }

    func scheduleFocusedInputCorrectionIfNeeded() {
        guard isCurrentStreamActive else { return }
        Task { @MainActor in
            await Task.yield()
            focusCurrentStreamForInputIfNeeded()
        }
    }

    func scheduleInitialInputFocusRecovery() {
        Task { @MainActor in
            await Task.yield()
            focusCurrentStreamForInputIfNeeded(force: true)
        }
    }

    func scheduleStreamContentDisappearCleanup() {
        Task { @MainActor in
            await Task.yield()
            handleStreamContentDisappear()
        }
    }

    /// Clears transient resize, focus, and renderer state when the stream view leaves the hierarchy.
    func handleStreamContentDisappear() {
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        appResizeDispatchState.cancel()
        streamScaleTask?.cancel()
        streamScaleTask = nil
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        cancelInputResumeGate(reason: "stream_content_disappeared")
        stopPresentationBlurProgressMonitoring()
        resetRecoveryBlurDebounceState()
        if awaitingAppResizeAck {
            onAppResizeWaitingChanged?(false)
        }
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestDrawableScaleFactor = nil
        localKeyboardOcclusionActive = false
        resizeLifecycleState = .active
        if isResizing { isResizing = false }
        clientService.clearDesktopResizeState(
            streamID: session.streamID,
            preserveLastSentTarget: clientService.desktopStreamRequestStartTime > 0
        )
        #if os(iOS) || os(visionOS)
        MirageClientService.clearCachedDisplayMetrics()
        MirageStreamViewRepresentable.releaseCachedControllerIfPossible(
            streamID: session.streamID,
            sessionStore: sessionStore
        )
        #endif
    }
}

private struct MirageStreamIgnoresSafeAreaModifier: ViewModifier {
    let ignoresSafeArea: Bool

    func body(content: Content) -> some View {
        if ignoresSafeArea {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

private extension View {
    func mirageStreamIgnoresSafeArea(_ ignoresSafeArea: Bool) -> some View {
        modifier(MirageStreamIgnoresSafeAreaModifier(ignoresSafeArea: ignoresSafeArea))
    }
}
