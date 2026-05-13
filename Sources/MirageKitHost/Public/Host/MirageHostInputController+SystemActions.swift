//
//  MirageHostInputController+SystemActions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit

extension MirageHostInputController {
    private static let systemActionKeyReleaseDelay: DispatchTimeInterval = .milliseconds(50)
    private static let systemActionInjectionDomain: HostKeyboardInjectionDomain = .session
    private static let systemActionCooldown: CFAbsoluteTime = 0.45
    static let missionControlApplicationURL = URL(filePath: "/System/Applications/Mission Control.app")

    /// Executes a host-level system action requested by a client.
    func executeHostSystemAction(_ request: MirageHostSystemActionRequest) {
        guard beginSystemActionIfAllowed(request.action) else {
            MirageLogger.host("Skipping host system action \(request.action.diagnosticLabel) during cooldown")
            return
        }

        executeResolvedHostSystemAction(request, allowApplicationFallback: true)
    }

    /// Starts a cooldown window for a system action if one is not already active.
    private func beginSystemActionIfAllowed(_ action: MirageHostSystemAction) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let inFlightUntil = systemActionInFlightUntilByAction[action],
           now < inFlightUntil {
            return false
        }
        systemActionInFlightUntilByAction[action] = now + Self.systemActionCooldown
        return true
    }

    /// Returns Mission Control app launch arguments for actions that support app fallback.
    static func missionControlLaunchArguments(for action: MirageHostSystemAction) -> [String]? {
        switch action {
        case .missionControl:
            []
        case .appExpose:
            ["2"]
        case .spaceLeft, .spaceRight:
            nil
        }
    }

    /// Launches Mission Control as a fallback for disabled or unavailable symbolic hot keys.
    private func launchMissionControl(
        arguments: [String],
        fallbackRequest: MirageHostSystemActionRequest
    ) {
        Task { @MainActor [weak self] in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = arguments

            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: Self.missionControlApplicationURL,
                    configuration: configuration
                )
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to launch Mission Control app for \(fallbackRequest.action.diagnosticLabel): "
                )
                self?.accessibilityQueue.async { [weak self] in
                    self?.executeResolvedHostSystemAction(fallbackRequest, allowApplicationFallback: false)
                }
            }
        }
    }

    /// Resolves a host system action to a configured shortcut, app fallback, or built-in shortcut.
    private func executeResolvedHostSystemAction(
        _ request: MirageHostSystemActionRequest,
        allowApplicationFallback: Bool
    ) {
        switch HostSymbolicHotKeyResolver.resolve(request.action) {
        case let .shortcut(resolvedShortcut):
            injectHostShortcut(resolvedShortcut)
        case .disabled:
            if allowApplicationFallback,
               let launchArguments = Self.missionControlLaunchArguments(for: request.action) {
                MirageLogger.host("Falling back to Mission Control app launch for \(request.action.diagnosticLabel)")
                launchMissionControl(arguments: launchArguments, fallbackRequest: request)
            } else {
                fallbackToBuiltInHostSystemShortcut(request, reason: "host shortcut is disabled")
            }
        case .unavailable:
            if allowApplicationFallback,
               let launchArguments = Self.missionControlLaunchArguments(for: request.action) {
                MirageLogger.host("Falling back to Mission Control app launch for \(request.action.diagnosticLabel)")
                launchMissionControl(arguments: launchArguments, fallbackRequest: request)
            } else {
                fallbackToBuiltInHostSystemShortcut(request, reason: "no shortcut could be resolved")
            }
        }
    }

    /// Falls back to the protocol-provided built-in shortcut for a system action.
    private func fallbackToBuiltInHostSystemShortcut(
        _ request: MirageHostSystemActionRequest,
        reason: String
    ) {
        guard let fallbackKeyEvent = request.fallbackKeyEvent else {
            MirageLogger.host(
                "Skipping host system action \(request.action.diagnosticLabel) because \(reason)"
            )
            return
        }
        MirageLogger.host(
            "Falling back to built-in shortcut for host system action \(request.action.diagnosticLabel) because \(reason)"
        )
        injectHostShortcut(fallbackKeyEvent)
    }

    /// Injects a shortcut and releases its key/modifier state after a short delay.
    private func injectHostShortcut(_ keyEvent: MirageKeyEvent) {
        let domain = Self.systemActionInjectionDomain
        clearUnexpectedSystemModifiers(domain: domain)

        if !keyEvent.modifiers.isEmpty {
            injectFlagsChanged(keyEvent.modifiers, domain: domain)
        }
        injectKeyEvent(isKeyDown: true, keyEvent, domain: domain)

        accessibilityQueue.asyncAfter(
            deadline: .now() + Self.systemActionKeyReleaseDelay
        ) { [weak self] in
            guard let self else { return }

            injectKeyEvent(isKeyDown: false, keyEvent, domain: domain)
            if !keyEvent.modifiers.isEmpty {
                injectFlagsChanged([], domain: domain)
            }
        }
    }
}

private extension MirageHostSystemAction {
    /// Human-readable label used in host system action diagnostics.
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
