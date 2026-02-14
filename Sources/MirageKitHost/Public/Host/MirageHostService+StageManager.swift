//
//  MirageHostService+StageManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Host Stage Manager guardrail for app streaming.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func prepareStageManagerForAppStreamingIfNeeded() async {
        let sessions = await appStreamManager.getAllSessions()
        guard sessions.isEmpty else { return }
        guard !appStreamingStageManagerNeedsRestore else { return }
        guard !appStreamingStageManagerPreparationInProgress else { return }

        appStreamingStageManagerPreparationInProgress = true
        defer { appStreamingStageManagerPreparationInProgress = false }

        let state = await stageManagerController.readState()
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

    func restoreStageManagerAfterAppStreamingIfNeeded(force: Bool = false) async {
        guard appStreamingStageManagerNeedsRestore else { return }

        if !force {
            let sessions = await appStreamManager.getAllSessions()
            guard sessions.isEmpty else { return }
        }

        let restored = await stageManagerController.setEnabled(true)
        if restored {
            appStreamingStageManagerNeedsRestore = false
            MirageLogger.host("Stage Manager restored after app streaming")
        } else {
            MirageLogger.error(.host, "Failed to restore Stage Manager after app streaming")
        }
    }

    func removeStoppedWindowFromAppSessionIfNeeded(windowID: WindowID) async {
        guard let session = await appStreamManager.getSessionForWindow(windowID) else { return }

        await appStreamManager.removeWindowFromSession(
            bundleIdentifier: session.bundleIdentifier,
            windowID: windowID,
            enterCooldown: false
        )
        await endAppSessionIfIdle(bundleIdentifier: session.bundleIdentifier)
    }

    func endAppSessionIfIdle(bundleIdentifier: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return }
        guard session.windowStreams.isEmpty, session.windowsInCooldown.isEmpty else { return }

        await appStreamManager.endSession(bundleIdentifier: bundleIdentifier)
        await restoreStageManagerAfterAppStreamingIfNeeded()
    }
}
#endif
