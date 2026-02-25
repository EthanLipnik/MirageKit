//
//  MirageWindowFocusObserver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import MirageKit
#if os(macOS)
import AppKit
import SwiftUI

/// Observes macOS window focus changes for a stream session.
/// Observes macOS window focus changes for a stream session.
struct MirageWindowFocusObserver: NSViewRepresentable {
    /// Session ID used to track focus state.
    let sessionID: StreamSessionID
    /// Stream ID for forwarding focus events.
    let streamID: StreamID
    /// Session store for focus updates.
    let sessionStore: MirageClientSessionStore
    /// Client service used to send focus input events.
    let clientService: MirageClientService
    /// Callback fired when the hosting macOS window is closing.
    let onWindowWillClose: (() -> Void)?

    func makeNSView(context _: Context) -> NSView {
        let view = FocusTrackingView()
        view.sessionID = sessionID
        view.streamID = streamID
        view.sessionStore = sessionStore
        view.clientService = clientService
        view.onWindowWillClose = onWindowWillClose
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class FocusTrackingView: NSView {
    var sessionID: StreamSessionID?
    var streamID: StreamID?
    var sessionStore: MirageClientSessionStore?
    var clientService: MirageClientService?
    var onWindowWillClose: (() -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        detachWindowObservers()
        attachWindowObservers()

        guard let window else { return }
        if window.isKeyWindow {
            sessionStore?.setFocusedSession(sessionID)
            notifyHostWindowFocused()
        }
    }

    private func attachWindowObservers() {
        guard let window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func detachWindowObservers() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: observedWindow
        )
        self.observedWindow = nil
    }

    @objc
    private func windowDidBecomeKey(_: Notification) {
        sessionStore?.setFocusedSession(sessionID)
        notifyHostWindowFocused()
    }

    @objc
    private func windowDidResignKey(_: Notification) {
        if sessionStore?.focusedSessionID == sessionID { sessionStore?.setFocusedSession(nil) }

        guard let streamID else { return }
        clientService?.sendInputFireAndForget(.flagsChanged([]), forStream: streamID)
    }

    @objc
    private func windowWillClose(_: Notification) {
        if sessionStore?.focusedSessionID == sessionID { sessionStore?.setFocusedSession(nil) }
        if let streamID {
            clientService?.sendInputFireAndForget(.flagsChanged([]), forStream: streamID)
        }
        onWindowWillClose?()
    }

    private func notifyHostWindowFocused() {
        guard let streamID else { return }
        clientService?.sendInputFireAndForget(.windowFocus, forStream: streamID)

        let modifiers = MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags)
        clientService?.sendInputFireAndForget(.flagsChanged(modifiers), forStream: streamID)
    }

    deinit {
        detachWindowObservers()
    }
}
#endif
