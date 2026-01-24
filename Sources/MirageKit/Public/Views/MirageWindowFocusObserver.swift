//
//  MirageWindowFocusObserver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

#if os(macOS)
import SwiftUI
import AppKit

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

    func makeNSView(context: Context) -> NSView {
        let view = FocusTrackingView()
        view.sessionID = sessionID
        view.streamID = streamID
        view.sessionStore = sessionStore
        view.clientService = clientService
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusTrackingView: NSView {
    var sessionID: StreamSessionID?
    var streamID: StreamID?
    var sessionStore: MirageClientSessionStore?
    var clientService: MirageClientService?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }

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

        if window.isKeyWindow {
            sessionStore?.setFocusedSession(sessionID)
            notifyHostWindowFocused()
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        sessionStore?.setFocusedSession(sessionID)
        notifyHostWindowFocused()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        if sessionStore?.focusedSessionID == sessionID {
            sessionStore?.setFocusedSession(nil)
        }

        guard let streamID else { return }
        clientService?.sendInputFireAndForget(.flagsChanged([]), forStream: streamID)
    }

    private func notifyHostWindowFocused() {
        guard let streamID else { return }
        clientService?.sendInputFireAndForget(.windowFocus, forStream: streamID)

        let modifiers = MirageModifierFlags(nsEventFlags: NSEvent.modifierFlags)
        clientService?.sendInputFireAndForget(.flagsChanged(modifiers), forStream: streamID)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
#endif
