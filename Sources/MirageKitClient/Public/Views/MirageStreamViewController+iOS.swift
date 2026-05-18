//
//  MirageStreamViewController+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import SwiftUI

/// UIKit host controller that owns the stream input-capture view for SwiftUI.
public final class MirageStreamViewController: UIViewController {
    var currentStreamID: StreamID?
    private let captureView = InputCapturingView(frame: .zero)
    private var pointerLockRequested: Bool = false
    private var pointerLockObserver: NSObjectProtocol?
    private var lastResolvedPointerLockState: MirageResolvedPointerLockState?
    private var lastDesktopSessionIDForResponderRecovery: UUID?
    private var lastDesktopMediaStreamIDForResponderRecovery: StreamID?

    override public func loadView() {
        view = captureView
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPointerLockObserverIfNeeded()
        captureView.requestResponderRecovery(.viewDidAppear)
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
        captureView.requestResponderRecovery(.callbacksConfigured)
    }

    func updateState(_ state: MirageStreamViewControllerState) {
        // Establish media and logical stream identities before cursor stores refresh.
        let previousDesktopSessionID = lastDesktopSessionIDForResponderRecovery
        let previousDesktopMediaStreamID = lastDesktopMediaStreamIDForResponderRecovery
        currentStreamID = state.streamID
        captureView.mediaStreamID = state.mediaStreamID
        captureView.streamID = state.streamID
        captureView.contentRectOverride = state.contentRectOverride
        captureView.directTouchInputMode = state.directTouchInputMode
        captureView.inputEnabled = state.inputEnabled
        captureView.softwareKeyboardVisible = state.softwareKeyboardVisible
        captureView.pencilGestureConfiguration = state.pencilGestureConfiguration
        captureView.clientShortcuts = state.clientShortcuts
        captureView.actions = state.actions
        captureView.dictationToggleRequestID = state.dictationToggleRequestID
        captureView.dictationMode = state.dictationMode
        captureView.dictationLocalePreference = state.dictationLocalePreference
        captureView.hideSystemCursor = state.hideSystemCursor
        captureView.cursorStore = state.cursorStore
        captureView.cursorPositionStore = state.cursorPositionStore
        captureView.desktopSessionID = state.desktopSessionID
        captureView.hasPresentedFrameForActivationRecovery = state.hasPresentedFrameForActivationRecovery
        captureView.allowsExtendedCursorBounds = state.allowsExtendedDesktopCursorBounds
        captureView.cursorLockEnabled = state.cursorLockEnabled
        captureView.canRecaptureCursorLock = state.cursorLockCanRecapture
        captureView.onCursorLockEscapeRequested = state.onCursorLockEscapeRequested
        captureView.onCursorLockRecaptureRequested = state.onCursorLockRecaptureRequested
        captureView.syntheticCursorEnabled = state.syntheticCursorEnabled
        captureView.presentationTier = state.presentationTier
        captureView.preferredMaximumRenderFPS = state.preferredMaximumRenderFPS
        captureView.maxDrawableSize = state.maxDrawableSize
        captureView.prefersLocalAspectFitPresentation = state.prefersLocalAspectFitPresentation
        captureView.ignoresSafeArea = state.ignoresSafeArea
        captureView.activateStreamPresentation()

        pointerLockRequested = state.cursorLockEnabled
        updatePointerLockState()
        let responderRecoveryTrigger: InputCapturingResponderRecoveryTrigger
        if let desktopSessionID = state.desktopSessionID {
            if previousDesktopSessionID != desktopSessionID {
                responderRecoveryTrigger = .desktopStreamStarted
            } else if previousDesktopMediaStreamID != state.mediaStreamID {
                responderRecoveryTrigger = .desktopTransitionCommitted
            } else {
                responderRecoveryTrigger = .streamIdentityUpdated
            }
            lastDesktopSessionIDForResponderRecovery = desktopSessionID
            lastDesktopMediaStreamIDForResponderRecovery = state.mediaStreamID
        } else {
            lastDesktopSessionIDForResponderRecovery = nil
            lastDesktopMediaStreamIDForResponderRecovery = nil
            responderRecoveryTrigger = .streamIdentityUpdated
        }
        captureView.requestResponderRecovery(responderRecoveryTrigger)
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
