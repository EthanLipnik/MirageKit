//
//  MenuBarMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

#if os(macOS)
import Foundation

/// Monitors menu bar changes for streamed applications using polling.
///
/// Since Accessibility APIs don't provide direct notifications for menu content changes,
/// this monitor polls the menu bar periodically and detects changes by comparing versions.
actor MenuBarMonitor {

    // MARK: - Types

    /// Information about a monitored stream
    private struct MonitoredStream {
        let pid: pid_t
        let bundleIdentifier: String
        let onChange: @Sendable (MirageMenuBar) -> Void
        var lastMenuBar: MirageMenuBar?
    }

    // MARK: - Properties

    /// Active streams being monitored
    private var monitoredStreams: [StreamID: MonitoredStream] = [:]

    /// The menu bar extractor
    private let extractor = MenuBarExtractor()

    /// Polling interval in seconds
    private let pollInterval: TimeInterval

    /// Background monitoring task
    private var monitorTask: Task<Void, Never>?

    /// Whether monitoring is currently active
    private var isMonitoring: Bool { monitorTask != nil }

    // MARK: - Initialization

    /// Creates a new menu bar monitor.
    ///
    /// - Parameter pollInterval: How often to check for menu changes (default 1 second)
    init(pollInterval: TimeInterval = 1.0) {
        self.pollInterval = pollInterval
    }

    // MARK: - Public API

    /// Starts monitoring menu bar changes for a stream.
    ///
    /// - Parameters:
    ///   - streamID: The stream to monitor
    ///   - pid: Process ID of the application
    ///   - bundleIdentifier: Bundle identifier of the application
    ///   - onChange: Callback invoked when menu bar changes (called on actor)
    func startMonitoring(
        streamID: StreamID,
        pid: pid_t,
        bundleIdentifier: String,
        onChange: @escaping @Sendable (MirageMenuBar) -> Void
    ) async {
        // Extract initial menu bar
        let initialMenuBar = await extractor.extractMenuBar(for: pid, bundleIdentifier: bundleIdentifier)

        // Store the stream info
        monitoredStreams[streamID] = MonitoredStream(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            onChange: onChange,
            lastMenuBar: initialMenuBar
        )

        // Send initial menu bar if we got one
        if let menuBar = initialMenuBar {
            onChange(menuBar)
        }

        // Start polling if not already running
        if !isMonitoring {
            startPolling()
        }

        MirageLogger.log(.menuBar, "Started monitoring menu bar for stream \(streamID)")
    }

    /// Stops monitoring menu bar changes for a stream.
    ///
    /// - Parameter streamID: The stream to stop monitoring
    func stopMonitoring(streamID: StreamID) {
        monitoredStreams.removeValue(forKey: streamID)

        // Stop polling if no more streams
        if monitoredStreams.isEmpty {
            stopPolling()
        }

        MirageLogger.log(.menuBar, "Stopped monitoring menu bar for stream \(streamID)")
    }

    /// Gets the current menu bar for a stream.
    ///
    /// - Parameter streamID: The stream to get menu bar for
    /// - Returns: The current menu bar, or nil if not found
    func currentMenuBar(for streamID: StreamID) -> MirageMenuBar? {
        monitoredStreams[streamID]?.lastMenuBar
    }

    /// Forces a refresh of the menu bar for a stream.
    ///
    /// - Parameter streamID: The stream to refresh
    /// - Returns: The refreshed menu bar, or nil if extraction failed
    func refreshMenuBar(for streamID: StreamID) async -> MirageMenuBar? {
        guard var stream = monitoredStreams[streamID] else { return nil }

        let newMenuBar = await extractor.extractMenuBar(
            for: stream.pid,
            bundleIdentifier: stream.bundleIdentifier
        )

        if let menuBar = newMenuBar {
            stream.lastMenuBar = menuBar
            monitoredStreams[streamID] = stream
            stream.onChange(menuBar)
        }

        return newMenuBar
    }

    // MARK: - Polling

    /// Starts the background polling task.
    private func startPolling() {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAllStreams()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 1.0))
            }
        }

        MirageLogger.log(.menuBar, "Started menu bar polling")
    }

    /// Stops the background polling task.
    private func stopPolling() {
        monitorTask?.cancel()
        monitorTask = nil

        MirageLogger.log(.menuBar, "Stopped menu bar polling")
    }

    /// Polls all monitored streams for menu bar changes.
    private func pollAllStreams() async {
        for (streamID, stream) in monitoredStreams {
            await pollStream(streamID: streamID, stream: stream)
        }
    }

    /// Polls a single stream for menu bar changes.
    private func pollStream(streamID: StreamID, stream: MonitoredStream) async {
        let newMenuBar = await extractor.extractMenuBar(
            for: stream.pid,
            bundleIdentifier: stream.bundleIdentifier
        )

        guard let newMenuBar else {
            // Extraction failed - app might have quit
            return
        }

        // Check if menu bar changed
        if hasMenuBarChanged(old: stream.lastMenuBar, new: newMenuBar) {
            // Update cached version
            var updatedStream = stream
            updatedStream.lastMenuBar = newMenuBar
            monitoredStreams[streamID] = updatedStream

            // Notify listener
            stream.onChange(newMenuBar)

            MirageLogger.log(.menuBar, "Menu bar changed for stream \(streamID)")
        }
    }

    /// Checks if the menu bar has changed.
    ///
    /// This performs a structural comparison rather than relying on version numbers,
    /// as we generate version numbers ourselves.
    private func hasMenuBarChanged(old: MirageMenuBar?, new: MirageMenuBar) -> Bool {
        guard let old else { return true }

        // Quick check: different number of menus
        if old.menus.count != new.menus.count { return true }

        // Compare each menu
        for (oldMenu, newMenu) in zip(old.menus, new.menus) {
            if menuHasChanged(old: oldMenu, new: newMenu) {
                return true
            }
        }

        return false
    }

    /// Checks if a menu has changed.
    private func menuHasChanged(old: MirageMenu, new: MirageMenu) -> Bool {
        if old.title != new.title { return true }
        if old.items.count != new.items.count { return true }

        for (oldItem, newItem) in zip(old.items, new.items) {
            if menuItemHasChanged(old: oldItem, new: newItem) {
                return true
            }
        }

        return false
    }

    /// Checks if a menu item has changed.
    private func menuItemHasChanged(old: MirageMenuItem, new: MirageMenuItem) -> Bool {
        // Compare basic properties
        if old.title != new.title { return true }
        if old.isEnabled != new.isEnabled { return true }
        if old.isChecked != new.isChecked { return true }
        if old.isMixed != new.isMixed { return true }
        if old.isSeparator != new.isSeparator { return true }

        // Compare submenus
        if let oldSubmenu = old.submenu, let newSubmenu = new.submenu {
            if oldSubmenu.count != newSubmenu.count { return true }
            for (oldSub, newSub) in zip(oldSubmenu, newSubmenu) {
                if menuItemHasChanged(old: oldSub, new: newSub) {
                    return true
                }
            }
        } else if old.submenu != nil || new.submenu != nil {
            // One has submenu, other doesn't
            return true
        }

        return false
    }

    // MARK: - Action Execution

    /// Performs a menu action on the application associated with a stream.
    ///
    /// - Parameters:
    ///   - streamID: The stream to perform the action on
    ///   - actionPath: Path to the menu item
    /// - Returns: True if the action was performed successfully
    func performMenuAction(streamID: StreamID, actionPath: [Int]) async -> Bool {
        guard let stream = monitoredStreams[streamID] else {
            MirageLogger.log(.menuBar, "No monitored stream for action: \(streamID)")
            return false
        }

        return await extractor.performMenuAction(pid: stream.pid, actionPath: actionPath)
    }

    /// Performs a menu action directly on a process.
    ///
    /// - Parameters:
    ///   - pid: Process ID of the target application
    ///   - actionPath: Path to the menu item
    /// - Returns: True if the action was performed successfully
    func performMenuAction(pid: pid_t, actionPath: [Int]) async -> Bool {
        return await extractor.performMenuAction(pid: pid, actionPath: actionPath)
    }

    // MARK: - Cleanup

    /// Stops monitoring all streams and cleans up resources.
    func stopAll() {
        stopPolling()
        monitoredStreams.removeAll()
    }
}
#endif
