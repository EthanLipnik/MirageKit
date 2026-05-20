//
//  MirageStreamContentView+Body.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
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
        ZStack {
            Rectangle()
                .fill(.black)
                .mirageStreamIgnoresSafeArea(ignoresSafeArea)

            Group {
                #if os(iOS) || os(visionOS)
                MirageStreamViewRepresentable(
                    streamID: session.streamID,
                    mediaStreamID: presentationStreamID,
                    contentRectOverride: presentationContentRectOverride,
                    onInputEvent: inputEnabled ? { event in
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
                    inputEnabled: inputEnabled,
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
                    inputEnabled: inputEnabled && macOSInputEnabled,
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
        .onChange(of: sessionStore.sessionMinSizes[session.id]) {
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
        .onChange(of: sessionStore.sessionMinSizeUpdateGenerations[session.id]) {
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
        .onChange(of: appStreamStartAcknowledgement) {
            Task { @MainActor in
                await Task.yield()
                handleAppStreamStartAcknowledgement(
                    appStreamStartAcknowledgement
                )
            }
        }
        .onChange(of: awaitingPostResizeFirstFrame) {
            updatePresentationBlurProgressMonitoring()
            guard isDesktopStream, !awaitingPostResizeFirstFrame else { return }
            Task { @MainActor in
                await Task.yield()
                clientService.handleDesktopPresentationReady(streamID: session.streamID)
            }
        }
        .onChange(of: session.hasPresentedFrame) {
            updatePresentationBlurProgressMonitoring()
            guard isDesktopStream, session.hasPresentedFrame else { return }
            Task { @MainActor in
                await Task.yield()
                clientService.handleDesktopPresentationReady(streamID: session.streamID)
            }
        }
        .onChange(of: session.clientRecoveryStatus) {
            updateRecoveryBlurDebounceState()
            updatePresentationBlurProgressMonitoring()
        }
        .onChange(of: rawPresentationBlurRadius) {
            updatePresentationBlurProgressMonitoring()
        }
        .onChange(of: maxDrawableSize) {
            guard isDesktopStream else { return }
            scheduleDesktopResizeForCurrentMetricsIfNeeded()
        }
        .onChange(of: useHostResolution) {
            guard isDesktopStream else { return }
            scheduleDesktopResizeForCurrentMetricsIfNeeded()
        }
        .onChange(of: localKeyboardOcclusionActive) {
            guard localKeyboardOcclusionActive else { return }
            cancelPendingWindowDrivenResizeForLocalPresentation()
        }
        .onChange(of: isCurrentStreamActive) {
            guard isCurrentStreamActive else { return }
            Task { @MainActor in
                await Task.yield()
                focusCurrentStreamForInputIfNeeded()
            }
        }
        .onAppear {
            updateRecoveryBlurDebounceState()
            updatePresentationBlurProgressMonitoring()
            Task { @MainActor in
                await Task.yield()
                focusCurrentStreamForInputIfNeeded(force: true)
            }
        }
        .onDisappear {
            Task { @MainActor in
                await Task.yield()
                handleStreamContentDisappear()
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            handleLocalKeyboardFrameChange(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            localKeyboardOcclusionActive = false
        }
        #endif
        #if os(iOS) || os(visionOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            handleResizeLifecycleSuspension(event: .willResignActive)
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
}

private extension MirageStreamContentView {
    /// Clears transient resize, focus, and renderer state when the stream view leaves the hierarchy.
    func handleStreamContentDisappear() {
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        pendingDisplayResolutionDispatchTarget = .zero
        streamScaleTask?.cancel()
        streamScaleTask = nil
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        stopPresentationBlurProgressMonitoring()
        resetRecoveryBlurDebounceState()
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestDrawableScaleFactor = nil
        localKeyboardOcclusionActive = false
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
