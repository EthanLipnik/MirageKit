//
//  ScrollPhysicsCapturingNSView+Setup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Setup

    func setup() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setupLockedCursorView()
        shortcutForwardingEventTap.shouldForward = { [weak self] in
            self?.isKeyboardInputActive == true
        }
        shortcutForwardingEventTap.onInputEvent = { [weak self] event in
            self?.onMouseEvent?(event)
        }
        shortcutForwardingEventTap.onForwardedShortcutKeyDown = { [weak self] in
            self?.hideCursorForTypingUntilPointerMovement()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncKeyboardActivationObservers()
        syncFullscreenTransitionObservers()
        handleInputActivityStateChange()
        reportContainerSizeIfChanged(force: true)
        if let window, isInputProcessingActive {
            window.makeFirstResponder(self)
        }
    }

    func setupLockedCursorView() {
        lockedCursorView.imageScaling = .scaleNone
        lockedCursorView.isHidden = true
        updateLockedCursorImage()
        contentView.addSubview(lockedCursorView)
    }

    func updateLockedCursorImage() {
        let cursor = mirroredSystemCursorType.nsCursor
        lockedCursorView.image = cursor.image
        lockedCursorView.frame.size = cursor.image.size
    }

    override func layout() {
        super.layout()
        reportContainerSizeIfChanged()
        if cursorLockEnabled, isInputProcessingActive {
            updateCursorLockAnchor()
            warpCursorToAnchor()
        }
        updateLockedCursorViewPosition()
    }

    var isInputProcessingActive: Bool {
        inputEnabled && window != nil
    }

    var shouldMirrorHostCursorAppearanceToSystemCursor: Bool {
        guard isInputProcessingActive else { return false }
        guard !hideSystemCursor else { return false }
        return !cursorLockEnabled || !syntheticCursorEnabled
    }

    var isKeyboardInputActive: Bool {
        guard isInputProcessingActive, let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.firstResponder === self
    }

    func handleInputActivityStateChange() {
        if isInputProcessingActive {
            claimKeyboardFocusIfPossible()
            updateCursorLockMode()
            updateShortcutForwardingEventTap()
            startModifierPollingIfNeeded()
            if isKeyboardInputActive {
                syncModifierStateFromSystem(force: true)
            } else {
                syncModifierState([], force: true)
            }
        } else {
            shortcutForwardingStartTask?.cancel()
            shortcutForwardingStartTask = nil
            shortcutForwardingEventTap.stop()
            stopLockedCursorSmoothing()
            stopModifierPolling()
            cursorHiddenForTyping = false
            restoreCursorLockIfNeeded()
            lockedCursorView.isHidden = true
            syncModifierState([], force: true)
        }

        invalidateHostCursorRects()
        applyMirroredSystemCursorAppearance()
        updateTrackingAreas()
    }

    func handleKeyboardActivationStateChange() {
        claimKeyboardFocusIfPossible()
        updateShortcutForwardingEventTap()
        if isKeyboardInputActive {
            syncModifierStateFromSystem(force: true)
        } else {
            syncModifierState([], force: true)
        }
    }

    func claimKeyboardFocusIfPossible() {
        guard NSApp.isActive,
              let window,
              isInputProcessingActive,
              window.isKeyWindow,
              window.firstResponder !== self else {
            return
        }
        window.makeFirstResponder(self)
    }

    func updateShortcutForwardingEventTap() {
        shortcutForwardingStartTask?.cancel()
        shortcutForwardingStartTask = nil
        guard shortcutForwardingEnabled, isKeyboardInputActive else {
            shortcutForwardingEventTap.stop()
            return
        }
        shortcutForwardingStartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, shortcutForwardingEnabled, isKeyboardInputActive else { return }
            shortcutForwardingStartTask = nil
            shortcutForwardingEventTap.start()
        }
    }

    func reportContainerSizeIfChanged(force: Bool = false) {
        if fullscreenGeometryDeferralActive {
            pendingContainerSizeReportDuringFullscreenDeferral = true
            return
        }

        let size = resolvedContainerSize
        guard size.width > 0, size.height > 0 else { return }
        guard force || size != lastReportedContainerSize else { return }
        lastReportedContainerSize = size
        onContainerSizeChanged?(size)
    }

    var resolvedContainerSize: CGSize {
        MirageStreamPresentationPolicy.containerSize(
            boundsSize: bounds.size,
            contentLayoutSize: window?.contentLayoutRect.size,
            mode: containerSizingMode
        )
    }

    func syncFullscreenTransitionObservers() {
        guard observedFullscreenWindow !== window else { return }
        removeFullscreenTransitionObservers()
        guard let window else { return }

        observedFullscreenWindow = window
        let notificationCenter = NotificationCenter.default

        let willEnter = notificationCenter.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginFullscreenGeometryDeferral()
            }
        }

        let willExit = notificationCenter.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginFullscreenGeometryDeferral()
            }
        }

        let didEnter = notificationCenter.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishFullscreenGeometryDeferralAfterDelay()
            }
        }

        let didExit = notificationCenter.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishFullscreenGeometryDeferralAfterDelay()
            }
        }

        fullscreenTransitionObservers = [willEnter, willExit, didEnter, didExit]
    }

    func removeFullscreenTransitionObservers() {
        for observer in fullscreenTransitionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        fullscreenTransitionObservers.removeAll()
        observedFullscreenWindow = nil
        fullscreenGeometryDeferralTask?.cancel()
        fullscreenGeometryDeferralTask = nil
        fullscreenGeometryDeferralActive = false
        pendingContainerSizeReportDuringFullscreenDeferral = false
    }

    func syncKeyboardActivationObservers() {
        guard observedKeyboardActivationWindow !== window else { return }
        removeKeyboardActivationObservers()
        guard let window else { return }

        observedKeyboardActivationWindow = window
        let notificationCenter = NotificationCenter.default

        let didBecomeKey = notificationCenter.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleKeyboardActivationStateChange()
            }
        }

        let didResignKey = notificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleKeyboardActivationStateChange()
            }
        }

        let didBecomeActive = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleKeyboardActivationStateChange()
            }
        }

        let didResignActive = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleKeyboardActivationStateChange()
            }
        }

        keyboardActivationObservers = [didBecomeKey, didResignKey, didBecomeActive, didResignActive]
    }

    func removeKeyboardActivationObservers() {
        for observer in keyboardActivationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyboardActivationObservers.removeAll()
        observedKeyboardActivationWindow = nil
    }

    func beginFullscreenGeometryDeferral() {
        fullscreenGeometryDeferralTask?.cancel()
        fullscreenGeometryDeferralTask = nil
        fullscreenGeometryDeferralActive = true
    }

    func finishFullscreenGeometryDeferralAfterDelay() {
        fullscreenGeometryDeferralTask?.cancel()
        fullscreenGeometryDeferralTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.fullscreenGeometrySettleDelay)
            } catch {
                return
            }

            guard let self else { return }
            fullscreenGeometryDeferralTask = nil
            fullscreenGeometryDeferralActive = false
            let shouldForceReport = pendingContainerSizeReportDuringFullscreenDeferral
            pendingContainerSizeReportDuringFullscreenDeferral = false
            guard shouldForceReport || resolvedContainerSize != lastReportedContainerSize else { return }
            reportContainerSizeIfChanged(force: true)
        }
    }

    func startModifierPollingIfNeeded() {
        guard modifierPollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.modifierPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollModifierState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPollTimer = timer
    }

    func stopModifierPolling() {
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
    }

    func syncModifierState(_ modifiers: MirageModifierFlags, force: Bool = false) {
        guard force || modifiers != currentModifiers else { return }
        currentModifiers = modifiers
        onMouseEvent?(.flagsChanged(modifiers))
    }

    func syncModifierStateFromSystem(force: Bool = false) {
        syncModifierState(MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags), force: force)
    }

    func pollModifierState() {
        guard isKeyboardInputActive else { return }
        let modifiers = MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags)
        if modifiers != currentModifiers {
            syncModifierState(modifiers, force: true)
            return
        }

        // Keep the host's held-modifier timestamps fresh for long holds.
        if !modifiers.isEmpty { onMouseEvent?(.flagsChanged(modifiers)) }
    }
}
#endif
