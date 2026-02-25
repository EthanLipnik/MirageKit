//
//  AppStreamManager+WindowMonitoring.swift
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
import ScreenCaptureKit

extension AppStreamManager {
    // MARK: - Window Monitoring

    func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitoringTask = Task { [weak self] in
            await self?.monitoringLoop()
        }

        logger.debug("Started window monitoring")
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        logger.debug("Stopped window monitoring")
    }

    private func monitoringLoop() async {
        while !Task.isCancelled, isMonitoring {
            await checkForWindowChanges()
            await checkForExpiredCooldowns()
            await checkForExpiredReservations()

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func checkForWindowChanges() async {
        guard !sessions.isEmpty else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let bundleIDs = Array(sessions.keys)

            for bundleID in bundleIDs {
                guard let session = sessions[bundleID],
                      case .streaming = session.state else { continue }

                // Get windows for this app
                let appWindows = content.windows.filter { window in
                    guard let app = window.owningApplication else { return false }
                    return app.bundleIdentifier.lowercased() == bundleID
                }

                // Filter to valid windows (using existing filtering criteria)
                let validWindows = appWindows.filter { window in
                    let hasMinSize = window.frame.width >= 200 && window.frame.height >= 150
                    let isNormalLayer = window.windowLayer == 0
                    let hasOwner = window.owningApplication != nil
                    return hasMinSize && isNormalLayer && hasOwner
                }

                let currentValidIDs = Set(validWindows.map { WindowID($0.windowID) })

                // Check for new windows - only windows we haven't seen before AND are on-screen.
                // IMPORTANT: mutate the live session entry directly to avoid clobbering stream state
                // that callback handlers may update while this loop is running.
                for window in validWindows where window.isOnScreen {
                    let windowID = WindowID(window.windowID)
                    guard sessions[bundleID]?.knownWindowIDs.contains(windowID) != true else { continue }
                    sessions[bundleID]?.knownWindowIDs.insert(windowID)
                    logger.info("New window detected: \(window.title ?? "untitled") for \(bundleID)")
                    await onNewWindowDetected?(bundleID, window)
                }

                // Check for closed windows (only windows that were actively streaming).
                // Read from the latest session snapshot after potential callback updates.
                let currentStreamingIDs = Set(sessions[bundleID]?.windowStreams.keys ?? session.windowStreams.keys)
                for windowID in currentStreamingIDs where !currentValidIDs.contains(windowID) {
                    logger.info("Window closed: \(windowID) for \(bundleID)")
                    await onWindowClosed?(bundleID, windowID)
                }

                // Check if app terminated (no windows and app not running).
                if validWindows.isEmpty {
                    let appIsRunning = NSWorkspace.shared.runningApplications.contains { app in
                        app.bundleIdentifier?.lowercased() == bundleID
                    }

                    let hasActiveWindows = sessions[bundleID]?.hasActiveWindows ?? false
                    if !appIsRunning, hasActiveWindows {
                        logger.info("App terminated: \(bundleID)")
                        await onAppTerminated?(bundleID)
                    }
                }
            }
        } catch {
            logger.error("Failed to check window changes: \(error)")
        }
    }

    private func checkForExpiredCooldowns() async {
        for (bundleID, session) in sessions {
            for windowID in session.expiredCooldowns {
                sessions[bundleID]?.windowsInCooldown.removeValue(forKey: windowID)
                logger.debug("Cooldown expired for window \(windowID) in \(bundleID)")
                await onCooldownExpired?(bundleID, windowID)
            }
        }
    }

    private func checkForExpiredReservations() async {
        let expiredSessions = sessions.filter(\.value.reservationExpired)

        for (bundleID, session) in expiredSessions {
            logger.info("Reservation expired for \(session.appName), ending session")
            sessions.removeValue(forKey: bundleID)
        }

        // Stop monitoring if no more sessions
        if sessions.isEmpty { stopMonitoring() }
    }
}

#endif
