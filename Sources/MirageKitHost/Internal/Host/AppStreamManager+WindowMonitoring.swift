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

                let runningPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier?.lowercased() == bundleID }
                        .map(\.processIdentifier)
                )

                // Include windows that match by bundle ID or by PID for the selected app.
                let appWindows = content.windows.filter { window in
                    guard let app = window.owningApplication else { return false }
                    if app.bundleIdentifier.lowercased() == bundleID { return true }
                    return runningPIDs.contains(app.processID)
                }

                // Only normal on-screen windows with minimum streamable size.
                let validWindows = appWindows.filter { window in
                    window.isOnScreen &&
                        window.windowLayer == 0 &&
                        window.frame.width >= 160 &&
                        window.frame.height >= 120
                }

                let validWindowsByID = Dictionary(uniqueKeysWithValues: validWindows.map { (WindowID($0.windowID), $0) })
                let currentValidIDs = Set(validWindowsByID.keys)
                let knownWindowIDs = session.knownWindowIDs
                let currentStreamingIDs = Set(session.windowStreams.keys)

                // Only surface each discovered window once while it remains present.
                // This prevents infinite re-attempt loops when stream startup fails.
                let addedWindowIDs = currentValidIDs.subtracting(knownWindowIDs)
                for windowID in addedWindowIDs.sorted(by: <) {
                    guard let window = validWindowsByID[windowID] else { continue }
                    sessions[bundleID]?.knownWindowIDs.insert(windowID)
                    logger.info("New window detected: \(window.title ?? "untitled") for \(bundleID) (\(windowID))")
                    await onNewWindowDetected?(bundleID, window)
                }

                // Forget windows once they disappear so future re-open events can be detected.
                let staleKnownWindowIDs = knownWindowIDs.subtracting(currentValidIDs)
                for windowID in staleKnownWindowIDs {
                    sessions[bundleID]?.knownWindowIDs.remove(windowID)
                }

                let removedWindowIDs = currentStreamingIDs.subtracting(currentValidIDs)
                for windowID in removedWindowIDs.sorted(by: <) {
                    logger.info("Window removed from active set: \(windowID) for \(bundleID)")
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
