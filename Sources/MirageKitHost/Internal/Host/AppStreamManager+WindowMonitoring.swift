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
            let bundleIDs = Array(sessions.keys)
            let catalogByBundleID = try await AppStreamWindowCatalog.catalog(for: bundleIDs)

            for bundleID in bundleIDs {
                guard let session = sessions[bundleID],
                      case .streaming = session.state else { continue }

                let candidates = catalogByBundleID[bundleID.lowercased()] ?? []
                let candidatesByWindowID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.window.id, $0) })
                let currentValidIDs = Set(candidatesByWindowID.keys)
                let knownWindowIDs = session.knownWindowIDs
                let hiddenWindowIDs = Set(session.hiddenWindows.keys)
                let visibleWindowIDs = Set(session.windowStreams.keys)
                var updatedKnownWindowIDs = knownWindowIDs

                var currentAuxiliaryWindowIDs = Set<WindowID>()

                for candidate in candidates {
                    let windowID = candidate.window.id
                    let wasKnown = updatedKnownWindowIDs.contains(windowID)
                    if !wasKnown {
                        updatedKnownWindowIDs.insert(windowID)
                    }

                    switch candidate.classification {
                    case .auxiliary:
                        currentAuxiliaryWindowIDs.insert(windowID)
                        let previouslyKnown = knownAuxiliaryWindowIDs[bundleID]?.contains(windowID) ?? false
                        if !previouslyKnown {
                            logger.info(
                                "Detected auxiliary window: \(candidate.window.displayName) for \(bundleID) (\(windowID), \(candidate.logMetadata))"
                            )
                            await onAuxiliaryWindowDetected?(bundleID, candidate)
                        }
                        continue
                    case .primary:
                        break
                    }

                    if visibleWindowIDs.contains(windowID) { continue }
                    // Hidden windows remain tracked in inventory and should not repeatedly
                    // trigger startup attempts until a slot becomes available.
                    if hiddenWindowIDs.contains(windowID) { continue }
                    guard canAttemptWindowStartup(bundleID: bundleID, windowID: windowID) else {
                        if !wasKnown {
                            logger.debug(
                                "Skipping startup retry for window \(windowID) in \(bundleID); retry budget/cooldown active"
                            )
                        }
                        continue
                    }

                    let prefix = wasKnown ? "Retrying primary window startup" : "New primary window detected"
                    logger.info(
                        "\(prefix): \(candidate.window.displayName) for \(bundleID) (\(windowID), \(candidate.logMetadata))"
                    )
                    await onNewWindowDetected?(bundleID, candidate)
                }

                // Detect auxiliary windows that disappeared since the last scan.
                let previousAuxiliaryIDs = knownAuxiliaryWindowIDs[bundleID] ?? []
                let closedAuxiliaryIDs = previousAuxiliaryIDs.subtracting(currentAuxiliaryWindowIDs)
                for windowID in closedAuxiliaryIDs.sorted(by: <) {
                    logger.info("Auxiliary window closed: \(windowID) for \(bundleID)")
                    await onAuxiliaryWindowClosed?(bundleID, windowID)
                }
                knownAuxiliaryWindowIDs[bundleID] = currentAuxiliaryWindowIDs

                sessions[bundleID]?.knownWindowIDs = updatedKnownWindowIDs

                // Forget windows once they disappear so future re-open events can be detected.
                let staleKnownWindowIDs = updatedKnownWindowIDs.subtracting(currentValidIDs)
                for windowID in staleKnownWindowIDs {
                    sessions[bundleID]?.knownWindowIDs.remove(windowID)
                    clearWindowStartupTracking(bundleID: bundleID, windowID: windowID)
                }

                let trackedWindowIDs = visibleWindowIDs.union(hiddenWindowIDs)
                let removedWindowIDs = trackedWindowIDs.subtracting(currentValidIDs)
                for windowID in removedWindowIDs.sorted(by: <) {
                    logger.info("Window removed from tracked set: \(windowID) for \(bundleID)")
                    await onWindowClosed?(bundleID, windowID)
                }

                // Check if app terminated (no windows and app not running).
                if candidates.isEmpty {
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
