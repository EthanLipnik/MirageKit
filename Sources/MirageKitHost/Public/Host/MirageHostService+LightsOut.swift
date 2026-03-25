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
        lightsOutEnabled: Bool,
        lightsOutDisabledByEnvironment: Bool = false
    ) -> Bool {
        guard !lightsOutDisabledByEnvironment else { return false }
        #if DEBUG
        // In debug builds, app streaming does not force lights out so the
        // developer can still see and interact with the host display.
        return lightsOutEnabled && (hasDesktopStream || hasPendingDesktopStreamStart)
        #else
        return hasAppStreams || hasPendingAppStreamStart ||
            (lightsOutEnabled && (hasDesktopStream || hasPendingDesktopStreamStart))
        #endif
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
        cancelLightsOutScreenshotSuspension()
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

    func updateLightsOutState() async {
        guard sessionState == .ready else {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        if lightsOutScreenshotSuspended {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        let hasAppStreams = !activeStreams.isEmpty
        let hasDesktopStream = desktopStreamContext != nil
        let hasPendingAppStreamStart = pendingAppStreamStartCount > 0
        let hasPendingDesktopStreamStart = pendingDesktopStreamStartCount > 0
        let effectiveLightsOutEnabled = lightsOutEnabled && desktopStreamMode != .secondary
        let shouldEnableLightsOut = Self.shouldEnableLightsOut(
            hasAppStreams: hasAppStreams,
            hasDesktopStream: hasDesktopStream,
            hasPendingAppStreamStart: hasPendingAppStreamStart,
            hasPendingDesktopStreamStart: hasPendingDesktopStreamStart,
            lightsOutEnabled: effectiveLightsOutEnabled,
            lightsOutDisabledByEnvironment: lightsOutDisabledByEnvironment
        )
        guard shouldEnableLightsOut else {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        lightsOutController.updateTarget(.physicalDisplays)
        await refreshLightsOutCaptureExclusions()
    }

    func handleLightsOutScreenshotShortcut() async {
        guard lightsOutController.isActive else { return }

        lightsOutScreenshotSuspended = true
        lightsOutController.deactivate()
        await refreshLightsOutCaptureExclusions()

        lightsOutScreenshotSuspendTask?.cancel()
        lightsOutScreenshotSuspendTask = Task { @MainActor [weak self] in
            await self?.monitorLightsOutScreenshotSuspension()
        }
    }

    func refreshLightsOutCaptureExclusions() async {
        guard lightsOutController.isActive,
              let desktopContext = desktopStreamContext,
              desktopStreamMode == .mirrored else {
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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

            try? await Task.sleep(for: .milliseconds(delayMs))
            delayMs = min(200, Int(Double(delayMs) * 1.6))
        }

        return []
    }

    func cancelLightsOutScreenshotSuspension() {
        lightsOutScreenshotSuspendTask?.cancel()
        lightsOutScreenshotSuspendTask = nil
        lightsOutScreenshotSuspended = false
    }

    private func monitorLightsOutScreenshotSuspension() async {
        let pollInterval: Duration = .milliseconds(250)
        let minimumHold: Duration = .milliseconds(1500)
        let idleGrace: Duration = .seconds(1)
        let maxSuspension: Duration = .seconds(120)
        let clock = ContinuousClock()
        let startedAt = clock.now
        var idleSince: ContinuousClock.Instant?

        while !Task.isCancelled {
            let now = clock.now
            let elapsed = startedAt.duration(to: now)
            if elapsed >= maxSuspension {
                break
            }

            if isScreenshotCaptureAppRunning() {
                idleSince = nil
            } else if elapsed >= minimumHold {
                if idleSince == nil {
                    idleSince = now
                } else if let idleSince, idleSince.duration(to: now) >= idleGrace {
                    break
                }
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        lightsOutScreenshotSuspendTask = nil
        lightsOutScreenshotSuspended = false
        await updateLightsOutState()
    }

    private func isScreenshotCaptureAppRunning() -> Bool {
        let screenshotBundleIDs: Set<String> = [
            "com.apple.Screenshot",
            "com.apple.ScreenCaptureUI",
        ]

        return NSWorkspace.shared.runningApplications.contains { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return screenshotBundleIDs.contains(bundleIdentifier)
        }
    }

    nonisolated static func shouldLockHostWhenStreamingStops(
        lockHostWhenStreamingStops: Bool,
        sessionState: LoomSessionAvailability,
        hasAppStreams: Bool,
        hasDesktopStream: Bool,
        hasPendingAppStreamStart: Bool,
        hasPendingDesktopStreamStart: Bool
    ) -> Bool {
        guard lockHostWhenStreamingStops, sessionState == .ready else { return false }
        return !hasAppStreams &&
            !hasDesktopStream &&
            !hasPendingAppStreamStart &&
            !hasPendingDesktopStreamStart
    }

    func lockHostIfStreamingStopped() {
        guard Self.shouldLockHostWhenStreamingStops(
            lockHostWhenStreamingStops: lockHostWhenStreamingStops,
            sessionState: sessionState,
            hasAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamContext != nil,
            hasPendingAppStreamStart: pendingAppStreamStartCount > 0,
            hasPendingDesktopStreamStart: pendingDesktopStreamStartCount > 0
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
