//
//  InputCapturingView+Lifecycle.swift
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
#if os(iOS) || os(visionOS)
import AVFAudio
import Speech
import UIKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
    func setupSceneLifecycleObservers() {
        // Clear modifiers and transient input state when app loses focus.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Suspend rendering only when the app actually enters background.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Handle app returning to active state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillEnterForeground(_:)),
            name: UIScene.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )

        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        #endif

        #if canImport(GameController)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidDisconnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidConnect(_:)),
            name: .GCMouseDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidDisconnect(_:)),
            name: .GCMouseDidDisconnect,
            object: nil
        )

        installHardwareKeyboardHandler()
        updateHardwareKeyboardPresence(GCKeyboard.coalesced != nil)
        #endif
    }

    @objc
    func appWillResignActive() {
        didResignActiveSinceLastActivation = true
        cancelPendingResponderRecovery()
        releaseActivePointerButtonsIfNeeded(reason: "application_will_resign_active")
        resetPointerSuppressionState(reason: "application_will_resign_active")
        // Clear all modifier and key repeat state when app loses focus
        stopAllKeyRepeats()
        resetAllModifiers()
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        resetPencilGestureState()
        isDragging = false
        clearSoftwareKeyboardState()
        stopDictation()
        stopVirtualCursorDeceleration()
        stopTouchScrollDeceleration()
    }

    @objc
    func appDidEnterBackground() {
        didEnterBackgroundSinceLastActive = true
        // Ordinary app backgrounding should suspend the display layer so we
        // can resume from the last presented frame if the display layer stays healthy.
        sampleBufferView.suspendRendering(clearCurrentFrame: false)
    }

    @objc
    func appDidBecomeActive() {
        resetPointerSuppressionState(reason: "application_did_become_active")
        let resignedActive = didResignActiveSinceLastActivation
        let backgrounded = didEnterBackgroundSinceLastActive
        let displayLayerFailed = sampleBufferView.hasDisplayLayerFailure
        let activationDecision = inputCapturingActivationRecoveryDecision(
            resignedActive: resignedActive,
            backgrounded: backgrounded,
            displayLayerFailed: displayLayerFailed
        )

        if activationDecision.shouldRequestStreamRecovery ||
            activationDecision.shouldResumeRenderingWithoutRecovery {
            recordPendingApplicationActivationHandling(
                activationDecision,
                resignedActive: resignedActive,
                backgrounded: backgrounded,
                displayLayerFailed: displayLayerFailed
            )
            applyPendingApplicationActivationHandlingIfPossible()
        } else if window != nil {
            sampleBufferView.resumeRenderingAfterApplicationActivation(resetPresentationState: false)
        }
        Task {
            await MirageClientAudioSessionCoordinator.shared.handleApplicationDidBecomeActive()
        }

        sendModifierStateIfNeeded(force: true)
        #if canImport(GameController)
        installHardwareKeyboardHandler()
        updateHardwareKeyboardPresence(GCKeyboard.coalesced != nil)
        updateMouseInputHandler()
        #endif
        requestResponderRecovery(.applicationDidBecomeActive)

        didResignActiveSinceLastActivation = false
        didEnterBackgroundSinceLastActive = false
    }

    #if canImport(GameController)
    @objc
    func keyboardDidConnect(_: Notification) {
        installHardwareKeyboardHandler()
        syncModifierStateFromHardware()
        updateHardwareKeyboardPresence(true)
    }

    @objc
    func keyboardDidDisconnect(_: Notification) {
        HardwareKeyboardCoordinator.shared.handleKeyboardDisconnect()
        stopModifierRefresh()
        updateHardwareKeyboardPresence(false)

        // Always notify the host to clear modifiers on keyboard disconnect,
        // even if client-side modifiers are already empty (host may have drifted state)
        heldModifierKeys.removeAll()
        capsLockEnabled = false
        lastSentModifiers = []
        onInputEvent?(.flagsChanged([]))
    }

    @objc
    func mouseDidConnect(_: Notification) {
        updateMouseInputHandler()
    }

    @objc
    func mouseDidDisconnect(_: Notification) {
        updateMouseInputHandler()
    }
    #endif

    @objc
    func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene else { return }
        guard scene === window?.windowScene else { return }
        requestResponderRecovery(.sceneDidActivate)
        applyPendingApplicationActivationHandlingIfPossible()
    }

    @objc
    func sceneWillEnterForeground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene else { return }
        guard scene === window?.windowScene else { return }
        requestResponderRecovery(.sceneWillEnterForeground)
        applyPendingApplicationActivationHandlingIfPossible()
    }

    @objc
    func windowDidBecomeKey(_ notification: Notification) {
        guard let notifiedWindow = notification.object as? UIWindow else { return }
        guard notifiedWindow === window else { return }
        requestResponderRecovery(.windowDidBecomeKey)
        applyPendingApplicationActivationHandlingIfPossible()
    }

    override public var canBecomeFirstResponder: Bool { inputEnabled }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        reportContainerSizeIfChanged(force: true)
        if window != nil {
            releaseActivePointerButtonsIfNeeded(reason: "did_move_to_window")
            resetPointerSuppressionState(reason: "did_move_to_window")
            requestResponderRecovery(.didMoveToWindow)
            applyPendingApplicationActivationHandlingIfPossible()
        } else {
            releaseActivePointerButtonsIfNeeded(reason: "did_move_from_window")
            stopVirtualCursorDeceleration()
            stopTouchScrollDeceleration()
            cancelPendingResponderRecovery()
        }
        updateMouseInputHandler()
    }

    override public func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()
        reportContainerSizeIfChanged()
        updateVirtualCursorViewPosition()
        updateLockedCursorViewPosition()
    }

    func reportContainerSizeIfChanged(_ overrideSize: CGSize? = nil, force: Bool = false) {
        let size = overrideSize ?? bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard force || size != lastReportedContainerSize else { return }
        lastReportedContainerSize = size
        onContainerSizeChanged?(size)
    }

    override public func resignFirstResponder() -> Bool {
        // Clear all modifier and key repeat state when losing focus
        stopAllKeyRepeats()
        releaseActivePointerButtonsIfNeeded(reason: "resign_first_responder")
        stopVirtualCursorDeceleration()
        stopTouchScrollDeceleration()
        resetAllModifiers()
        resetPrimaryClickTracking()
        resetSecondaryClickTracking()
        resetPencilGestureState()
        resetPointerSuppressionState(reason: "resign_first_responder")
        isDragging = false
        return super.resignFirstResponder()
    }
}

#endif
