//
//  MirageHostService+DesktopSpaceRestore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

#if os(macOS)

extension MirageHostService {
    func captureDisplaySpaceSnapshot(
        for displayIDs: [CGDirectDisplayID],
        overwriteExisting: Bool
    ) {
        let snapshot = capturedDisplaySpaceSnapshot(
            displayIDs: displayIDs,
            currentSpaceProvider: { CGSWindowSpaceBridge.currentSpace(for: $0) }
        )
        guard !snapshot.isEmpty else { return }

        if overwriteExisting || desktopDisplaySpaceSnapshot.isEmpty {
            desktopDisplaySpaceSnapshot = snapshot
        } else {
            for displayID in displayIDs {
                guard desktopDisplaySpaceSnapshot[displayID] == nil,
                      let spaceID = snapshot[displayID] else { continue }
                desktopDisplaySpaceSnapshot[displayID] = spaceID
            }
        }

        MirageLogger.host("Captured display space snapshot for \(snapshot.count) displays")
    }

    func restoreDisplaySpaceSnapshotIfNeeded(
        reason: String,
        maxAttempts: Int = 3
    )
    async -> Bool {
        guard !desktopDisplaySpaceSnapshot.isEmpty else { return true }

        for attempt in 1 ... maxAttempts {
            let pending = pendingDisplaySpaceRestores(
                snapshot: desktopDisplaySpaceSnapshot,
                currentSpaceProvider: { CGSWindowSpaceBridge.currentSpace(for: $0) }
            )
            if pending.isEmpty { return true }

            for displayID in pending.keys.sorted() {
                guard let expectedSpaceID = pending[displayID] else { continue }
                if !CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: expectedSpaceID) {
                    MirageLogger.host(
                        "Failed to restore current space \(expectedSpaceID) for display \(displayID) " +
                            "(reason=\(reason), attempt=\(attempt))"
                    )
                }
            }

            if attempt < maxAttempts {
                do {
                    try await Task.sleep(for: .milliseconds(Int64(120 * attempt)))
                } catch {
                    return false
                }
            }
        }

        var unresolved = pendingDisplaySpaceRestores(
            snapshot: desktopDisplaySpaceSnapshot,
            currentSpaceProvider: { CGSWindowSpaceBridge.currentSpace(for: $0) }
        )
        if !unresolved.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return false
            }
            unresolved = pendingDisplaySpaceRestores(
                snapshot: desktopDisplaySpaceSnapshot,
                currentSpaceProvider: { CGSWindowSpaceBridge.currentSpace(for: $0) }
            )
        }
        if !unresolved.isEmpty {
            let unresolvedSummary = unresolved
                .keys
                .sorted()
                .compactMap { displayID in
                    guard let expectedSpaceID = unresolved[displayID] else { return nil }
                    let actualSpaceID = CGSWindowSpaceBridge.currentSpace(for: displayID)
                    return "\(displayID): expected=\(expectedSpaceID), actual=\(actualSpaceID)"
                }
                .joined(separator: "; ")
            let message = "Display current Space restore remained incomplete after delayed verification " +
                "(reason=\(reason), attempts=\(maxAttempts)): \(unresolvedSummary)"
            if reason.hasPrefix("mirroring_disable") {
                MirageLogger.host(message)
            } else {
                MirageLogger.error(.host, message)
            }
            return false
        }
        return true
    }

    func finishDesktopSpaceRestoreAfterDisplayTeardown(reason: String) async {
        guard !desktopDisplaySpaceSnapshot.isEmpty else { return }

        for attempt in 1 ... 3 {
            let restored = await restoreDisplaySpaceSnapshotIfNeeded(
                reason: "\(reason)_post_teardown_\(attempt)",
                maxAttempts: 4
            )
            if restored {
                desktopDisplaySpaceSnapshot.removeAll()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(Int64(250 * attempt)))
            } catch {
                return
            }
        }

        MirageLogger.host(
            "Retaining unresolved display Space snapshot for future cleanup (reason=\(reason), displays=\(desktopDisplaySpaceSnapshot.keys.sorted()))"
        )
    }
}

#endif
