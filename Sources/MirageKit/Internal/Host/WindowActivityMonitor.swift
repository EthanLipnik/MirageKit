//
//  WindowActivityMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation

#if os(macOS)
import AppKit
import CoreGraphics

/// Monitors which windows are "active" (their app is frontmost) for stream throttling.
/// Inactive streams can be throttled to ~1fps to save CPU/GPU/bandwidth.
actor WindowActivityMonitor {
    /// Callback when a window's activity state changes
    /// Parameters: windowID, isActive
    private var onActivityChange: (@Sendable (WindowID, Bool) async -> Void)?

    /// Currently tracked windows and their last known active state
    private var trackedWindows: [WindowID: Bool] = [:]

    /// Polling timer for activity checks
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.mirage.windowActivity", qos: .utility)

    /// Polling interval - 500ms is frequent enough to detect focus changes quickly
    /// while not being too expensive
    private let pollInterval: TimeInterval = 0.5

    /// Whether monitoring is currently active
    private var isMonitoring = false

    // MARK: - Public API

    /// Start monitoring activity for specified windows
    /// - Parameters:
    ///   - windows: Window IDs to monitor
    ///   - onActivityChange: Callback when a window's activity state changes (windowID, isActive)
    func start(
        windows: [WindowID],
        onActivityChange: @escaping @Sendable (WindowID, Bool) async -> Void
    ) {
        guard !isMonitoring else { return }
        isMonitoring = true

        self.onActivityChange = onActivityChange

        // Initialize all windows as active (optimistic - full frame rate until proven inactive)
        for windowID in windows {
            trackedWindows[windowID] = true
        }

        startPolling()
        MirageLogger.host("WindowActivityMonitor started for \(windows.count) windows")
    }

    /// Add a window to monitoring
    /// - Parameter windowID: The window ID to start tracking
    func addWindow(_ windowID: WindowID) {
        trackedWindows[windowID] = true  // New windows start as active
        MirageLogger.host("WindowActivityMonitor: Added window \(windowID)")

        // Immediately check actual state
        Task { await checkActivityState() }
    }

    /// Remove a window from monitoring
    /// - Parameter windowID: The window ID to stop tracking
    func removeWindow(_ windowID: WindowID) {
        trackedWindows.removeValue(forKey: windowID)
        MirageLogger.host("WindowActivityMonitor: Removed window \(windowID)")
    }

    /// Stop all monitoring
    func stop() {
        isMonitoring = false
        pollTimer?.cancel()
        pollTimer = nil
        trackedWindows.removeAll()
        onActivityChange = nil
        MirageLogger.host("WindowActivityMonitor stopped")
    }

    // MARK: - Private

    private func startPolling() {
        pollTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: pollInterval)

        // Use Task.detached to avoid capturing mutable actor state
        timer.setEventHandler { [weak self] in
            Task.detached { [weak self] in
                await self?.checkActivityState()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Check activity state for all tracked windows
    private func checkActivityState() async {
        guard isMonitoring, !trackedWindows.isEmpty else { return }

        // Get frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let frontPID = frontApp.processIdentifier

        // Get window info for all windows to find their owner PIDs
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        // Build a map of windowID -> ownerPID
        var windowOwners: [CGWindowID: pid_t] = [:]
        for windowInfo in windowList {
            guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            windowOwners[CGWindowID(windowNumber)] = ownerPID
        }

        // Check each tracked window
        for (windowID, wasActive) in trackedWindows {
            // Find this window's owner PID
            guard let ownerPID = windowOwners[windowID] else {
                // Window not found in system list - may have been closed
                continue
            }

            // Window is active if its app is frontmost
            let isActive = ownerPID == frontPID

            // Notify on state change
            if isActive != wasActive {
                trackedWindows[windowID] = isActive

                let activityString = isActive ? "active" : "inactive"
                MirageLogger.host("Window \(windowID) became \(activityString) (PID \(ownerPID), front PID \(frontPID))")

                // Call the async callback
                await onActivityChange?(windowID, isActive)
            }
        }
    }
}

#endif
