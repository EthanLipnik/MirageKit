//
//  MirageHostService+LightsOut.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Lights Out (curtain) mode support.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    nonisolated static func shouldEnableLightsOut(
        hasAppStreams: Bool,
        hasDesktopStream: Bool,
        hasPendingAppStreamStart: Bool,
        hasPendingDesktopStreamStart: Bool,
        desktopStreamMode: MirageDesktopStreamMode = .unified,
        lightsOutEnabled: Bool,
        lightsOutDisabledByEnvironment: Bool = false
    ) -> Bool {
        guard !lightsOutDisabledByEnvironment, lightsOutEnabled else { return false }
        let hasMirroredDesktopWorkload = (hasDesktopStream || hasPendingDesktopStreamStart) &&
            desktopStreamMode == .unified
        return hasAppStreams ||
            hasMirroredDesktopWorkload ||
            hasPendingAppStreamStart
    }

    /// Emergency recovery path for stuck Lights Out states.
    /// Disconnects all clients, clears overlays, and locks the host.
    public func performLightsOutEmergencyRecovery() async {
        let clients = connectedClients
        for client in clients {
            await disconnectClient(client)
        }

        await forceDisableLightsOut(reason: "emergency recovery")

        guard sessionState == .ready else { return }
        if let lockHostHandler {
            lockHostHandler()
            return
        }
        lockHost()
    }

    func forceDisableLightsOut(reason: String) async {
        pendingAppStreamStartCount = 0
        pendingDesktopStreamStartCount = 0
        lightsOutController.deactivate()
        await refreshLightsOutCaptureExclusions()
        await syncAppListRequestDeferralForInteractiveWorkload()
        MirageLogger.host("Lights Out forcibly disabled (\(reason))")
    }

    func beginPendingAppStreamLightsOutSetup() async {
        pendingAppStreamStartCount += 1
        await updateLightsOutState()
        await syncAppListRequestDeferralForInteractiveWorkload()
    }

    func endPendingAppStreamLightsOutSetup() async {
        pendingAppStreamStartCount = max(0, pendingAppStreamStartCount - 1)
        await updateLightsOutState()
        await syncAppListRequestDeferralForInteractiveWorkload()
        lockHostIfStreamingStopped()
    }

    func beginPendingDesktopStreamLightsOutSetup() async {
        pendingDesktopStreamStartCount += 1
        await updateLightsOutState()
        await syncAppListRequestDeferralForInteractiveWorkload()
    }

    func endPendingDesktopStreamLightsOutSetup() async {
        pendingDesktopStreamStartCount = max(0, pendingDesktopStreamStartCount - 1)
        await updateLightsOutState()
        await syncAppListRequestDeferralForInteractiveWorkload()
        lockHostIfStreamingStopped()
    }

    func cancelPendingDesktopStreamLightsOutSetup(reason: String) async {
        guard pendingDesktopStreamStartCount > 0 else { return }

        pendingDesktopStreamStartCount = 0
        await updateLightsOutState()
        await syncAppListRequestDeferralForInteractiveWorkload()
        MirageLogger.host("Lights Out pending desktop setup cleared (\(reason))")
    }

    func updateLightsOutState() async {
        guard sessionState != .unavailable else {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        let hasAppStreams = !activeStreams.isEmpty
        let hasDesktopStream = desktopStreamContext != nil
        let hasPendingAppStreamStart = pendingAppStreamStartCount > 0
        let hasPendingDesktopStreamStart = pendingDesktopStreamStartCount > 0
        let shouldEnableLightsOut = Self.shouldEnableLightsOut(
            hasAppStreams: hasAppStreams,
            hasDesktopStream: hasDesktopStream,
            hasPendingAppStreamStart: hasPendingAppStreamStart,
            hasPendingDesktopStreamStart: hasPendingDesktopStreamStart,
            desktopStreamMode: desktopStreamMode,
            lightsOutEnabled: lightsOutEnabled,
            lightsOutDisabledByEnvironment: lightsOutDisabledByEnvironment
        )
        guard shouldEnableLightsOut else {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        guard lightsOutController.updateTarget(
            .physicalDisplays,
            emergencyShortcut: lightsOutEmergencyShortcut
        ) else {
            await refreshLightsOutCaptureExclusions()
            return
        }
        await refreshLightsOutCaptureExclusions()
    }

    func refreshLightsOutCaptureExclusions() async {
        guard lightsOutController.isActive,
              let desktopContext = desktopStreamContext,
              desktopStreamMode == .unified else {
            await desktopStreamContext?.updateDisplayCaptureExclusions([])
            return
        }

        let excluded = await resolveLightsOutExcludedWindows()
        await desktopContext.updateDisplayCaptureExclusions(excluded)
    }

    func resolveLightsOutExcludedWindows(
        maxAttempts: Int = 4,
        initialDelayMs: Int = 30
    )
    async -> [SCWindowWrapper] {
        let overlayIDs = Set(lightsOutController.overlayWindowIDs)
        guard !overlayIDs.isEmpty else { return [] }

        let attempts = max(1, maxAttempts)
        var delayMs = max(10, initialDelayMs)

        for attempt in 1 ... attempts {
            do {
                let content = try await SCShareableContent.mirageHostContent()
                let windows = content.windows.filter { overlayIDs.contains($0.windowID) }
                if windows.count == overlayIDs.count || attempt == attempts {
                    return windows.map { SCWindowWrapper(window: $0) }
                }
            } catch {
                if attempt == attempts {
                    MirageLogger.error(.host, error: error, message: "Failed to resolve Lights Out exclusion windows: ")
                    return []
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                return []
            }
            delayMs = min(200, Int(Double(delayMs) * 1.6))
        }

        return []
    }

    private nonisolated static func shouldLockHostWhenStreamingStops(
        lockHostWhenStreamingStops: Bool,
        sessionState: LoomSessionAvailability,
        hasAppStreams: Bool,
        hasDesktopStream: Bool,
        hasPendingAppStreamStart: Bool,
        hasPendingDesktopStreamStart: Bool,
        triggeredByExplicitStreamStop: Bool = true
    ) -> Bool {
        guard triggeredByExplicitStreamStop, lockHostWhenStreamingStops, sessionState == .ready else { return false }
        return !hasAppStreams &&
            !hasDesktopStream &&
            !hasPendingAppStreamStart &&
            !hasPendingDesktopStreamStart
    }

    func lockHostIfStreamingStopped(triggeredByExplicitStreamStop: Bool = true) {
        guard Self.shouldLockHostWhenStreamingStops(
            lockHostWhenStreamingStops: lockHostWhenStreamingStops,
            sessionState: sessionState,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamContext != nil,
            hasPendingAppStreamStart: pendingAppStreamStartCount > 0,
            hasPendingDesktopStreamStart: pendingDesktopStreamStartCount > 0,
            triggeredByExplicitStreamStop: triggeredByExplicitStreamStop
        ) else { return }

        if let lockHostHandler {
            lockHostHandler()
            return
        }
        lockHost()
    }

    private func lockHost() {
        Task.detached(priority: .userInitiated) {
            if Self.lockHostUsingCGSessionCommand() { return }
            if Self.lockHostUsingKeyboardShortcut() { return }
            MirageLogger.error(.host, "Failed to lock host session: no supported lock strategy succeeded")
        }
    }

    nonisolated private static func lockHostUsingCGSessionCommand() -> Bool {
        let candidates = [
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            "/System/Library/CoreServices/CGSession",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: candidate)
            task.arguments = ["-suspend"]

            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    return true
                }
                MirageLogger.error(.host, "Lock command '\(candidate)' exited with status \(task.terminationStatus)")
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to run lock command '\(candidate)': ")
            }
        }

        return false
    }

    nonisolated private static func lockHostUsingKeyboardShortcut() -> Bool {
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            MirageLogger.error(.host, "Failed to create keyboard event source for lock shortcut")
            return false
        }

        let lockKeyCode: CGKeyCode = 12 // Q
        let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl]

        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: lockKeyCode,
            keyDown: true
        ),
            let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: lockKeyCode,
                keyDown: false
            ) else {
            MirageLogger.error(.host, "Failed to create keyboard events for lock shortcut")
            return false
        }

        keyDown.flags = shortcutFlags
        keyUp.flags = shortcutFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
#endif
