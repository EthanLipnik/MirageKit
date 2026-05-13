//
//  MenuBarMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageKit
#if os(macOS)
import Foundation

/// Polls Accessibility menu-bar state for streamed applications and publishes structural changes.
///
/// Since Accessibility APIs don't provide direct notifications for menu content changes,
/// this monitor polls the menu bar periodically and detects changes by comparing versions.
actor MenuBarMonitor {
    // MARK: - Types

    /// Cached menu-bar state and callback for one active stream.
    private struct MonitoredStream {
        let pid: pid_t
        let bundleIdentifier: String
        let onChange: @Sendable (MirageMenuBar) -> Void
        var lastMenuBar: MirageMenuBar?
    }

    // MARK: - Properties

    /// Active streams keyed by Mirage stream ID.
    private var monitoredStreams: [StreamID: MonitoredStream] = [:]

    /// Accessibility extractor used for snapshots and menu actions.
    private let extractor = MenuBarExtractor()

    /// Delay between menu-bar snapshots.
    private let pollInterval: TimeInterval

    /// Polling task shared by all monitored streams.
    private var monitorTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new menu bar monitor.
    ///
    /// - Parameter pollInterval: How often to check for menu changes.
    init(pollInterval: TimeInterval = 1.0) {
        self.pollInterval = pollInterval
    }

    // MARK: - Public API

    /// Starts monitoring menu-bar changes for a stream and immediately publishes the first snapshot.
    ///
    /// - Parameters:
    ///   - streamID: Stream receiving menu-bar updates.
    ///   - pid: Process ID of the source application.
    ///   - bundleIdentifier: Bundle identifier of the source application.
    ///   - onChange: Callback invoked on the monitor actor when the menu bar changes.
    func startMonitoring(
        streamID: StreamID,
        pid: pid_t,
        bundleIdentifier: String,
        onChange: @escaping @Sendable (MirageMenuBar) -> Void
    )
    async {
        let initialMenuBar = await extractor.extractMenuBar(for: pid, bundleIdentifier: bundleIdentifier)

        monitoredStreams[streamID] = MonitoredStream(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            onChange: onChange,
            lastMenuBar: initialMenuBar
        )

        if let menuBar = initialMenuBar { onChange(menuBar) }

        if monitorTask == nil { startPolling() }

        MirageLogger.log(.menuBar, "Started monitoring menu bar for stream \(streamID)")
    }

    /// Stops monitoring menu bar changes for a stream.
    ///
    /// - Parameter streamID: Stream to remove from menu-bar polling.
    func stopMonitoring(streamID: StreamID) {
        monitoredStreams.removeValue(forKey: streamID)

        if monitoredStreams.isEmpty { stopPolling() }

        MirageLogger.log(.menuBar, "Stopped monitoring menu bar for stream \(streamID)")
    }

    // MARK: - Polling

    /// Starts the background polling task.
    private func startPolling() {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAllStreams()
                do {
                    try await Task.sleep(for: .seconds(self?.pollInterval ?? 1.0))
                } catch {
                    break
                }
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

        guard let newMenuBar else { return }

        if hasMenuBarChanged(old: stream.lastMenuBar, new: newMenuBar) {
            var updatedStream = stream
            updatedStream.lastMenuBar = newMenuBar
            monitoredStreams[streamID] = updatedStream

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
        if old.menus.count != new.menus.count { return true }
        return zip(old.menus, new.menus).contains { menuHasChanged(old: $0, new: $1) }
    }

    /// Checks if a menu has changed.
    private func menuHasChanged(old: MirageMenu, new: MirageMenu) -> Bool {
        if old.title != new.title { return true }
        if old.items.count != new.items.count { return true }
        return zip(old.items, new.items).contains { menuItemHasChanged(old: $0, new: $1) }
    }

    /// Checks if a menu item has changed.
    private func menuItemHasChanged(old: MirageMenuItem, new: MirageMenuItem) -> Bool {
        if old.title != new.title ||
            old.isEnabled != new.isEnabled ||
            old.isChecked != new.isChecked ||
            old.isMixed != new.isMixed ||
            old.isSeparator != new.isSeparator {
            return true
        }

        if let oldSubmenu = old.submenu, let newSubmenu = new.submenu {
            if oldSubmenu.count != newSubmenu.count { return true }
            return zip(oldSubmenu, newSubmenu).contains { menuItemHasChanged(old: $0, new: $1) }
        } else if old.submenu != nil || new.submenu != nil {
            return true
        }

        return false
    }

    // MARK: - Action Execution

    /// Performs a menu action directly on a process.
    ///
    /// - Parameters:
    ///   - pid: Process ID of the target application
    ///   - actionPath: Path to the menu item
    /// - Returns: True if the action was performed successfully
    func performMenuAction(pid: pid_t, actionPath: [Int]) async -> Bool {
        await extractor.performMenuAction(pid: pid, actionPath: actionPath)
    }
}
#endif
