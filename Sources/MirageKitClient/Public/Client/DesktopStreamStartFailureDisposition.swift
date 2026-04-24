//
//  DesktopStreamStartFailureDisposition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import MirageKit

enum DesktopStreamStartFailureDisposition: Equatable {
    case noChange
    case clearPendingStart
}

func desktopStreamStartFailureDisposition(
    errorCode: ErrorMessage.ErrorCode,
    desktopStartPending: Bool,
    hasActiveDesktopStream: Bool
) -> DesktopStreamStartFailureDisposition {
    guard desktopStartPending else { return .noChange }
    guard !hasActiveDesktopStream else { return .noChange }
    _ = errorCode
    return .clearPendingStart
}

@MainActor
extension MirageClientService {
    func clearPendingStreamSetup(kind: StreamSetupKind? = nil, appSessionID: UUID? = nil) {
        if let kind, pendingStreamSetupKind != kind { return }
        if let appSessionID, pendingStreamSetupAppSessionID != appSessionID { return }
        pendingStreamSetupRequestID = nil
        pendingStreamSetupKind = nil
        pendingStreamSetupAppSessionID = nil
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
        desktopCaptureSource = .virtualDisplay
        desktopStreamAllowsClientResize = true
        pendingDesktopRequestedColorDepth = nil
        clearPendingStreamSetup(kind: .desktop)
        desktopResizeCoordinator.clearAllState()
    }
}
