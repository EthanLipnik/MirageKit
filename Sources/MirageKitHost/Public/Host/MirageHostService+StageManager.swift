//
//  MirageHostService+StageManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Host Stage Manager guardrail for app streaming.
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
import Foundation

#if os(macOS)
import AppKit
@MainActor
extension MirageHostService {
    /// Disables Stage Manager before app streaming starts when it would interfere with window placement.
    func prepareStageManagerForAppStreamingIfNeeded() async {
        let sessions = await appStreamManager.allSessions()
        guard sessions.isEmpty else { return }
        guard !appStreamingStageManagerNeedsRestore else { return }
        guard !appStreamingStageManagerPreparationInProgress else { return }

        appStreamingStageManagerPreparationInProgress = true
        defer { appStreamingStageManagerPreparationInProgress = false }

        let state = await stageManagerController.readCurrentState()
        switch state {
        case .disabled:
            MirageLogger.host("Stage Manager is already off for app streaming")

        case .enabled:
            let disabled = await stageManagerController.setEnabled(false)
            if disabled {
                appStreamingStageManagerNeedsRestore = true
                MirageLogger.host("Stage Manager disabled for app streaming")
            } else {
                MirageLogger.error(.host, "Unable to disable Stage Manager for app streaming; continuing startup")
            }

        case .unknown:
            let disabled = await stageManagerController.setEnabled(false)
            if disabled {
                MirageLogger
                    .host(
                        "Stage Manager disabled for app streaming with unknown pre-stream state; restoration is skipped"
                    )
            } else {
                MirageLogger.error(.host, "Unable to disable Stage Manager for app streaming; continuing startup")
            }
        }
    }

    /// Restores Stage Manager after app streaming no longer needs it disabled.
    func restoreStageManagerAfterAppStreamingIfNeeded(force: Bool = false) async {
        guard appStreamingStageManagerNeedsRestore else { return }

        if !force {
            guard await !hasAppStreamingStageManagerWorkInProgress() else { return }
        }

        let restored = await stageManagerController.setEnabled(true)
        if restored {
            appStreamingStageManagerNeedsRestore = false
            MirageLogger.host("Stage Manager restored after app streaming")
        } else {
            MirageLogger.error(.host, "Failed to restore Stage Manager after app streaming")
        }
    }

    private func hasAppStreamingStageManagerWorkInProgress() async -> Bool {
        if !pendingLockedAppStreamIntentsByAppSessionID.isEmpty { return true }

        let sessions = await appStreamManager.allSessions()
        return !sessions.isEmpty
    }

    /// Removes a stopped stream's window from its app session and ends the session if it is idle.
    func removeStoppedWindowFromAppSessionIfNeeded(
        streamID: StreamID,
        fallbackWindowID: WindowID
    ) async {
        guard let session = await appStreamManager.sessionForStreamID(streamID) else { return }
        let windowID = await appStreamManager.windowIDForStream(
            bundleIdentifier: session.bundleIdentifier,
            streamID: streamID
        ) ?? fallbackWindowID

        await appStreamManager.removeWindowFromSession(
            bundleIdentifier: session.bundleIdentifier,
            windowID: windowID
        )
        await endAppSessionIfIdle(bundleIdentifier: session.bundleIdentifier)
    }

    /// Ends an app-stream session once it has no streamed windows remaining.
    func endAppSessionIfIdle(
        bundleIdentifier: String,
        keepAliveIfAppRunning: Bool = false
    )
    async {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleIdentifier) else { return }
        guard session.windowStreams.isEmpty else { return }

        if keepAliveIfAppRunning {
            let normalizedBundleIdentifier = bundleIdentifier.lowercased()
            let appIsRunning = NSWorkspace.shared.runningApplications.contains { app in
                app.bundleIdentifier?.lowercased() == normalizedBundleIdentifier
            }
            if appIsRunning {
                MirageLogger.host("Keeping idle app session alive for running app \(bundleIdentifier)")
                return
            }
        }

        await appStreamManager.endSession(bundleIdentifier: bundleIdentifier)
        await stopAppStreamGovernorsIfIdle()
        await restoreStageManagerAfterAppStreamingIfNeeded()
    }
}
#endif
