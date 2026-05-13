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
        return window.isKeyWindow && window.firstResponder === self
    }

    func handleInputActivityStateChange() {
        if isInputProcessingActive {
            updateCursorLockMode()
            if shortcutForwardingEnabled {
                shortcutForwardingEventTap.start()
            } else {
                shortcutForwardingEventTap.stop()
            }
            startModifierPollingIfNeeded()
            syncModifierStateFromSystem(force: true)
        } else {
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

    func reportContainerSizeIfChanged(force: Bool = false) {
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
