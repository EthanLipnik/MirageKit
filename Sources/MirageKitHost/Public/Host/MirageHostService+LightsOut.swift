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
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    /// Emergency recovery path for stuck Lights Out states.
    /// Disconnects all clients, clears overlays, and locks the host.
    public func performLightsOutEmergencyRecovery() async {
        let clients = connectedClients
        for client in clients {
            await disconnectClient(client)
        }

        cancelLightsOutScreenshotSuspension()
        lightsOutController.deactivate()
        await refreshLightsOutCaptureExclusions()

        guard sessionState == .active else { return }
        if let lockHostHandler {
            lockHostHandler()
            return
        }
        lockHost()
    }

    func updateLightsOutState() async {
        guard lightsOutEnabled else {
            lightsOutController.deactivate()
            await refreshLightsOutCaptureExclusions()
            return
        }

        guard sessionState == .active else {
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
        let hasMirroredDesktop = desktopStreamContext != nil && desktopStreamMode == .mirrored
        guard hasAppStreams || hasMirroredDesktop else {
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
                    MirageLogger.error(.host, "Failed to resolve Lights Out exclusion windows: \(error)")
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

    func lockHostIfNeeded() {
        guard lockHostOnDisconnect, sessionState == .active else { return }
        if let lockHostHandler {
            lockHostHandler()
            return
        }
        lockHost()
    }

    private func lockHost() {
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
            task.arguments = ["-suspend"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                MirageLogger.error(.host, "Failed to lock host session: \(error)")
            }
        }
    }
}
#endif
