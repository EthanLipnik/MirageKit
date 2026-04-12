//
//  MirageHostInputController+SystemActions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension MirageHostInputController {
    private static let systemActionKeyReleaseDelay: DispatchTimeInterval = .milliseconds(50)

    func executeHostSystemAction(
        _ request: MirageHostSystemActionRequest,
        domain: HostKeyboardInjectionDomain
    ) {
        switch HostSymbolicHotKeyResolver.resolve(request.action) {
        case let .shortcut(resolvedShortcut):
            injectHostShortcut(resolvedShortcut, domain: domain)
        case .disabled:
            MirageLogger.host(
                "Skipping host system action \(request.action.diagnosticLabel) because the host shortcut is disabled"
            )
        case .unavailable:
            guard let fallbackKeyEvent = request.fallbackKeyEvent else {
                MirageLogger.host(
                    "Skipping host system action \(request.action.diagnosticLabel) because no shortcut could be resolved"
                )
                return
            }
            MirageLogger.host(
                "Falling back to built-in shortcut for host system action \(request.action.diagnosticLabel)"
            )
            injectHostShortcut(fallbackKeyEvent, domain: domain)
        }
    }

    private func injectHostShortcut(
        _ keyEvent: MirageKeyEvent,
        domain: HostKeyboardInjectionDomain
    ) {
        clearUnexpectedSystemModifiers(domain: domain)

        if !keyEvent.modifiers.isEmpty {
            injectFlagsChanged(keyEvent.modifiers, domain: domain, app: nil)
        }
        injectKeyEvent(isKeyDown: true, keyEvent, domain: domain, app: nil)

        accessibilityQueue.asyncAfter(
            deadline: .now() + Self.systemActionKeyReleaseDelay
        ) { [weak self] in
            guard let self else { return }

            self.injectKeyEvent(isKeyDown: false, keyEvent, domain: domain, app: nil)
            if !keyEvent.modifiers.isEmpty {
                self.injectFlagsChanged([], domain: domain, app: nil)
            }
        }
    }
}

private extension MirageHostSystemAction {
    var diagnosticLabel: String {
        switch self {
        case .spaceLeft:
            "Move Left a Space"
        case .spaceRight:
            "Move Right a Space"
        case .missionControl:
            "Mission Control"
        case .appExpose:
            "App Exposé"
        }
    }
}
#endif
