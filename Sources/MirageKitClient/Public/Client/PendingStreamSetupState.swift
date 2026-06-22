//
//  PendingStreamSetupState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
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

@MainActor
extension MirageClientService {
    func clearPendingStreamSetup(kind: MirageWire.StreamSetupKind? = nil, appSessionID: UUID? = nil) {
        if let kind, pendingStreamSetupKind != kind { return }
        if let appSessionID, pendingStreamSetupAppSessionID != appSessionID { return }
        if kind == nil || kind == .app || pendingStreamSetupKind == .app {
            appStreamStartTimeoutTask?.cancel()
            appStreamStartTimeoutTask = nil
        }
        pendingStreamSetupRequestID = nil
        pendingStreamSetupKind = nil
        pendingStreamSetupAppSessionID = nil
        pendingStreamSetupLatencyMode = nil
    }

    func clearPendingAppStreamStartState(appSessionID: UUID? = nil) {
        if let appSessionID, pendingStreamSetupAppSessionID != appSessionID { return }
        appStreamStartTimeoutTask?.cancel()
        appStreamStartTimeoutTask = nil
        pendingAppRequestedColorDepth = nil
        pendingAppRequestedLatencyMode = nil
        clearPendingStreamSetup(kind: .app, appSessionID: appSessionID)
    }

    func clearPendingDesktopStreamStartState() {
        guard desktopStreamID == nil else { return }
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = nil
        desktopStreamRequestStartTime = 0
        desktopSessionID = nil
        desktopStreamMode = nil
        desktopCursorPresentation = nil
        desktopStreamPresentationResolution = nil
        desktopStreamDisplayScaleFactor = nil
        desktopVisibleBounds = nil
        desktopVisibleBoundsReferenceSize = nil
        desktopCaptureSource = .virtualDisplay
        desktopStreamAllowsClientResize = true
        pendingDesktopRequestedColorDepth = nil
        pendingDesktopRequestedLatencyMode = nil
        clearPendingStreamSetup(kind: .desktop)
        desktopResizeCoordinator.clearAllState()
    }
}
