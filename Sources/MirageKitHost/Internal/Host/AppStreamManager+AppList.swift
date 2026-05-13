//
//  AppStreamManager+AppList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager extensions.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation

extension AppStreamManager {
    // MARK: - App List

    /// Returns installed applications with current running and streaming status.
    func installedApps(
        includeIcons: Bool = true,
        forceRefresh: Bool = false,
        onAppDiscovered: (@Sendable (MirageInstalledApp) async -> Void)? = nil
    )
    async -> [MirageInstalledApp] {
        if Task.isCancelled {
            let cached = includeIcons ? cachedAppsWithIcons : cachedAppsWithoutIcons
            return await refreshStatuses(for: cached)
        }

        let now = Date()
        let currentStatusSnapshot = statusSnapshot

        if forceRefresh {
            let scanned = await applicationScanner.scanInstalledApps(
                includeIcons: includeIcons,
                runningApps: currentStatusSnapshot.runningApps,
                streamingApps: currentStatusSnapshot.streamingApps,
                onAppDiscovered: onAppDiscovered
            )
            if Task.isCancelled {
                let cached = includeIcons ? cachedAppsWithIcons : cachedAppsWithoutIcons
                return await refreshStatuses(for: cached)
            }

            let refreshed = await refreshStatuses(for: scanned)
            if includeIcons {
                cachedAppsWithIcons = refreshed
                lastAppsScanWithIconsAt = now
            } else {
                cachedAppsWithoutIcons = refreshed
                lastAppsScanWithoutIconsAt = now
            }
            return refreshed
        }

        if includeIcons {
            if let task = appScanTaskWithIcons {
                let apps = await task.value
                let wasCancelled = task.isCancelled
                if wasCancelled {
                    return await refreshStatuses(for: cachedAppsWithIcons)
                }
                let refreshed = await refreshStatuses(for: apps)
                await replayInstalledApps(refreshed, onAppDiscovered: onAppDiscovered)
                cachedAppsWithIcons = refreshed
                lastAppsScanWithIconsAt = now
                return refreshed
            }

            if isCacheValid(lastAppsScanWithIconsAt, ttl: appScanWithIconsTTL, now: now),
               !cachedAppsWithIcons.isEmpty {
                let refreshed = await refreshStatuses(for: cachedAppsWithIcons)
                await replayInstalledApps(refreshed, onAppDiscovered: onAppDiscovered)
                return refreshed
            }

            let task = Task(priority: .utility) { [applicationScanner] in
                await applicationScanner.scanInstalledApps(
                    includeIcons: true,
                    runningApps: currentStatusSnapshot.runningApps,
                    streamingApps: currentStatusSnapshot.streamingApps,
                    onAppDiscovered: onAppDiscovered
                )
            }
            appScanTaskWithIcons = task
            let apps = await task.value
            let wasCancelled = task.isCancelled
            appScanTaskWithIcons = nil

            if wasCancelled {
                return await refreshStatuses(for: cachedAppsWithIcons)
            }
            let refreshed = await refreshStatuses(for: apps)
            cachedAppsWithIcons = refreshed
            lastAppsScanWithIconsAt = now
            return refreshed
        }

        if let task = appScanTaskWithoutIcons {
            let apps = await task.value
            let wasCancelled = task.isCancelled
            if wasCancelled {
                return await refreshStatuses(for: cachedAppsWithoutIcons)
            }
            let refreshed = await refreshStatuses(for: apps)
            await replayInstalledApps(refreshed, onAppDiscovered: onAppDiscovered)
            cachedAppsWithoutIcons = refreshed
            lastAppsScanWithoutIconsAt = now
            return refreshed
        }

        if isCacheValid(lastAppsScanWithoutIconsAt, ttl: appScanWithoutIconsTTL, now: now),
           !cachedAppsWithoutIcons.isEmpty {
            let refreshed = await refreshStatuses(for: cachedAppsWithoutIcons)
            await replayInstalledApps(refreshed, onAppDiscovered: onAppDiscovered)
            return refreshed
        }

        let task = Task(priority: .utility) { [applicationScanner] in
            await applicationScanner.scanInstalledApps(
                includeIcons: false,
                runningApps: currentStatusSnapshot.runningApps,
                streamingApps: currentStatusSnapshot.streamingApps,
                onAppDiscovered: onAppDiscovered
            )
        }
        appScanTaskWithoutIcons = task
        let apps = await task.value
        let wasCancelled = task.isCancelled
        appScanTaskWithoutIcons = nil

        if wasCancelled {
            return await refreshStatuses(for: cachedAppsWithoutIcons)
        }
        let refreshed = await refreshStatuses(for: apps)
        cachedAppsWithoutIcons = refreshed
        lastAppsScanWithoutIconsAt = now
        return refreshed
    }

    /// Replays discovered apps to a progress callback from cached results.
    func replayInstalledApps(
        _ apps: [MirageInstalledApp],
        onAppDiscovered: (@Sendable (MirageInstalledApp) async -> Void)?
    ) async {
        guard let onAppDiscovered else { return }
        for app in apps {
            if Task.isCancelled { return }
            await onAppDiscovered(app)
        }
    }

    /// Cancels any in-flight installed app scans.
    func cancelAppListScans() {
        appScanTaskWithIcons?.cancel()
        appScanTaskWithoutIcons?.cancel()
        appScanTaskWithIcons = nil
        appScanTaskWithoutIcons = nil
    }

    /// Generates icon payload data for an installed app path.
    func iconDataForInstalledApp(
        atPath appPath: String,
        maxPixelSize: Int,
        heifCompressionQuality: Double
    ) async -> Data? {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        return await applicationScanner.generateIconPayloadData(
            for: appURL,
            maxPixelSize: maxPixelSize,
            heifCompressionQuality: heifCompressionQuality
        )
    }

    /// Current lowercased bundle identifiers for running apps and active app-stream sessions.
    private var statusSnapshot: (runningApps: Set<String>, streamingApps: Set<String>) {
        let runningApps = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier?.lowercased() }
        )
        let streamingApps = Set(sessions.keys.map { $0.lowercased() })
        return (runningApps, streamingApps)
    }

    /// Refreshes running/streaming state for a list of installed apps.
    private func refreshStatuses(for apps: [MirageInstalledApp]) async -> [MirageInstalledApp] {
        let currentStatusSnapshot = statusSnapshot
        return await applicationScanner.updateStatus(
            for: apps,
            runningApps: currentStatusSnapshot.runningApps,
            streamingApps: currentStatusSnapshot.streamingApps
        )
    }

    /// Returns whether a cached app scan is still within its TTL.
    private func isCacheValid(_ lastScan: Date?, ttl: TimeInterval, now: Date) -> Bool {
        lastScan.map { now.timeIntervalSince($0) <= ttl } ?? false
    }
}

#endif
